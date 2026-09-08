-- Volvra example 2: undo a DELETE, and read the audit trail.
--
--   psql -f examples/02_undo_a_delete.sql
--
-- Shows that reversing a delete is an insert, that the restored row is
-- identical, and that Volvra records two separate identities for every
-- change.

DROP TABLE IF EXISTS customers;
CREATE TABLE customers (id int PRIMARY KEY, email text NOT NULL, plan text);

SELECT volvra.enable('customers');
INSERT INTO customers VALUES (1,'ada@example.com','pro'), (2,'grace@example.com','free');

-- What the application declares it is doing.  Use SET LOCAL behind a
-- transaction-mode connection pooler.
SET volvra.actor = 'svc:billing';

SELECT clock_timestamp() AS mark \gset
SELECT pg_sleep(0.1);

\echo ''
\echo '=== 1. delete a customer ==='
DELETE FROM customers WHERE id = 1;
SELECT * FROM customers ORDER BY id;

\echo '=== 2. undo it: the inverse of a delete is an insert ==='
SELECT seq, op, inverse_op, pk, status
FROM volvra.undo('customers', :'mark', now(), confirm => true);
SELECT * FROM customers ORDER BY id;

\echo '=== 3. the audit trail for that row ==='
-- actor is app-declared and spoofable by design; db_user is authenticated
-- by the database and is the column to audit on.  The final I is Volvra's
-- own undo, captured like any other change.
SELECT change_id, op, actor, db_user, old_row, new_row
FROM volvra.history('customers', '{"id":1}') ORDER BY change_id;
