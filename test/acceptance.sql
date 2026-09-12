-- =====================================================================
-- pgVolvra v0 acceptance test  (steps 1-6 of HANDOFF.md)
-- Any failed assertion raises -> psql exits non-zero under ON_ERROR_STOP.
-- =====================================================================
\set ON_ERROR_STOP on
\timing off
\pset pager off

\echo '=== 0. environment ==='
SELECT current_setting('server_version') AS server_version;

-- ---------------------------------------------------------------------
\echo '=== 1. create table, seed rows, enable capture ==='
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
  id        int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer  text NOT NULL,
  total     numeric(10,2) NOT NULL,
  note      text,
  total_x2  numeric(12,2) GENERATED ALWAYS AS (total * 2) STORED  -- generated col
);

-- Arm the table BEFORE any data lands, so the seed inserts are captured too.
SELECT volvra.enable('orders');

-- App-supplied actor, as an application would set it
SELECT set_config('volvra.actor', 'app:checkout-svc', false);

INSERT INTO orders (customer, total, note) VALUES
  ('acme',   100.00, 'first'),
  ('globex',  42.50, NULL),
  ('initech', 999.99, 'big one');

SELECT clock_timestamp() AS t0 \gset
SELECT pg_sleep(0.05);

-- ---------------------------------------------------------------------
\echo '=== 2. the accident: UPDATE with no WHERE ==='
UPDATE orders SET total = 0;

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM orders WHERE total = 0) = 3,
         'setup: all totals should be zeroed';
  ASSERT (SELECT count(*) FROM volvra.change_log WHERE op = 'U') = 3,
         'capture: 3 UPDATE rows expected in change_log';
  ASSERT (SELECT count(*) FROM volvra.change_log WHERE op = 'I') = 3,
         'capture: 3 INSERT rows expected in change_log';
  ASSERT (SELECT count(DISTINCT actor) FROM volvra.change_log WHERE op='U') = 1
         AND (SELECT actor FROM volvra.change_log WHERE op='U' LIMIT 1) = 'app:checkout-svc',
         'actor: volvra.actor GUC should override session_user';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 3. preview_undo -- shows compensating SQL, changes nothing ==='
SELECT seq, op, inverse_op, pk, left(stmt, 90) || '...' AS compensating_sql
FROM volvra.preview_undo('orders', :'t0', now());

SELECT set_config('test.t0', :'t0', false);

-- undo(confirm => false) must behave exactly like preview
SELECT count(*) AS unconfirmed_undo_rows FROM volvra.undo('orders', :'t0', now());

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM volvra.preview_undo(
            'orders', current_setting('test.t0')::timestamptz, now())) = 3,
         'preview: 3 compensating statements expected';
  ASSERT (SELECT count(*) FROM orders WHERE total = 0) = 3,
         'preview MUST NOT execute anything';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 4. undo(confirm => true) -- totals restored ==='
SELECT seq, inverse_op, pk FROM volvra.undo('orders', :'t0', now(), confirm => true);

SELECT id, customer, total, note, total_x2 FROM orders ORDER BY id;

DO $$
BEGIN
  ASSERT (SELECT total FROM orders WHERE customer='acme')    = 100.00, 'undo: acme total';
  ASSERT (SELECT total FROM orders WHERE customer='globex')  =  42.50, 'undo: globex total';
  ASSERT (SELECT total FROM orders WHERE customer='initech') = 999.99, 'undo: initech total';
  ASSERT (SELECT count(*) FROM orders) = 3, 'undo: row count unchanged';
  ASSERT (SELECT total_x2 FROM orders WHERE customer='acme') = 200.00,
         'undo: GENERATED column recomputed, not written';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 5. history() -- every version of row 1, with actor ==='
SELECT change_id, op, actor,
       old_row -> 'total' AS old_total,
       new_row -> 'total' AS new_total
FROM volvra.history('orders', '{"id":1}')
ORDER BY change_id;

DO $$
DECLARE v_ops text;
BEGIN
  SELECT string_agg(op, '' ORDER BY change_id) INTO v_ops
  FROM volvra.history('orders', '{"id":1}');
  ASSERT v_ops = 'IUU', format('history: expected I,U,U for row 1, got %s', v_ops);
END $$;

-- ---------------------------------------------------------------------
\echo '=== 6. undo the undo -- reversibility ==='
SELECT clock_timestamp() AS t1 \gset
SELECT pg_sleep(0.05);
UPDATE orders SET note = 'edited' WHERE id = 2;
SELECT pg_sleep(0.05);
SELECT clock_timestamp() AS t2 \gset

-- forward undo of that edit
SELECT count(*) FROM volvra.undo('orders', :'t1', :'t2', confirm => true);
DO $$ BEGIN
  ASSERT (SELECT note FROM orders WHERE id=2) IS NULL, 'undo: note reverted to NULL';
END $$;

-- now undo the undo
SELECT pg_sleep(0.05);
SELECT count(*) FROM volvra.undo('orders', :'t2', clock_timestamp(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT note FROM orders WHERE id=2) = 'edited',
         'undo-the-undo: note should be back to ''edited''';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 7. DELETE is reversible (row resurrection, identity preserved) ==='
SELECT clock_timestamp() AS t3 \gset
SELECT pg_sleep(0.05);
DELETE FROM orders WHERE id = 3;
DO $$ BEGIN ASSERT (SELECT count(*) FROM orders) = 2, 'delete happened'; END $$;

SELECT count(*) FROM volvra.undo('orders', :'t3', clock_timestamp(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM orders) = 3, 'delete undone: row count back to 3';
  ASSERT (SELECT customer FROM orders WHERE id = 3) = 'initech',
         'delete undone: same pk and payload restored';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 8. INSERT is reversible ==='
SELECT clock_timestamp() AS t4 \gset
SELECT pg_sleep(0.05);
INSERT INTO orders (customer, total) VALUES ('oops-corp', 1.00);
DO $$ BEGIN ASSERT (SELECT count(*) FROM orders) = 4, 'insert happened'; END $$;

SELECT count(*) FROM volvra.undo('orders', :'t4', clock_timestamp(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM orders WHERE customer='oops-corp') = 0,
         'insert undone: row removed';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 9. primary-key-changing UPDATE reverts correctly ==='
-- Needs a natural (non-identity) key: Postgres forbids updating a
-- GENERATED ALWAYS AS IDENTITY column at all.
DROP TABLE IF EXISTS accounts;
CREATE TABLE accounts (code text PRIMARY KEY, owner text NOT NULL);
SELECT volvra.enable('accounts');
INSERT INTO accounts VALUES ('A-1', 'ada'), ('A-2', 'grace');

SELECT clock_timestamp() AS t5 \gset
SELECT pg_sleep(0.05);
UPDATE accounts SET code = 'ZZZ' WHERE code = 'A-2';
SELECT count(*) FROM volvra.undo('accounts', :'t5', clock_timestamp(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM accounts WHERE code = 'A-2') = 1, 'pk change reverted';
  ASSERT (SELECT count(*) FROM accounts WHERE code = 'ZZZ') = 0, 'new pk gone';
  ASSERT (SELECT owner FROM accounts WHERE code = 'A-2') = 'grace', 'payload intact';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 10. blast-radius guard ==='
DO $$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    PERFORM volvra.undo('orders', '-infinity'::timestamptz, now(),
                        confirm => true, max_rows => 1);
  EXCEPTION WHEN program_limit_exceeded THEN
    v_ok := true;
  END;
  ASSERT v_ok, 'blast-radius guard should have raised program_limit_exceeded';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 11. change_log is append-only ==='
DO $$
DECLARE v_upd boolean := false; v_del boolean := false;
BEGIN
  BEGIN UPDATE volvra.change_log SET actor = 'mallory' WHERE id = 1;
  EXCEPTION WHEN insufficient_privilege THEN v_upd := true; END;
  BEGIN DELETE FROM volvra.change_log WHERE id = 1;
  EXCEPTION WHEN insufficient_privilege THEN v_del := true; END;
  ASSERT v_upd, 'change_log UPDATE should be blocked';
  ASSERT v_del, 'change_log DELETE should be blocked';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 12. undo attempts are audited ==='
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.undo_log) >= 6, 'undo_log should record every attempt';
  ASSERT (SELECT count(*) FROM volvra.undo_log WHERE NOT confirmed) >= 1,
         'undo_log should record previews too';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 13. purge respects retention, append-only otherwise ==='
SELECT volvra.purge('100 years'::interval) AS purged_rows;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log) > 0, 'purge should not have removed recent rows';
END $$;

-- ---------------------------------------------------------------------
\echo '=== 14. disable stops capture, keeps history ==='
SELECT volvra.disable('orders');
SELECT set_config('test.hb', count(*)::text, false) FROM volvra.change_log;
UPDATE orders SET note = 'after-disable' WHERE id = 1;
DO $$
DECLARE v_now bigint;
BEGIN
  SELECT count(*) INTO v_now FROM volvra.change_log;
  ASSERT v_now = current_setting('test.hb')::bigint,
         'disable: no new change_log rows expected';
END $$;

\echo ''
\echo '*** ALL VOLVRA ACCEPTANCE CHECKS PASSED ***'
