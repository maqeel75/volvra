-- =====================================================================
-- pgVolvra security suite
--
-- Everything here runs as a *real unprivileged role* via SET ROLE, not as
-- the superuser that installed volvra.  Negative tests are wrapped in
-- exception handlers and assert both that the operation failed and that it
-- failed for the right reason.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== S0. cast of characters ==='
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['app_writer','nobody','viewer_ok','viewer_blind',
                           'operator_ok','operator_norights','admin_user'] LOOP
    -- Created if absent, never dropped and recreated.  Roles are
    -- cluster-wide, so a role that holds privileges in another database
    -- cannot be dropped from this one, and this suite runs in more than one
    -- database per cluster.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I LOGIN', r);
    END IF;

    -- From PostgreSQL 16, a CREATEROLE role receives ADMIN OPTION on the
    -- roles it creates but NOT the SET option, so SET ROLE is refused even
    -- though pg_auth_members shows admin_option = t.  An explicit GRANT
    -- carries SET by default on every supported version.  Superusers may
    -- already SET ROLE to anything, so this is a no-op for them.
    IF NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
      EXECUTE format('GRANT %I TO CURRENT_USER', r);
    END IF;
  END LOOP;
END $$;

GRANT volvra_viewer   TO viewer_ok, viewer_blind;
GRANT volvra_operator TO operator_ok, operator_norights;
GRANT volvra_admin    TO admin_user;

DROP TABLE IF EXISTS ledger;
DROP TABLE IF EXISTS secrets;
CREATE TABLE ledger  (id int PRIMARY KEY, amount numeric NOT NULL, memo text);
CREATE TABLE secrets (id int PRIMARY KEY, ssn text NOT NULL);

SELECT volvra.enable('ledger');
SELECT volvra.enable('secrets');

INSERT INTO ledger  VALUES (1, 10.00, 'a'), (2, 20.00, 'b');
INSERT INTO secrets VALUES (1, '000-00-0001');

GRANT USAGE ON SCHEMA public TO app_writer, viewer_ok, viewer_blind,
                                operator_ok, operator_norights, admin_user, nobody;
GRANT SELECT, INSERT, UPDATE, DELETE ON ledger TO app_writer, operator_ok;
GRANT SELECT ON ledger TO viewer_ok;
-- operator_norights may READ ledger but not write it: that is what proves undo
-- checks the caller's own DML rights rather than the volvra role alone.
GRANT SELECT ON ledger TO operator_norights;
-- viewer_blind and nobody get NOTHING on ledger.

-- ---------------------------------------------------------------------
\echo '=== S1. an ordinary writer is captured, and cannot forge attribution ==='
SELECT clock_timestamp() AS ts_s1 \gset
SELECT pg_sleep(0.05);

SET ROLE app_writer;
SET volvra.actor = 'i-am-the-dba';          -- deliberate spoof attempt
UPDATE ledger SET amount = 0 WHERE id = 1;
RESET ROLE;

DO $$
DECLARE v record;
BEGIN
  SELECT actor, db_user INTO v
  FROM volvra.change_log
  WHERE table_name = 'public.ledger' AND op = 'U'
  ORDER BY id DESC LIMIT 1;

  ASSERT v.actor   = 'i-am-the-dba',
         'the app-declared actor is recorded as given';
  ASSERT v.db_user = 'app_writer',
         format('db_user must be the authenticated role, got %s', v.db_user);
END $$;

-- ---------------------------------------------------------------------
\echo '=== S2. a writer with no volvra grants cannot reach volvra at all ==='
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE app_writer;
  BEGIN
    PERFORM count(*) FROM volvra.change_log;
    RAISE EXCEPTION 'SECURITY FAILURE: app_writer read change_log';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'change_log must be unreadable without a grant';
END $$;
RESET ROLE;

DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE nobody;
  BEGIN
    PERFORM volvra.undo('public.ledger'::regclass, '-infinity'::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'SECURITY FAILURE: nobody executed undo';
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR invalid_schema_name THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'undo must be unreachable without volvra_operator';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------
\echo '=== S3. history cannot be used to bypass a table''s own SELECT grants ==='
SET ROLE viewer_ok;
SELECT count(*) AS ledger_history_rows FROM volvra.history('ledger', '{"id":1}');
RESET ROLE;

DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE viewer_blind;                   -- volvra_viewer, no SELECT on ledger
  BEGIN
    PERFORM * FROM volvra.history('public.ledger'::regclass, '{"id":1}'::jsonb);
    RAISE EXCEPTION 'SECURITY FAILURE: viewer_blind read ledger history';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'history must require SELECT on the base table';
END $$;
RESET ROLE;

\echo '--- and RLS hides those rows on a direct change_log read ---'
DO $$
DECLARE v_ledger bigint; v_secrets bigint;
BEGIN
  SET LOCAL ROLE viewer_ok;                      -- may read ledger, not secrets
  SELECT count(*) FILTER (WHERE table_name = 'public.ledger'),
         count(*) FILTER (WHERE table_name = 'public.secrets')
    INTO v_ledger, v_secrets
  FROM volvra.change_log;

  ASSERT v_ledger  > 0, 'viewer_ok should see ledger history';
  ASSERT v_secrets = 0,
    format('SECURITY FAILURE: viewer_ok saw %s secrets history rows', v_secrets);
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------
\echo '=== S4. previewing an undo leaks row images -- same gate applies ==='
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE viewer_blind;
  BEGIN
    PERFORM * FROM volvra.preview_undo('public.ledger'::regclass,
                                       '-infinity'::timestamptz, now());
    RAISE EXCEPTION 'SECURITY FAILURE: viewer_blind previewed ledger';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'preview_undo must require SELECT on the base table';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------
\echo '=== S5. a viewer cannot apply an undo ==='
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE viewer_ok;
  BEGIN
    PERFORM volvra.undo('public.ledger'::regclass, '-infinity'::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'SECURITY FAILURE: viewer_ok applied an undo';
  EXCEPTION WHEN insufficient_privilege OR undefined_function THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'confirm => true requires volvra_operator';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------
\echo '=== S6. volvra_operator is not a backdoor onto tables you cannot write ==='
SELECT set_config('test.ts_s1', :'ts_s1', false);
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE operator_norights;   -- volvra_operator, read-only on ledger
  BEGIN
    PERFORM volvra.undo('public.ledger'::regclass,
                        current_setting('test.ts_s1')::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'SECURITY FAILURE: operator_norights rewrote ledger';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked',
    'undo is SECURITY INVOKER: the caller still needs its own DML rights';
END $$;
RESET ROLE;

\echo '--- an operator that *does* hold the rights succeeds ---'
SELECT set_config('test.ts_s1', :'ts_s1', false);
SET ROLE operator_ok;
SELECT count(*) AS applied
FROM volvra.undo('ledger', current_setting('test.ts_s1')::timestamptz,
                 now(), confirm => true);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT amount FROM ledger WHERE id = 1) = 10.00, 'legitimate undo restored the row';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S7. history cannot be forged by attaching capture() elsewhere ==='
GRANT CREATE ON SCHEMA public TO app_writer;
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE app_writer;
  CREATE TABLE attacker_tbl (id int PRIMARY KEY, junk text);
  BEGIN
    EXECUTE 'CREATE TRIGGER t AFTER INSERT ON attacker_tbl '
            'FOR EACH ROW EXECUTE FUNCTION volvra.capture(''id'')';
    RAISE EXCEPTION 'SECURITY FAILURE: app_writer attached volvra.capture()';
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR invalid_schema_name THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'capture() must not be attachable by ordinary roles';
END $$;
RESET ROLE;

\echo '--- and even from a privileged trigger, unregistered tables are refused ---'
DROP TABLE IF EXISTS unregistered;
CREATE TABLE unregistered (id int PRIMARY KEY, junk text);
CREATE TRIGGER t AFTER INSERT ON unregistered
  FOR EACH ROW EXECUTE FUNCTION volvra.capture('id');
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    INSERT INTO unregistered VALUES (1, 'forged');
    RAISE EXCEPTION 'SECURITY FAILURE: capture() logged an unregistered table';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'capture() must refuse tables volvra.enable() did not arm';
END $$;
DROP TABLE unregistered;

-- ---------------------------------------------------------------------
\echo '=== S8. append-only survives a hostile GUC ==='
DO $$
DECLARE v_state text;
BEGIN
  -- the guard consults volvra.allow_purge, so try to open it by hand
  PERFORM set_config('volvra.allow_purge', 'on', true);
  SET LOCAL ROLE operator_ok;
  BEGIN
    DELETE FROM volvra.change_log WHERE true;
    RAISE EXCEPTION 'SECURITY FAILURE: operator_ok purged change_log';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'allow_purge alone must not defeat the append-only guard';
END $$;
RESET ROLE;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log) > 0, 'history intact';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S9. only an admin may arm, disarm, or reconfigure ==='
DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE operator_ok;
  BEGIN
    PERFORM volvra.set_setting('max_undo_rows', '999999999');
    RAISE EXCEPTION 'SECURITY FAILURE: operator_ok changed the blast-radius cap';
  EXCEPTION WHEN insufficient_privilege OR undefined_function THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'set_setting requires volvra_admin';
END $$;
RESET ROLE;

DO $$
DECLARE v_state text;
BEGIN
  SET LOCAL ROLE operator_ok;
  BEGIN
    PERFORM volvra.disable('public.ledger'::regclass);
    RAISE EXCEPTION 'SECURITY FAILURE: operator_ok stopped capture';
  EXCEPTION WHEN insufficient_privilege OR undefined_function THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'disable requires volvra_admin';
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------
\echo '=== S10. volvra cannot be pointed at its own tables ==='
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.enable('volvra.change_log'::regclass);
    RAISE EXCEPTION 'SECURITY FAILURE: volvra covered its own history table';
  EXCEPTION WHEN raise_exception THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'enable() must refuse the volvra schema';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S11. injection-shaped identifiers and payloads round-trip safely ==='
DROP TABLE IF EXISTS "we'ird ""tbl";
CREATE TABLE "we'ird ""tbl" (
  "o'clock"      int PRIMARY KEY,
  "col"");--"    text,
  payload        text
);
SELECT volvra.enable('"we''ird ""tbl"');
INSERT INTO "we'ird ""tbl" VALUES
  (1, 'x', $q$'); DROP TABLE ledger; --$q$),
  (2, 'y', $q$Robert'); DROP TABLE students;--$q$);

SELECT clock_timestamp() AS ts_inj \gset
SELECT pg_sleep(0.05);
UPDATE "we'ird ""tbl" SET payload = 'clobbered';

SELECT count(*) FROM volvra.undo('"we''ird ""tbl"', :'ts_inj', now(), confirm => true);

DO $$ BEGIN
  ASSERT (SELECT to_regclass('public.ledger')) IS NOT NULL,
         'SECURITY FAILURE: injected payload dropped a table';
  ASSERT (SELECT payload FROM "we'ird ""tbl" WHERE "o'clock" = 1)
         = $q$'); DROP TABLE ledger; --$q$,
         'injection-shaped payload restored verbatim';
  ASSERT (SELECT payload FROM "we'ird ""tbl" WHERE "o'clock" = 2)
         = $q$Robert'); DROP TABLE students;--$q$,
         'second injection-shaped payload restored verbatim';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S12. strict_roles fails closed when a role is missing ==='
SELECT volvra.set_setting('strict_roles', 'on');
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra._require('volvra_does_not_exist');
    RAISE EXCEPTION 'SECURITY FAILURE: strict_roles did not fail closed';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'strict_roles must turn a missing role into a hard error';
END $$;
SELECT volvra.set_setting('strict_roles', 'off');

-- ---------------------------------------------------------------------
\echo '=== S13. every undo attempt is attributable ==='
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.undo_log WHERE db_user = 'operator_ok';
  ASSERT v_n >= 1, 'undo_log must attribute the applied undo to operator_ok';
  ASSERT (SELECT count(*) FROM volvra.undo_log WHERE db_user IS NULL) = 0,
         'undo_log db_user is never null';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S14. a viewer can actually read everything the docs promise ==='
-- Every earlier read test ran as a superuser, which is why two GRANT
-- statements could silently fail to apply and nothing noticed.  This section
-- exercises the documented read surface as a real volvra_viewer.
DO $$
DECLARE
  t        text;
  v_denied text[] := '{}';
BEGIN
  SET LOCAL ROLE viewer_ok;
  FOREACH t IN ARRAY ARRAY['change_log','enabled_tables','undo_log','settings',
                           'seal','retention','retention_log','erasure_log',
                           'schema_version','companion_checkpoint',
                           'companion_gap'] LOOP
    BEGIN
      EXECUTE format('SELECT 1 FROM volvra.%I LIMIT 1', t);
    EXCEPTION WHEN insufficient_privilege THEN
      v_denied := v_denied || t::text;
    END;
  END LOOP;
  ASSERT v_denied = '{}',
    format('volvra_viewer cannot read: %s', array_to_string(v_denied, ', '));
END $$;
RESET ROLE;

\echo '--- and can run every read-only function ---'
DO $$
DECLARE v_failed text[] := '{}';
BEGIN
  SET LOCAL ROLE viewer_ok;
  BEGIN PERFORM count(*) FROM volvra.health();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'health'::text; END;
  BEGIN PERFORM count(*) FROM volvra.preflight();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'preflight'::text; END;
  BEGIN PERFORM count(*) FROM volvra.status();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'status'::text; END;
  BEGIN PERFORM count(*) FROM volvra.storage();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'storage'::text; END;
  BEGIN PERFORM count(*) FROM volvra.activity('1 hour','1 hour');
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'activity'::text; END;
  BEGIN PERFORM count(*) FROM volvra.fingerprint();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'fingerprint'::text; END;
  BEGIN PERFORM count(*) FROM volvra.verify();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'verify'::text; END;
  BEGIN PERFORM count(*) FROM volvra.transactions();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'transactions'::text; END;
  BEGIN PERFORM count(*) FROM volvra.uncovered('public');
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'uncovered'::text; END;
  BEGIN PERFORM volvra.version();
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || 'version'::text; END;
  ASSERT v_failed = '{}',
    format('volvra_viewer cannot run: %s', array_to_string(v_failed, ', '));
END $$;
RESET ROLE;

\echo '--- and the companion can report progress without owning the schema ---'
DO $$
DECLARE v_failed text[] := '{}';
BEGIN
  -- The companion connects as an ordinary role, not as the installer.
  SET LOCAL ROLE viewer_ok;
  BEGIN
    PERFORM volvra.companion_report('test_slot', '0/1000'::pg_lsn, 1, 1, '/tmp');
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || ('report: ' || SQLERRM); END;
  BEGIN
    PERFORM volvra.companion_record_gap('test_slot', '0/1000'::pg_lsn,
                                        '0/2000'::pg_lsn, 'test', 'test');
  EXCEPTION WHEN OTHERS THEN v_failed := v_failed || ('gap: ' || SQLERRM); END;
  ASSERT v_failed = '{}',
    format('a companion running as an ordinary role cannot: %s',
           array_to_string(v_failed, ', '));
END $$;
RESET ROLE;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.companion_checkpoint
          WHERE slot_name = 'test_slot') = 1, 'the checkpoint was recorded';
  ASSERT (SELECT count(*) FROM volvra.companion_gap
          WHERE slot_name = 'test_slot') = 1, 'the gap was recorded';
END $$;

\echo '--- but a viewer still cannot write history or change settings ---'
DO $$
DECLARE v_allowed text[] := '{}';
BEGIN
  SET LOCAL ROLE viewer_ok;
  BEGIN
    PERFORM volvra.set_setting('max_undo_rows', '1');
    v_allowed := v_allowed || 'set_setting'::text;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN
    PERFORM volvra.seal();
    v_allowed := v_allowed || 'seal'::text;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN
    PERFORM volvra.forget('public.ledger'::regclass, '{"id":1}'::jsonb);
    v_allowed := v_allowed || 'forget'::text;
  EXCEPTION WHEN OTHERS THEN NULL; END;
  ASSERT v_allowed = '{}',
    format('a viewer must not be able to: %s', array_to_string(v_allowed, ', '));
END $$;
RESET ROLE;

\echo ''
\echo '*** ALL VOLVRA SECURITY CHECKS PASSED ***'
