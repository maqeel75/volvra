-- =====================================================================
-- Volvra upgrade test, part 2 -- run after the CURRENT schema has been
-- installed over the seeded v1 database.
--
-- This is what makes "you can upgrade volvra" a fact rather than an
-- intention: once a customer has history, a reinstall that reshapes a
-- table is data loss.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== U1. a pre-release install was adopted and repaired in place ==='
SELECT version, note FROM volvra.schema_version ORDER BY version;

DO $$
BEGIN
  -- Nothing has been released, so however old the database was, it lands on
  -- one schema version.  A development history is not a release history.
  ASSERT (SELECT count(*) FROM volvra.schema_version) = 1,
    format('expected exactly one schema version, got %s',
           (SELECT count(*) FROM volvra.schema_version));
  ASSERT volvra.version() = 1,
    format('expected version 1, got %s', volvra.version());

  ASSERT (SELECT note FROM volvra.schema_version WHERE version = 1)
         LIKE 'adopted%',
    'an install that predates the ledger must be recorded as adopted, not as a fresh install';
  ASSERT (SELECT note FROM volvra.schema_version WHERE version = 1)
         LIKE '%history row(s) preserved%',
    'and the repair must record how much history it carried across';
END $$;

\echo '=== U2. every history row survived, and only then was the original dropped ==='
DO $$
DECLARE
  v_expected bigint := (SELECT v::bigint FROM upg_marker WHERE k = 'rows');
  v_actual   bigint;
BEGIN
  ASSERT (SELECT relkind FROM pg_class WHERE oid = 'volvra.change_log'::regclass) = 'p',
    'change_log is now partitioned';
  ASSERT to_regclass('volvra.change_log_v1') IS NULL,
    'the original table is gone';

  SELECT count(*) INTO v_actual FROM volvra.change_log;
  ASSERT v_actual = v_expected,
    format('history must survive the upgrade: had %s rows, now %s', v_expected, v_actual);
END $$;

\echo '=== U3. ids and the sequence carried over ==='
DO $$
DECLARE
  v_maxid   bigint := (SELECT v::bigint FROM upg_marker WHERE k = 'maxid');
  v_nextval bigint;
BEGIN
  ASSERT (SELECT max(id) FROM volvra.change_log) = v_maxid,
    'row ids are preserved, so anything referencing a change id still resolves';
  SELECT nextval('volvra.change_log_id_seq') INTO v_nextval;
  ASSERT v_nextval > v_maxid,
    format('the sequence must continue past %s, produced %s', v_maxid, v_nextval);
END $$;

\echo '=== U4. pre-upgrade history is still usable for an undo ==='
DO $$
DECLARE v_ops text;
BEGIN
  SELECT string_agg(op, '' ORDER BY change_id) INTO v_ops
  FROM volvra.history('upg_orders', '{"id":1}');
  ASSERT v_ops = 'IU',
    format('history() over migrated rows should show I then U, got %s', v_ops);
END $$;

SELECT count(*) AS reverted
FROM volvra.undo('upg_orders',
                 (SELECT v::timestamptz FROM upg_marker WHERE k = 't0'),
                 now(), confirm => true);

DO $$ BEGIN
  ASSERT (SELECT total FROM upg_orders WHERE id = 1) = 100,
    'an undo driven entirely by pre-upgrade history still restores the row';
  ASSERT (SELECT total FROM upg_orders WHERE id = 2) = 250, 'both rows';
END $$;

\echo '=== U5. capture continues into the new partitions ==='
UPDATE upg_orders SET total = 555 WHERE id = 1;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log_default) = 0,
    'new writes go to a month partition, not the default';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.upg_orders') >= 4, 'and are captured';
END $$;

\echo '=== U6. phase 2 features work on a migrated database ==='
BEGIN;
  SELECT txid_current() AS utx \gset
  UPDATE upg_orders SET customer = 'migrated' WHERE id = 1;
COMMIT;
SELECT count(*) FROM volvra.undo_txid(:utx, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT customer FROM upg_orders WHERE id = 1) = 'acme',
    'txid-scoped undo works after the upgrade';
END $$;

\echo '=== U7. repeat installs change nothing ==='
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.schema_version) = 1,
    'a repeat install must not add a ledger row';
  ASSERT (SELECT count(*) FROM volvra.schema_version)
         = (SELECT count(DISTINCT version) FROM volvra.schema_version),
    'no version is recorded twice';
  -- The repair is shape-guarded, so a second run must find nothing to do.
  ASSERT (SELECT relkind FROM pg_class WHERE oid='volvra.change_log'::regclass) = 'p',
    'change_log is partitioned and stays partitioned';
END $$;

\echo ''
\echo '*** VOLVRA UPGRADE FROM V1 PASSED ***'
