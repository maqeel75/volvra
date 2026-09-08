-- =====================================================================
-- Volvra upgrade test, part 1 -- run against the PREVIOUS RELEASE's
-- schema, from test/fixtures/volvra-<version>.sql.
--
-- Markers go in a table, not a GUC: the current schema is installed by a
-- separate psql session, and session settings do not survive that.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DO $$ BEGIN
  -- The fixture is a released schema, so it has a version ledger and a
  -- partitioned history. Asserting the shape here means a fixture captured
  -- wrongly fails now, with a clear reason, rather than making the upgrade
  -- assertions below quietly meaningless.
  ASSERT to_regclass('volvra.schema_version') IS NOT NULL,
    'the fixture must be a released schema, which has a version ledger';
  ASSERT (SELECT relkind FROM pg_class WHERE oid = 'volvra.change_log'::regclass) = 'p',
    'a released change_log is partitioned';
  ASSERT volvra.version() >= 1,
    format('the fixture reports schema version %s', volvra.version());
END $$;

DROP TABLE IF EXISTS upg_marker;
DROP TABLE IF EXISTS upg_orders;
CREATE TABLE upg_marker (k text PRIMARY KEY, v text NOT NULL);

-- Real history, made through the fixture's own capture path: history written
-- by the previous release is exactly what the upgrade has to keep usable.
CREATE TABLE upg_orders (id int PRIMARY KEY, customer text, total numeric);
SELECT volvra.enable('upg_orders');

INSERT INTO upg_marker(k, v) SELECT 'schema_before', volvra.version()::text;
INSERT INTO upg_orders VALUES (1, 'acme', 100), (2, 'globex', 250);

INSERT INTO upg_marker(k, v) SELECT 't0', clock_timestamp()::text;
SELECT pg_sleep(0.05);
UPDATE upg_orders SET total = 0;          -- the accident, pre-upgrade

INSERT INTO upg_marker(k, v) SELECT 'rows',  count(*)::text FROM volvra.change_log;
INSERT INTO upg_marker(k, v) SELECT 'maxid', max(id)::text  FROM volvra.change_log;

-- Seal before the upgrade: a seal chain that stops verifying across an
-- upgrade would make the history unprovable exactly when someone needs it.
SELECT count(*) FROM volvra.seal();
INSERT INTO upg_marker(k, v) SELECT 'seals', count(*)::text FROM volvra.seal;
INSERT INTO upg_marker(k, v)
  SELECT 'chain', coalesce(max(chain_hash), '') FROM volvra.seal;

SELECT k, v FROM upg_marker ORDER BY k;
