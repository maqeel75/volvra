-- Volvra example 5: a TRUNCATE, and proving the history was not altered.
--
--   psql -f examples/05_truncate_and_integrity.sql
--
-- Row triggers never fire on TRUNCATE, so Volvra captures every row with a
-- statement trigger first.  Then two stages of integrity: the history
-- refuses to be rewritten, and when an administrator forces it anyway,
-- verification catches it.
--
-- The error in section 3 is the expected result.

DROP TABLE IF EXISTS audit_rows;
CREATE TABLE audit_rows (id int PRIMARY KEY, note text);

SELECT volvra.enable('audit_rows');
INSERT INTO audit_rows SELECT g, 'row ' || g FROM generate_series(1,50) g;

SELECT clock_timestamp() AS mark \gset
SELECT pg_sleep(0.1);

\echo ''
\echo '=== 1. truncate the table ==='
TRUNCATE audit_rows;
SELECT count(*) AS rows_now FROM audit_rows;

\echo '=== 2. even a TRUNCATE is reversible ==='
SELECT count(*) AS reverted
FROM volvra.undo('audit_rows', :'mark', now(), confirm => true);
SELECT count(*) AS restored, min(id), max(id) FROM audit_rows;

\echo '=== 3. seal the history, then verify it ==='
SELECT seal_id, from_id, to_id, row_count FROM volvra.seal();
SELECT seal_id, rows_sealed, rows_found, verdict FROM volvra.verify();

\echo '=== 4. a plain attempt to rewrite history is refused ==='
UPDATE volvra.change_log SET actor = 'mallory'
WHERE id = (SELECT min(id) FROM volvra.change_log);

\echo '=== 5. force it as only an administrator could ==='
BEGIN;
  SELECT set_config('volvra.allow_purge','on',true);
  UPDATE volvra.change_log
     SET old_row = NULL, new_row = NULL,
         redacted_at = clock_timestamp(), redacted_by = 'mallory'
   WHERE id = (SELECT min(id) FROM volvra.change_log);
COMMIT;

\echo '=== 6. verification catches it, and health calls it critical ==='
SELECT seal_id, rows_sealed, rows_found, verdict, kind FROM volvra.verify();
SELECT severity, problem FROM volvra.health();
