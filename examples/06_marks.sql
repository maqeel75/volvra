-- Volvra example 6: marks, for rewinding to a named moment.
--
--   psql -f examples/06_marks.sql
--
-- A mark is a named moment, and undoing to a mark reverts everything
-- recorded since.  That makes a mark blunter than a transaction id: it is
-- for rewinding, not for undoing one specific mistake.

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (id int PRIMARY KEY, customer text, total numeric);

SELECT volvra.enable('orders');
INSERT INTO orders VALUES (1,'acme',100), (2,'globex',200);

SELECT volvra.unmark('before-deploy');

\echo ''
\echo '=== 1. name the moment before a deployment ==='
SELECT volvra.mark('before-deploy', 'release 042') AS marked_at;

\echo '=== 2. a second mark of the same name is refused ==='
-- A restore point people believe in must not be relocated silently.
SELECT volvra.mark('before-deploy');

\echo '=== 3. the deployment goes wrong ==='
SELECT pg_sleep(0.1);
UPDATE orders SET total = 0;
DELETE FROM orders WHERE id = 2;
SELECT * FROM orders ORDER BY id;

\echo '=== 4. what undoing to the mark would cost, before committing ==='
SELECT name, age, created_by, changes_since, tables_since, note
FROM volvra.marks();

\echo '=== 5. preview it ==='
SELECT seq, table_name, op, inverse_op, pk
FROM volvra.preview_undo_to('before-deploy');

\echo '=== 6. rewind ==='
SELECT seq, table_name, inverse_op, pk, status
FROM volvra.undo_to('before-deploy', confirm => true);
SELECT * FROM orders ORDER BY id;

\echo '=== 7. removing a mark removes a pointer, never the history ==='
SELECT volvra.unmark('before-deploy') AS removed;
SELECT count(*) AS history_rows FROM volvra.change_log
WHERE table_name = 'public.orders';
