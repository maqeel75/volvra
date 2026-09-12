-- =====================================================================
-- pgVolvra phase 4 -- trust
--
-- Gate: every claim in the README survives a hostile reading.  These tests
-- therefore try to break the claims, not demonstrate them.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== P4.1 the schema version ledger is complete and has no gaps ==='
SELECT version, note FROM volvra.schema_version ORDER BY version;
DO $$
DECLARE v_gaps int;
BEGIN
  ASSERT volvra._at_least(1), 'the schema is installed';
  SELECT count(*) INTO v_gaps FROM generate_series(1, volvra.version()) AS n
  WHERE NOT EXISTS (SELECT 1 FROM volvra.schema_version sv WHERE sv.version = n);
  ASSERT v_gaps = 0, 'the migration ledger has no gaps';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.2 sealing makes the history verifiable ==='
DROP TABLE IF EXISTS ledger4;
CREATE TABLE ledger4 (id int PRIMARY KEY, owner text, amount numeric);
SELECT volvra.enable('ledger4');
INSERT INTO ledger4 VALUES (1,'ada',100), (2,'grace',200), (3,'hopper',300);
UPDATE ledger4 SET amount = amount + 1 WHERE id = 1;

SELECT seal_id, from_id, to_id, row_count FROM volvra.seal();

DO $$
DECLARE v_bad bigint;
BEGIN
  ASSERT (SELECT count(*) FROM volvra.seal) = 1, 'one seal';
  SELECT count(*) INTO v_bad FROM volvra.verify() WHERE verdict <> 'ok';
  ASSERT v_bad = 0, format('a freshly sealed history must verify, %s bad', v_bad);
END $$;

\echo '--- sealing again covers only what is new ---'
UPDATE ledger4 SET amount = 999 WHERE id = 2;
SELECT from_id, to_id, row_count FROM volvra.seal();

DO $$
DECLARE r record;
BEGIN
  ASSERT (SELECT count(*) FROM volvra.seal) = 2, 'a second seal';
  SELECT * INTO r FROM volvra.seal ORDER BY id DESC LIMIT 1;
  ASSERT r.row_count = 1, format('the second seal covers 1 change, got %s', r.row_count);
  ASSERT r.prev_hash = (SELECT chain_hash FROM volvra.seal ORDER BY id LIMIT 1),
         'and is chained to the first';
  ASSERT (SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok') = 0,
         'both spans verify';
END $$;

\echo '--- an empty seal is a no-op, not a spurious span ---'
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.seal()) = 0,
    'sealing with nothing new must produce no seal';
  ASSERT (SELECT count(*) FROM volvra.seal) = 2, 'and add no row';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.3 altering sealed history is detected ==='
-- Forge a row the way an attacker with table ownership would have to: open the
-- purge window (which needs volvra_admin) and redact.  This is the strongest
-- write anyone can make, and it must still be caught.
DO $$
DECLARE v_id bigint;
BEGIN
  SELECT min(id) INTO v_id FROM volvra.change_log WHERE table_name = 'public.ledger4';
  PERFORM set_config('volvra.allow_purge', 'on', true);
  UPDATE volvra.change_log
     SET old_row = NULL, new_row = NULL, redacted_at = clock_timestamp(),
         redacted_by = 'mallory'
   WHERE id = v_id;
  PERFORM set_config('volvra.allow_purge', 'off', true);
END $$;

SELECT seal_id, verdict, rows_sealed, rows_found FROM volvra.verify();

DO $$
DECLARE v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad FROM volvra.verify() WHERE verdict = 'TAMPERED';
  ASSERT v_bad = 1,
    format('an unexplained change to sealed history must read TAMPERED, got %s', v_bad);
  ASSERT (SELECT count(*) FROM volvra.health()
          WHERE severity = 'critical' AND problem LIKE '%no longer match%') = 1,
    'and health() must call it critical';
END $$;

\echo '--- deleting a sealed row is detected too ---'
DROP TABLE IF EXISTS ledger5;
CREATE TABLE ledger5 (id int PRIMARY KEY, v text);
SELECT volvra.enable('ledger5');
INSERT INTO ledger5 VALUES (1,'a'), (2,'b');
SELECT from_id, to_id FROM volvra.seal();

DO $$
DECLARE v_id bigint;
BEGIN
  SELECT max(id) INTO v_id FROM volvra.change_log WHERE table_name = 'public.ledger5';
  PERFORM set_config('volvra.allow_purge', 'on', true);
  DELETE FROM volvra.change_log WHERE id = v_id;
  PERFORM set_config('volvra.allow_purge', 'off', true);
END $$;

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.verify() ORDER BY seal_id DESC LIMIT 1;
  ASSERT r.verdict = 'TAMPERED', format('a removed row must be caught, got %s', r.verdict);
  ASSERT r.rows_found = r.rows_sealed - 1,
    format('and counted: sealed %s, found %s', r.rows_sealed, r.rows_found);
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.4 forging a seal row is detected ==='
DO $$
DECLARE v_state text; v_bad bigint;
BEGIN
  -- The seal table is append-only for the same reason the history is.
  BEGIN
    UPDATE volvra.seal SET content_hash = 'forged' WHERE id = 1;
    v_state := 'allowed';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;

  IF v_state = 'allowed' THEN
    -- if it can be written at all, verify() must still catch it
    SELECT count(*) INTO v_bad FROM volvra.verify()
    WHERE verdict IN ('SEAL FORGED', 'CHAIN BROKEN', 'TAMPERED');
    ASSERT v_bad > 0, 'a rewritten seal must not verify clean';
  END IF;
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.5 lawful erasure is not reported as tampering ==='
DROP TABLE IF EXISTS people;
CREATE TABLE people (id int PRIMARY KEY, email text NOT NULL, note text);
SELECT volvra.enable('people');
INSERT INTO people VALUES (1,'ada@example.com','vip'), (2,'grace@example.com',NULL);
UPDATE people SET note = 'changed' WHERE id = 1;

SELECT from_id, to_id FROM volvra.seal();
DO $$ BEGIN
  ASSERT (SELECT verdict FROM volvra.verify() ORDER BY seal_id DESC LIMIT 1) = 'ok',
    'the span covering this subject verifies before the erasure';
END $$;

SELECT mode, rows_erased FROM volvra.forget('people', '{"id":1}', reason => 'GDPR art.17');

DO $$
DECLARE v_ct bigint;
BEGIN
  -- the personal data is gone
  SELECT count(*) INTO v_ct FROM volvra.change_log
   WHERE table_name = 'public.people' AND pk @> '{"id":1}'
     AND (old_row IS NOT NULL OR new_row IS NOT NULL);
  ASSERT v_ct = 0, 'every row image for that subject must be redacted';

  -- but the fact that changes happened survives
  SELECT count(*) INTO v_ct FROM volvra.change_log
   WHERE table_name = 'public.people' AND pk @> '{"id":1}';
  ASSERT v_ct = 2, format('the change records themselves remain, got %s', v_ct);

  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE pk @> '{"id":1}' AND table_name = 'public.people'
            AND redacted_at IS NULL) = 0, 'all stamped as redacted';

  -- the other subject is untouched
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.people' AND pk @> '{"id":2}'
            AND new_row IS NOT NULL) = 1, 'other subjects are not collateral';

  -- and it is recorded
  ASSERT (SELECT count(*) FROM volvra.erasure_log
          WHERE table_name = 'public.people' AND mode = 'redact') = 1,
    'erasure is itself auditable';
END $$;

\echo '--- verify() distinguishes that from an attack ---'
SELECT seal_id, verdict FROM volvra.verify() ORDER BY seal_id DESC LIMIT 1;
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.verify() ORDER BY seal_id DESC LIMIT 1;
  ASSERT r.verdict = 'changed by recorded erasure or retention',
    format('lawful erasure must not read as tampering, got %s', r.verdict);
END $$;

\echo '--- hard erasure removes the rows outright ---'
SELECT mode, rows_erased FROM volvra.forget('people', '{"id":2}', hard => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.people' AND pk @> '{"id":2}') = 0,
    'hard mode is for when the primary key is itself personal data';
  ASSERT (SELECT count(*) FROM volvra.erasure_log WHERE mode = 'hard') = 1,
    'and is recorded as such';
END $$;

\echo '--- erasing an unknown subject is not an error ---'
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.forget('people', '{"id":9999}');
  ASSERT r.rows_erased = 0, 'nothing to erase reports zero, it does not raise';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.6 the redaction window cannot be used to rewrite history ==='
DO $$
DECLARE v_state text;
BEGIN
  PERFORM set_config('volvra.allow_purge', 'on', true);
  BEGIN
    -- an attacker's real goal: change who did it, not remove the content
    UPDATE volvra.change_log
       SET db_user = 'somebody-else', redacted_at = clock_timestamp(),
           old_row = NULL, new_row = NULL
     WHERE table_name = 'public.ledger4';
    RAISE EXCEPTION 'SECURITY FAILURE: attribution was rewritten';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  PERFORM set_config('volvra.allow_purge', 'off', true);
  ASSERT v_state = 'blocked',
    'the redaction path may only remove content, never alter attribution';
END $$;

DO $$
DECLARE v_state text;
BEGIN
  PERFORM set_config('volvra.allow_purge', 'on', true);
  BEGIN
    -- nor may it put different content in
    UPDATE volvra.change_log
       SET old_row = '{"amount": 1}'::jsonb, redacted_at = clock_timestamp()
     WHERE table_name = 'public.ledger4';
    RAISE EXCEPTION 'SECURITY FAILURE: history was rewritten, not redacted';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  PERFORM set_config('volvra.allow_purge', 'off', true);
  ASSERT v_state = 'blocked', 'redaction nulls content; it never substitutes it';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.7 column exclusion keeps data out of the history ==='
DROP TABLE IF EXISTS cards;
CREATE TABLE cards (id int PRIMARY KEY, holder text, pan text, note text);
SELECT volvra.enable('cards');
SELECT table_name, excluded, warning FROM volvra.exclude_columns('cards', ARRAY['pan']);

INSERT INTO cards VALUES (1, 'ada', '4111111111111111', 'first');
UPDATE cards SET note = 'second' WHERE id = 1;
UPDATE cards SET pan = '4222222222222222' WHERE id = 1;

DO $$
DECLARE v_leaks bigint;
BEGIN
  SELECT count(*) INTO v_leaks FROM volvra.change_log
   WHERE table_name = 'public.cards'
     AND (old_row::text LIKE '%4111%' OR new_row::text LIKE '%4111%'
       OR old_row::text LIKE '%4222%' OR new_row::text LIKE '%4222%'
       OR old_row ? 'pan' OR new_row ? 'pan');
  ASSERT v_leaks = 0,
    format('an excluded column must never reach the history, %s leaks', v_leaks);

  -- a change confined to an excluded column records nothing at all
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.cards' AND op = 'U') = 1,
    'the pan-only update must not even record that something changed';
END $$;

\echo '--- excluding a required column warns that deletes become unrecoverable ---'
DROP TABLE IF EXISTS required_excl;
CREATE TABLE required_excl (id int PRIMARY KEY, must_have text NOT NULL);
SELECT volvra.enable('required_excl');
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.exclude_columns('required_excl', ARRAY['must_have']);
  ASSERT r.warning IS NOT NULL,
    'excluding a NOT NULL column must warn, not stay silent';
  ASSERT r.warning LIKE '%must_have%' AND r.warning LIKE '%undone%',
    format('the warning must name the column and the consequence, got: %s', r.warning);
END $$;

\echo '--- and undoing such a delete refuses rather than inserting a wrong row ---'
INSERT INTO required_excl VALUES (1, 'secret');
SELECT clock_timestamp() AS r0 \gset
SELECT pg_sleep(0.05);
DELETE FROM required_excl WHERE id = 1;
SELECT set_config('test.r0', :'r0', false);
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo('required_excl'::regclass,
                        current_setting('test.r0')::timestamptz, now(), confirm => true);
    RAISE EXCEPTION 'CORRECTNESS FAILURE: rebuilt a row without a required column';
  EXCEPTION WHEN datatype_mismatch THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'an incomplete image must refuse, not guess';
END $$;

\echo '--- the primary key can never be excluded ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.exclude_columns('cards'::regclass, ARRAY['id']);
    RAISE EXCEPTION 'SECURITY FAILURE: the pk was excluded';
  EXCEPTION WHEN invalid_column_reference THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'without a pk a change cannot be located at all';
END $$;

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.exclude_columns('cards'::regclass, ARRAY['no_such_column']);
    RAISE EXCEPTION 'expected an undefined_column error';
  EXCEPTION WHEN undefined_column THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'a typo in an exclusion list must not silently pass';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.8 an undo still works on a table with exclusions ==='
SELECT clock_timestamp() AS c0 \gset
SELECT pg_sleep(0.05);
UPDATE cards SET note = 'clobbered' WHERE id = 1;
SELECT set_config('test.c0', :'c0', false);

SELECT count(*) FROM volvra.undo('cards', :'c0', now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT note FROM cards WHERE id = 1) = 'second',
    'the captured columns are restored';
  ASSERT (SELECT pan FROM cards WHERE id = 1) = '4222222222222222',
    'and the excluded column is left exactly as it is';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.9 retention is recorded, and does not read as tampering ==='
DO $$
DECLARE v_old timestamptz := now() - interval '30 months';
BEGIN
  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid, ts)
  VALUES ('public.ledger4', 'U', '{"id":3}', '{"amount":1}', '{"amount":2}',
          'old', 'old', 1, v_old);
END $$;
SELECT volvra.relocate_default() IS NOT NULL AS relocated;
SELECT from_id, to_id FROM volvra.seal();

DO $$
DECLARE v_dropped bigint;
BEGIN
  SELECT count(*) INTO v_dropped FROM volvra.purge('12 months'::interval)
   WHERE action = 'dropped partition';
  ASSERT v_dropped >= 1, 'retention reclaimed a partition';
  ASSERT (SELECT count(*) FROM volvra.retention_log WHERE scope = 'partition') >= 1,
    'and recorded which ids it removed';
END $$;

DO $$
DECLARE v_untriaged bigint;
BEGIN
  SELECT count(*) INTO v_untriaged FROM volvra.verify() WHERE verdict = 'TAMPERED';
  -- the earlier deliberate tampering is still there, but retention must not
  -- have added to it
  ASSERT v_untriaged >= 1, 'the planted tampering is still reported';
  ASSERT (SELECT count(*) FROM volvra.verify()
          WHERE verdict = 'changed by recorded erasure or retention') >= 1,
    'a span emptied by retention is explained, not alarming';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.10 verification is read-only and leaks nothing ==='
DO $$
DECLARE v_before bigint; v_after bigint;
BEGIN
  SELECT count(*) INTO v_before FROM volvra.change_log;
  PERFORM count(*) FROM volvra.verify();
  SELECT count(*) INTO v_after FROM volvra.change_log;
  ASSERT v_before = v_after, 'verify() must not modify the history it checks';
END $$;

DO $$
DECLARE v_cols text;
BEGIN
  SELECT string_agg(a.attname, ',' ORDER BY a.attnum) INTO v_cols
  FROM pg_attribute a
  WHERE a.attrelid = 'volvra.seal'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
  ASSERT v_cols NOT LIKE '%old_row%' AND v_cols NOT LIKE '%new_row%',
    'seals carry hashes, never row content';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.11 verify() names the kind of interference ==='
DO $$
DECLARE r record; v_altered bigint; v_removed bigint;
BEGIN
  SELECT count(*) FILTER (WHERE kind = 'content altered in place'),
         count(*) FILTER (WHERE kind = 'rows removed')
    INTO v_altered, v_removed
  FROM volvra.verify();

  -- P4.3 did one of each, deliberately
  ASSERT v_altered >= 1,
    'a span whose rows are all present but whose hash changed is content alteration';
  ASSERT v_removed >= 1,
    'a span short of rows is a removal';

  -- and a clean span names nothing
  ASSERT (SELECT count(*) FROM volvra.verify()
          WHERE verdict = 'ok' AND kind IS NOT NULL) = 0,
    'a span that verifies has no interference to name';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.12 capture mode can be set per table ==='
DROP TABLE IF EXISTS narrow_hot;
CREATE TABLE narrow_hot (id int PRIMARY KEY, a int, b text);
SELECT volvra.enable('narrow_hot');
SELECT volvra.set_capture_mode('narrow_hot', 'full');
INSERT INTO narrow_hot VALUES (1, 1, 'keep');
UPDATE narrow_hot SET a = 2 WHERE id = 1;

DO $$
DECLARE r record;
BEGIN
  SELECT old_row, new_row INTO r FROM volvra.change_log
   WHERE table_name = 'public.narrow_hot' AND op = 'U';
  ASSERT r.old_row ? 'b',
    'this table asked for full images even though the global default is changed';
  ASSERT coalesce(volvra.get_setting('capture_updates'), 'changed') = 'changed',
    'and the global default is untouched';
END $$;

\echo '--- while another table still follows the global default ---'
DROP TABLE IF EXISTS wide_cold;
CREATE TABLE wide_cold (id int PRIMARY KEY, a int, blob text);
SELECT volvra.enable('wide_cold');
INSERT INTO wide_cold VALUES (1, 1, repeat('z', 4000));
UPDATE wide_cold SET a = 2 WHERE id = 1;
DO $$
DECLARE r record;
BEGIN
  SELECT old_row INTO r FROM volvra.change_log
   WHERE table_name = 'public.wide_cold' AND op = 'U';
  ASSERT NOT (r.old_row ? 'blob'),
    'a table with no override stores only the delta';
END $$;

\echo '--- resetting the override falls back to the setting ---'
SELECT volvra.set_capture_mode('narrow_hot', NULL);
UPDATE narrow_hot SET a = 3 WHERE id = 1;
DO $$
DECLARE r record;
BEGIN
  SELECT old_row INTO r FROM volvra.change_log
   WHERE table_name = 'public.narrow_hot' AND op = 'U'
   ORDER BY change_log.id DESC LIMIT 1;
  ASSERT NOT (r.old_row ? 'b'), 'NULL means follow capture_updates again';
END $$;

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.set_capture_mode('narrow_hot'::regclass, 'sometimes');
    RAISE EXCEPTION 'expected an invalid_parameter_value error';
  EXCEPTION WHEN invalid_parameter_value THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'an unknown mode must not be accepted silently';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.13 maintain() is the one thing to schedule ==='
SELECT step, detail, affected FROM volvra.maintain();

DO $$
DECLARE v_steps text;
BEGIN
  SELECT string_agg(step, ',' ORDER BY step) INTO v_steps FROM volvra.maintain();
  ASSERT v_steps LIKE '%partitions%', 'maintain extends partitions';
  ASSERT v_steps LIKE '%retention%',  'and applies retention';
  ASSERT v_steps LIKE '%sealed%',     'and seals';
  ASSERT v_steps LIKE '%critical%',   'and reports critical findings';

  -- it must leave nothing unsealed
  ASSERT (SELECT count(*) FROM volvra.change_log c
          WHERE c.id > coalesce((SELECT max(s.to_id) FROM volvra.seal s), 0)) = 0,
    'after maintain() the whole history is sealed';
END $$;

\echo '--- and its parts can be turned off ---'
DO $$
DECLARE v_steps text;
BEGIN
  SELECT string_agg(step, ',' ORDER BY step) INTO v_steps
  FROM volvra.maintain(p_purge => false, p_seal => false);
  ASSERT v_steps NOT LIKE '%retention%', 'purge can be skipped';
  ASSERT v_steps NOT LIKE '%sealed%',    'sealing can be skipped';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P4.14 preflight() checks what the docs assume ==='
SELECT severity, finding FROM volvra.preflight();

DO $$
DECLARE v_findings text;
BEGIN
  SELECT string_agg(finding, ' | ' ORDER BY finding) INTO v_findings
  FROM volvra.preflight();

  -- The correct behaviour differs by privilege context, so assert both
  -- directions rather than skipping one.  A superuser-owned SECURITY DEFINER
  -- capture must be flagged; a non-superuser-owned one must NOT be.
  IF (SELECT r.rolsuper
      FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
      WHERE p.oid = 'volvra.capture()'::regprocedure) THEN
    ASSERT v_findings LIKE '%owned by the superuser%',
      format('a superuser-owned SECURITY DEFINER capture must be flagged '
             'critical, got: %s', coalesce(v_findings, '(none)'));
    ASSERT (SELECT count(*) FROM volvra.preflight()
            WHERE severity = 'critical'
              AND finding LIKE 'volvra.capture() is owned by the superuser%') = 1,
      'and graded critical, not a warning';
  ELSE
    ASSERT coalesce(v_findings, '') NOT LIKE '%owned by the superuser%',
      format('a non-superuser install must NOT be flagged for superuser '
             'ownership, got: %s', v_findings);
    ASSERT (SELECT count(*) FROM volvra.preflight()
            WHERE severity = 'critical'
              AND finding LIKE '%superuser%') = 0,
      'a correctly-owned install has no superuser findings at all';
  END IF;

  -- strict_roles is off in the test database
  ASSERT v_findings LIKE '%strict_roles is off%', 'permissive role checks are flagged';
  -- pg_cron is not in the base image
  ASSERT v_findings LIKE '%pg_cron%', 'the absence of a scheduler is flagged';
END $$;

\echo '--- turning strict_roles on clears that finding ---'
SELECT volvra.set_setting('strict_roles', 'on');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.preflight()
          WHERE finding LIKE '%strict_roles%') = 0,
    'preflight reflects configuration, it does not just list boilerplate';
END $$;
SELECT volvra.set_setting('strict_roles', 'off');

-- ---------------------------------------------------------------------
\echo '=== P4.15 the installed code can be fingerprinted, and drift is caught ==='
SELECT scope, objects, left(sha256, 16) || '…' AS sha256 FROM volvra.fingerprint();

DO $$
DECLARE v_before text; v_after text;
BEGIN
  SELECT sha256 INTO v_before FROM volvra.fingerprint() WHERE scope = 'all';
  ASSERT v_before IS NOT NULL AND length(v_before) = 64, 'a sha256 is 64 hex chars';

  -- calling it twice must give the same answer, or it is useless for comparison
  SELECT sha256 INTO v_after FROM volvra.fingerprint() WHERE scope = 'all';
  ASSERT v_before = v_after, 'the fingerprint must be stable';
END $$;

\echo '--- altering a function after install changes it ---'
DO $$
DECLARE v_before text; v_after text; v_restored text;
BEGIN
  SELECT sha256 INTO v_before FROM volvra.fingerprint() WHERE scope = 'functions';

  -- the tamper a signature cannot see: the artifact was fine, the running code
  -- was changed afterwards
  CREATE OR REPLACE FUNCTION volvra._sha(p_text text) RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, pg_temp
  AS $body$ SELECT 'tampered' $body$;

  SELECT sha256 INTO v_after FROM volvra.fingerprint() WHERE scope = 'functions';
  ASSERT v_after <> v_before,
    'a function body altered after install must change the fingerprint';

  -- put it back
  CREATE OR REPLACE FUNCTION volvra._sha(p_text text) RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = pg_catalog, pg_temp
  AS $body$ SELECT encode(sha256(convert_to(coalesce(p_text, ''), 'UTF8')), 'hex') $body$;

  SELECT sha256 INTO v_restored FROM volvra.fingerprint() WHERE scope = 'functions';
  ASSERT v_restored = v_before,
    'and restoring it must restore the fingerprint exactly';
END $$;

\echo '--- adding a function to the schema changes it too ---'
DO $$
DECLARE v_before text; v_after text;
BEGIN
  SELECT sha256 INTO v_before FROM volvra.fingerprint() WHERE scope = 'functions';
  CREATE FUNCTION volvra._backdoor() RETURNS text
  LANGUAGE sql SECURITY DEFINER AS $body$ SELECT 'hello' $body$;
  SELECT sha256 INTO v_after FROM volvra.fingerprint() WHERE scope = 'functions';
  ASSERT v_after <> v_before,
    'a function smuggled into the schema must change the fingerprint';
  DROP FUNCTION volvra._backdoor();
END $$;

\echo '--- a new month partition must NOT change it ---'
DO $$
DECLARE v_before text; v_after text;
BEGIN
  SELECT sha256 INTO v_before FROM volvra.fingerprint() WHERE scope = 'all';
  PERFORM volvra._create_partition((now() + interval '36 months')::date);
  SELECT sha256 INTO v_after FROM volvra.fingerprint() WHERE scope = 'all';
  ASSERT v_after = v_before,
    'partitions carry the month in their name; a fingerprint that changed by '
    'itself every month would be ignored within weeks';
END $$;

\echo '--- preflight publishes it, and flags superuser-owned definers ---'
DO $$
DECLARE v_fp text; v_pf text;
BEGIN
  SELECT sha256 INTO v_fp FROM volvra.fingerprint() WHERE scope = 'all';
  SELECT detail INTO v_pf FROM volvra.preflight()
   WHERE finding = 'installed code fingerprint';
  ASSERT v_pf LIKE '%' || v_fp || '%',
    'preflight must report the same value fingerprint() returns';

  -- Context-dependent, so assert both directions.  Under a superuser install
  -- every SECURITY DEFINER function is a standing escalation and must be
  -- flagged; under the recommended install there is nothing to flag.
  IF (SELECT r.rolsuper
      FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
      WHERE p.oid = 'volvra.capture()'::regprocedure) THEN
    ASSERT (SELECT count(*) FROM volvra.preflight()
            WHERE severity = 'critical'
              AND finding LIKE '%SECURITY DEFINER%owned by a superuser%') = 1,
      'a superuser install must flag its definer functions';
  ELSE
    ASSERT (SELECT count(*) FROM volvra.preflight()
            WHERE severity = 'critical'
              AND finding LIKE '%SECURITY DEFINER%owned by a superuser%') = 0,
      'a non-superuser install must have no definer-ownership finding';
  END IF;
END $$;

\echo ''
\echo '*** ALL VOLVRA PHASE 4 CHECKS PASSED ***'
