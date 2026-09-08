-- Volvra example 1: undo a mistaken UPDATE.
--
--   docker exec volvra-demo psql -U postgres -d shop \
--       -f /volvra/examples/01_simple_undo.sql
--
-- Re-runnable: the table is recreated each time.

DROP TABLE IF EXISTS employees;
CREATE TABLE employees (id int PRIMARY KEY, name text, salary numeric);

SELECT volvra.enable('employees');

INSERT INTO employees VALUES (1,'ada',50000), (2,'grace',60000), (3,'hopper',70000);

\echo ''
\echo '=== 1. starting state ==='
SELECT * FROM employees ORDER BY id;

-- Mark this moment.  Taken AFTER the inserts, so the undo below reverts only
-- the mistake; a window reaching further back would revert the inserts too.
SELECT clock_timestamp() AS before_mistake \gset
SELECT pg_sleep(0.1);

\echo '=== 2. the mistake: an UPDATE with no WHERE ==='
UPDATE employees SET salary = 0;
SELECT * FROM employees ORDER BY id;

\echo '=== 3. what volvra recorded ==='
SELECT change_id, op, actor, old_row -> 'salary' AS was, new_row -> 'salary' AS became
FROM volvra.history('employees', '{"id":1}') ORDER BY change_id;

\echo '=== 4. preview the undo (changes nothing) ==='
SELECT seq, op, inverse_op, pk, conflict
FROM volvra.preview_undo('employees', :'before_mistake', now());
SELECT * FROM employees ORDER BY id;

\echo '=== 5. apply the undo ==='
SELECT count(*) AS reverted
FROM volvra.undo('employees', :'before_mistake', now(), confirm => true);

\echo '=== 6. restored ==='
SELECT * FROM employees ORDER BY id;
