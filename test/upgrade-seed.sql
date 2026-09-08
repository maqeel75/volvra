-- =====================================================================
-- Volvra upgrade test, part 1 -- run against the PREVIOUS schema
-- (test/fixtures/volvra-v1.sql), which has no version ledger at all.
--
-- Markers go in a table, not a GUC: the current schema is installed by a
-- separate psql session, and session settings do not survive that.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DO $$ BEGIN
  ASSERT (SELECT relkind FROM pg_class WHERE oid = 'volvra.change_log'::regclass) = 'r',
    'the v1 fixture should have an ordinary, unpartitioned change_log';
  ASSERT to_regclass('volvra.schema_version') IS NULL,
    'the v1 fixture predates the version ledger -- that is the point of this test';
END $$;

DROP TABLE IF EXISTS upg_marker;
DROP TABLE IF EXISTS upg_orders;
CREATE TABLE upg_marker (k text PRIMARY KEY, v text NOT NULL);
CREATE TABLE upg_orders (id int PRIMARY KEY, customer text, total numeric);

SELECT volvra.enable('upg_orders');
INSERT INTO upg_orders VALUES (1,'acme',100), (2,'globex',250);

SELECT clock_timestamp() AS t0 \gset
SELECT pg_sleep(0.05);
UPDATE upg_orders SET total = 0;              -- the accident, captured under v1

INSERT INTO upg_marker(k, v) VALUES
  ('t0',    :'t0'),
  ('rows',  (SELECT count(*)::text FROM volvra.change_log)),
  ('maxid', (SELECT max(id)::text  FROM volvra.change_log));

SELECT k, v FROM upg_marker ORDER BY k;

\echo ''
\echo '*** VOLVRA V1 FIXTURE SEEDED ***'
