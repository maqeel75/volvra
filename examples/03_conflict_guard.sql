-- Volvra example 3: the conflict guard.
--
--   psql -f examples/03_conflict_guard.sql
--
-- A script zeroes every invoice.  Someone then fixes one of them by hand.
-- Volvra refuses to undo the script, because doing so would destroy that
-- fix, and offers to revert everything else instead.
--
-- The error in section 4 is the expected result, not a failure.

DROP TABLE IF EXISTS invoices;
CREATE TABLE invoices (id int PRIMARY KEY, client text, amount numeric);

SELECT volvra.enable('invoices');
INSERT INTO invoices VALUES (1,'acme',100), (2,'globex',200), (3,'initech',300);

SELECT clock_timestamp() AS pre_accident \gset
SELECT pg_sleep(0.1);

SET volvra.actor = 'oops:script';
UPDATE invoices SET amount = 0;                    -- the accident

SELECT pg_sleep(0.1);
SELECT clock_timestamp() AS post_accident \gset

SET volvra.actor = 'alice:finance';
UPDATE invoices SET amount = 555 WHERE id = 2;     -- a later, correct fix

\echo ''
\echo '=== 1. state after the accident and the later fix ==='
SELECT * FROM invoices ORDER BY id;

\echo '=== 2. preview flags only the row that moved on ==='
SELECT seq, pk, actor, conflict
FROM volvra.preview_undo('invoices', :'pre_accident', :'post_accident');

\echo '=== 3. undo refuses, and applies nothing (the error is the point) ==='
SELECT * FROM volvra.undo('invoices', :'pre_accident', :'post_accident',
                          confirm => true);

\echo '=== 4. nothing was applied ==='
SELECT * FROM invoices ORDER BY id;

\echo '=== 5. revert the rest, leave the conflicting row alone ==='
SELECT seq, pk, status
FROM volvra.undo('invoices', :'pre_accident', :'post_accident',
                 confirm => true, skip_conflicts => true);

\echo '=== 6. two rows restored, the later fix preserved ==='
SELECT * FROM invoices ORDER BY id;
