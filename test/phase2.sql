-- =====================================================================
-- pgVolvra phase 2 -- scope
--
-- Gate: a person can express the accident they actually had, without
-- translating it into a time window first.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== P2.1 a bad migration is one transaction across several tables ==='
DROP TABLE IF EXISTS line_items;
DROP TABLE IF EXISTS orders_p2;
CREATE TABLE orders_p2  (id int PRIMARY KEY, customer text, total numeric);
CREATE TABLE line_items (id int PRIMARY KEY, order_id int, sku text, qty int);

SELECT volvra.enable('orders_p2');
SELECT volvra.enable('line_items');

INSERT INTO orders_p2  VALUES (1,'acme',100), (2,'globex',250);
INSERT INTO line_items VALUES (10,1,'widget',5), (11,2,'gizmo',3);

-- innocent traffic before the migration, which must survive untouched
UPDATE orders_p2 SET total = 110 WHERE id = 1;

-- the migration: one transaction, two tables, both wrong
BEGIN;
  SELECT txid_current() AS bad_txid \gset
  UPDATE orders_p2  SET total = 0;
  UPDATE line_items SET qty = 0;
  INSERT INTO line_items VALUES (12, 1, 'accidental', 1);
COMMIT;

SELECT set_config('test.bad_txid', :'bad_txid', false);

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM orders_p2 WHERE total = 0) = 2, 'migration ran';
  ASSERT (SELECT count(*) FROM line_items) = 3, 'migration inserted a row';
END $$;

\echo '--- preview names both tables ---'
SELECT seq, table_name, op, inverse_op, pk
FROM volvra.preview_undo_txid(:bad_txid);

DO $$
DECLARE v_tabs bigint;
BEGIN
  SELECT count(DISTINCT table_name) INTO v_tabs
  FROM volvra.preview_undo_txid(current_setting('test.bad_txid')::bigint);
  ASSERT v_tabs = 2, format('plan should span 2 tables, got %s', v_tabs);
END $$;

\echo '--- one call undoes the whole migration ---'
SELECT count(*) AS reverted
FROM volvra.undo_txid(:bad_txid, confirm => true);

DO $$ BEGIN
  ASSERT (SELECT total FROM orders_p2 WHERE id = 1) = 110,
         'the pre-migration update survived: undo reverted the txid, not a window';
  ASSERT (SELECT total FROM orders_p2 WHERE id = 2) = 250, 'order 2 restored';
  ASSERT (SELECT qty FROM line_items WHERE id = 10) = 5, 'line item restored';
  ASSERT (SELECT count(*) FROM line_items WHERE id = 12) = 0,
         'the accidental insert is gone';
  ASSERT (SELECT count(*) FROM line_items) = 2, 'row count restored';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.2 transactions() is how you find the mistake ==='
SELECT txid, tables, inserts, updates, deletes, changes
FROM volvra.transactions()
ORDER BY txid
LIMIT 5;

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.transactions()
  WHERE txid = current_setting('test.bad_txid')::bigint;
  ASSERT r.changes = 5, format('the migration touched 5 rows, reported %s', r.changes);
  ASSERT r.updates = 4 AND r.inserts = 1, 'op breakdown';
  ASSERT array_length(r.tables, 1) = 2, 'both tables listed';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.3 predicate scoping: undo only the rows that match ==='
SELECT clock_timestamp() AS p0 \gset
SELECT pg_sleep(0.05);
UPDATE orders_p2 SET customer = 'CLOBBERED';
SELECT set_config('test.p0', :'p0', false);

SELECT count(*) AS reverted
FROM volvra.undo('orders_p2', :'p0', now(), confirm => true,
                 predicate => $$old_row->>'customer' = 'acme'$$);

DO $$ BEGIN
  ASSERT (SELECT customer FROM orders_p2 WHERE id = 1) = 'acme',
         'the matching row was reverted';
  ASSERT (SELECT customer FROM orders_p2 WHERE id = 2) = 'CLOBBERED',
         'the non-matching row was left alone';
END $$;

-- clean up the rest by predicate on the other value
SELECT count(*) FROM volvra.undo('orders_p2', :'p0', now(), confirm => true,
                                 predicate => $$old_row->>'customer' = 'globex'$$);
DO $$ BEGIN
  ASSERT (SELECT customer FROM orders_p2 WHERE id = 2) = 'globex', 'and now that one too';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.4 actor scoping: undo everything one service did ==='
SELECT clock_timestamp() AS a0 \gset
SELECT pg_sleep(0.05);

SELECT set_config('volvra.actor', 'svc:pricing', false);
UPDATE orders_p2 SET total = 1 WHERE id = 1;
SELECT set_config('volvra.actor', 'svc:billing', false);
UPDATE orders_p2 SET total = 2 WHERE id = 2;
SELECT set_config('volvra.actor', '', false);
SELECT set_config('test.a0', :'a0', false);

SELECT count(*) AS reverted
FROM volvra.undo('orders_p2', :'a0', now(), confirm => true, actor => 'svc:pricing');

DO $$ BEGIN
  ASSERT (SELECT total FROM orders_p2 WHERE id = 1) = 110,
         'the pricing service''s change was reverted';
  ASSERT (SELECT total FROM orders_p2 WHERE id = 2) = 2,
         'the billing service''s change was untouched';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.5 multi-table undo and foreign keys ==='
DROP TABLE IF EXISTS child_p2;
DROP TABLE IF EXISTS parent_p2;
CREATE TABLE parent_p2 (id int PRIMARY KEY, name text);
CREATE TABLE child_p2  (id int PRIMARY KEY,
                        parent_id int NOT NULL REFERENCES parent_p2(id) ON DELETE CASCADE,
                        v text);
SELECT volvra.enable('parent_p2');
SELECT volvra.enable('child_p2');
INSERT INTO parent_p2 VALUES (1,'p1');
INSERT INTO child_p2  VALUES (10,1,'c1'), (11,1,'c2');

-- A cascade captures the parent FIRST and the children after, so reverse
-- chronological order tries to resurrect a child before its parent.
BEGIN;
  SELECT txid_current() AS fk_txid \gset
  DELETE FROM parent_p2 WHERE id = 1;
COMMIT;
SELECT set_config('test.fk_txid', :'fk_txid', false);

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM child_p2)  = 0, 'cascade emptied the child table';
  ASSERT (SELECT count(*) FROM parent_p2) = 0, 'and the parent';
END $$;

\echo '--- with a non-deferrable FK, undo refuses and names the fix ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo_txid(current_setting('test.fk_txid')::bigint, confirm => true);
    RAISE EXCEPTION 'PHASE 2 FAILURE: expected a foreign key refusal';
  EXCEPTION WHEN foreign_key_violation THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'a non-deferrable FK must produce a clear refusal';
  ASSERT (SELECT count(*) FROM parent_p2) = 0, 'nothing was half-applied';
END $$;

\echo '--- make_fks_deferrable() once, then the same undo works ---'
SELECT constraint_name, table_name, status
FROM volvra.make_fks_deferrable('public')
WHERE table_name = 'public.child_p2';

SELECT count(*) AS reverted
FROM volvra.undo_txid(:fk_txid, confirm => true);

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM parent_p2) = 1, 'parent resurrected';
  ASSERT (SELECT count(*) FROM child_p2)  = 2, 'both children resurrected';
  ASSERT (SELECT v FROM child_p2 WHERE id = 11) = 'c2', 'payload intact';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.6 covering a whole schema ==='
DROP SCHEMA IF EXISTS app CASCADE;
CREATE SCHEMA app;
CREATE TABLE app.with_pk    (id int PRIMARY KEY, v text);
CREATE TABLE app.also_pk    (id int PRIMARY KEY, v text);
CREATE TABLE app.no_pk      (v text);

SELECT table_name, status, detail FROM volvra.enable_all('app') ORDER BY table_name;

DO $$
DECLARE v_covered bigint; v_skipped bigint;
BEGIN
  SELECT count(*) FILTER (WHERE status IN ('covered','already covered')),
         count(*) FILTER (WHERE status = 'skipped')
    INTO v_covered, v_skipped
  FROM volvra.enable_all('app');
  ASSERT v_covered = 2, format('two tables have a pk, covered %s', v_covered);
  ASSERT v_skipped = 1, 'the pk-less table is skipped, not failed';
END $$;

\echo '--- and it is idempotent, so it doubles as a post-migration sync ---'
CREATE TABLE app.added_later (id int PRIMARY KEY, v text);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.uncovered('app')) = 2,
         'the new table and the pk-less one show as uncovered';
  PERFORM volvra.enable_all('app');
  ASSERT (SELECT count(*) FROM volvra.uncovered('app')
          WHERE reason = 'never covered') = 0,
         'sync covered the new table';
  ASSERT (SELECT count(*) FROM volvra.uncovered('app')) = 1,
         'the pk-less table remains, correctly, uncoverable';
END $$;

\echo '--- capture really works on a table covered by enable_all ---'
INSERT INTO app.added_later VALUES (1, 'x');
SELECT clock_timestamp() AS s0 \gset
SELECT pg_sleep(0.05);
UPDATE app.added_later SET v = 'wrecked';
SELECT count(*) FROM volvra.undo('app.added_later', :'s0', now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM app.added_later WHERE id = 1) = 'x', 'enable_all covered it properly';
END $$;

SELECT count(*) AS uncovered FROM volvra.disable_all('app');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.uncovered('app')) = 4, 'all four now uncovered';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.7 status() sees a trigger disabled behind volvra''s back ==='
DO $$
DECLARE v_covered boolean;
BEGIN
  SELECT covered INTO v_covered FROM volvra.status() WHERE table_name = 'public.orders_p2';
  ASSERT v_covered, 'orders_p2 should report covered';
END $$;

ALTER TABLE orders_p2 DISABLE TRIGGER volvra_capture;
DO $$
DECLARE v_covered boolean;
BEGIN
  SELECT covered INTO v_covered FROM volvra.status() WHERE table_name = 'public.orders_p2';
  ASSERT NOT v_covered,
         'status() must report a registered table whose trigger is disabled as uncovered';
END $$;
ALTER TABLE orders_p2 ENABLE TRIGGER volvra_capture;

-- ---------------------------------------------------------------------
\echo '=== P2.8 an undo with no scope at all is refused ==='
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo(confirm => true);
    RAISE EXCEPTION 'PHASE 2 FAILURE: unscoped undo was allowed';
  EXCEPTION WHEN null_value_not_allowed THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'undo must refuse to plan over everything by accident';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.9 a predicate cannot become a second statement ==='
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.preview_undo('orders_p2'::regclass,
              predicate => 'true); DROP TABLE line_items; --');
    RAISE EXCEPTION 'SECURITY FAILURE: predicate injection was accepted';
  EXCEPTION WHEN syntax_error THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'a predicate containing ; or -- must be refused';
  ASSERT to_regclass('public.line_items') IS NOT NULL,
         'SECURITY FAILURE: injected statement executed';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.10 a multi-table undo is itself undoable ==='
SELECT txid AS undo_txid FROM volvra.transactions() ORDER BY ended DESC LIMIT 1 \gset
DO $$
DECLARE v_qty int;
BEGIN
  -- the FK resurrection above was the most recent undo; walk it back again
  SELECT count(*) INTO v_qty FROM parent_p2;
  ASSERT v_qty = 1, 'starting from the restored state';
END $$;

BEGIN;
  SELECT txid_current() AS r_txid \gset
  UPDATE child_p2 SET v = 'round two' WHERE id = 10;
  UPDATE parent_p2 SET name = 'round two' WHERE id = 1;
COMMIT;

SELECT count(*) FROM volvra.undo_txid(:r_txid, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM child_p2 WHERE id = 10) = 'c1', 'child reverted';
  ASSERT (SELECT name FROM parent_p2 WHERE id = 1) = 'p1', 'parent reverted';
END $$;

-- and undo the undo, by its own txid
SELECT txid AS second_txid FROM volvra.transactions() ORDER BY ended DESC LIMIT 1 \gset
SELECT count(*) FROM volvra.undo_txid(:second_txid, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM child_p2 WHERE id = 10) = 'round two',
         'undoing the undo restored the change';
  ASSERT (SELECT name FROM parent_p2 WHERE id = 1) = 'round two',
         'across both tables';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.11 an undo that finds nothing says why ==='
DROP TABLE IF EXISTS never_covered_t;
CREATE TABLE never_covered_t (id int PRIMARY KEY, v text);
INSERT INTO never_covered_t VALUES (1, 'original');
UPDATE never_covered_t SET v = 'clobbered';        -- unrecoverable, by definition

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo('never_covered_t'::regclass, '-infinity'::timestamptz,
                        now(), confirm => true);
    RAISE EXCEPTION 'FAILURE: undo reported nothing to do instead of no coverage';
  EXCEPTION WHEN invalid_parameter_value THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused',
    '"0 changes reverted" would read as "we are fine" during an incident';
END $$;

\echo '--- preview says the same, rather than showing an empty plan ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM * FROM volvra.preview_undo('never_covered_t'::regclass,
                                       '-infinity'::timestamptz, now());
    RAISE EXCEPTION 'FAILURE: preview showed an empty plan for an uncovered table';
  EXCEPTION WHEN invalid_parameter_value THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'an empty plan and no coverage are different answers';
END $$;

\echo '--- but a table covered in the past can still be undone ---'
DROP TABLE IF EXISTS was_covered;
CREATE TABLE was_covered (id int PRIMARY KEY, v text);
SELECT volvra.enable('was_covered');
INSERT INTO was_covered VALUES (1, 'good');
SELECT clock_timestamp() AS w0 \gset
SELECT pg_sleep(0.05);
UPDATE was_covered SET v = 'bad';
SELECT volvra.disable('was_covered');              -- history is retained
SELECT set_config('test.w0', :'w0', false);

SELECT count(*) AS reverted
FROM volvra.undo('was_covered', :'w0', now(), confirm => true);

DO $$ BEGIN
  ASSERT (SELECT v FROM was_covered WHERE id = 1) = 'good',
    'stopping coverage keeps the history, so the undo must still work';
END $$;

\echo '--- and finding genuinely nothing in a window is still just zero ---'
DO $$
DECLARE v_n bigint;
BEGIN
  -- a window that provably contains nothing, rather than "recently"
  SELECT count(*) INTO v_n
  FROM volvra.undo('orders_p2'::regclass,
                   '2000-01-01'::timestamptz, '2000-01-02'::timestamptz,
                   confirm => true);
  ASSERT v_n = 0,
    'a covered table with no changes in the window is not an error';
END $$;

-- ---------------------------------------------------------------------
\echo '=== P2.12 marks name a moment you can come back to ==='
DROP TABLE IF EXISTS marked_t;
CREATE TABLE marked_t (id int PRIMARY KEY, v text);
SELECT volvra.enable('marked_t');
INSERT INTO marked_t VALUES (1,'a'), (2,'b');

SELECT volvra.unmark('m1');
SELECT volvra.mark('m1', 'first restore point') AS marked_at;
SELECT pg_sleep(0.05);
UPDATE marked_t SET v = 'wrecked';
DELETE FROM marked_t WHERE id = 2;

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM volvra.marks() WHERE name = 'm1';
  ASSERT r.changes_since = 3,
    format('marks() must count what undoing would touch, got %s', r.changes_since);
  ASSERT r.tables_since = 1, 'and how many tables';
  ASSERT r.note = 'first restore point', 'and carry the note';
  ASSERT r.age > interval '0', 'and an age';
END $$;

\echo '--- preview_undo_to and undo_to agree with the count ---'
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.preview_undo_to('m1')) = 3,
    'preview_undo_to plans the same change set';
END $$;

SELECT count(*) AS reverted FROM volvra.undo_to('m1', confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM marked_t) = 2, 'the deleted row came back';
  ASSERT (SELECT v FROM marked_t WHERE id = 1) = 'a', 'and the values are restored';
  ASSERT (SELECT v FROM marked_t WHERE id = 2) = 'b', 'both of them';
END $$;

\echo '--- a duplicate name is refused rather than silently moved ---'
DO $$
DECLARE v_state text; v_at timestamptz;
BEGIN
  SELECT at INTO v_at FROM volvra.restore_point WHERE name = 'm1';
  BEGIN
    PERFORM volvra.mark('m1');
    RAISE EXCEPTION 'FAILURE: a duplicate mark was accepted';
  EXCEPTION WHEN unique_violation THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused',
    'a restore point people believe in must not be quietly relocated';
  ASSERT (SELECT at FROM volvra.restore_point WHERE name = 'm1') = v_at,
    'and the original moment is untouched';
END $$;

\echo '--- but p_replace moves it deliberately ---'
DO $$
DECLARE v_before timestamptz; v_after timestamptz;
BEGIN
  SELECT at INTO v_before FROM volvra.restore_point WHERE name = 'm1';
  PERFORM pg_sleep(0.05);
  PERFORM volvra.mark('m1', 'moved', p_replace => true);
  SELECT at INTO v_after FROM volvra.restore_point WHERE name = 'm1';
  ASSERT v_after > v_before, 'p_replace moves the mark forward';
  ASSERT (SELECT note FROM volvra.restore_point WHERE name = 'm1') = 'moved',
    'and updates the note';
END $$;

\echo '--- an unknown mark is a clear error, not an empty plan ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo_to('no-such-mark', confirm => true);
    RAISE EXCEPTION 'FAILURE: undo_to accepted an unknown mark';
  EXCEPTION WHEN invalid_parameter_value THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused', 'an unknown mark must name itself';
END $$;

\echo '--- unmark removes the pointer, never the history ---'
DO $$
DECLARE v_history bigint;
BEGIN
  SELECT count(*) INTO v_history FROM volvra.change_log
   WHERE table_name = 'public.marked_t';
  ASSERT volvra.unmark('m1'), 'unmark reports that it removed one';
  ASSERT NOT volvra.unmark('m1'), 'and reports false the second time';
  ASSERT (SELECT count(*) FROM volvra.change_log
          WHERE table_name = 'public.marked_t') = v_history,
    'removing a mark must not touch the history';
END $$;

\echo '--- a mark reverts everything after it, later changes included ---'
DROP TABLE IF EXISTS marked_chain;
CREATE TABLE marked_chain (id int PRIMARY KEY, v int);
SELECT volvra.enable('marked_chain');
INSERT INTO marked_chain VALUES (1,10), (2,20);
SELECT volvra.mark('m2') AS marked_at;
SELECT pg_sleep(0.05);
UPDATE marked_chain SET v = 0;                     -- the accident
UPDATE marked_chain SET v = 999 WHERE id = 2;      -- a later change

DO $$ BEGIN
  -- Both changes are inside the mark-to-now window, so both are reverted and
  -- neither conflicts.  This is what makes a mark blunter than a txid: it
  -- undoes everything since, not one mistake.
  PERFORM volvra.undo_to('m2', 'marked_chain'::regclass, confirm => true);
  ASSERT (SELECT v FROM marked_chain WHERE id = 1) = 10, 'row 1 restored';
  ASSERT (SELECT v FROM marked_chain WHERE id = 2) = 20,
    'row 2 restored too: its later change was inside the window, not a conflict';
END $$;
SELECT volvra.unmark('m2');

\echo '--- but the guard still catches a change volvra never saw ---'
DROP TABLE IF EXISTS marked_unseen;
CREATE TABLE marked_unseen (id int PRIMARY KEY, v int);
SELECT volvra.enable('marked_unseen');
INSERT INTO marked_unseen VALUES (1,10);
SELECT volvra.mark('m3') AS marked_at;
SELECT pg_sleep(0.05);
UPDATE marked_unseen SET v = 0;                    -- captured

-- Now change the row behind volvra's back, which is the only way a live row
-- can stop matching the newest captured image.
ALTER TABLE marked_unseen DISABLE TRIGGER volvra_capture;
UPDATE marked_unseen SET v = 777;
ALTER TABLE marked_unseen ENABLE TRIGGER volvra_capture;

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM volvra.undo_to('m3', 'marked_unseen'::regclass, confirm => true);
    RAISE EXCEPTION 'FAILURE: undo_to overwrote a change volvra never recorded';
  EXCEPTION WHEN serialization_failure THEN
    v_state := 'refused';
  END;
  ASSERT v_state = 'refused',
    'a mark is a window, not a licence to overwrite an unrecorded change';
  ASSERT (SELECT v FROM marked_unseen WHERE id = 1) = 777, 'nothing was applied';
END $$;
SELECT volvra.unmark('m3');

\echo ''
\echo '*** ALL VOLVRA PHASE 2 CHECKS PASSED ***'
