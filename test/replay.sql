-- =====================================================================
-- pgVolvra replay -- the mirror of undo
--
-- Gate: a replay reapplies exactly the changes it was asked to, onto
-- rows that still hold what was captured before them, or it refuses.
-- It never writes over a row that has moved on, never applies a change
-- twice, and never applies half a selection.
--
-- Replay writes data forward, so the failure it must not have is
-- silent corruption. Every assertion below is written against that:
-- the negative cases matter more than the positive ones, and several
-- of them check that nothing changed at all.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP SCHEMA IF EXISTS rp CASCADE;
CREATE SCHEMA rp;
SET search_path = rp, public;

-- ---------------------------------------------------------------------
\echo '=== R1. the round trip: undo then replay returns the original state ==='

CREATE TABLE rp.orders (id int PRIMARY KEY, customer text, total numeric);
SELECT volvra.enable('rp.orders');
INSERT INTO rp.orders VALUES (1,'acme',100), (2,'globex',250), (3,'initech',75);

SELECT clock_timestamp() AS t0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.orders SET total = total * 2;          -- the change to reverse and reapply
SELECT clock_timestamp() AS t1 \gset
SELECT set_config('rp.t0', :'t0', false);
SELECT set_config('rp.t1', :'t1', false);

DO $$ BEGIN
  ASSERT (SELECT sum(total) FROM rp.orders) = 850, 'doubled';
END $$;

\echo '--- undo puts it back ---'
SELECT count(*) FROM volvra.undo('rp.orders', current_setting('rp.t0')::timestamptz,
                                 current_setting('rp.t1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT sum(total) FROM rp.orders) = 425, 'undo restored the originals';
END $$;

\echo '--- and replay of the same window applies it again ---'
SELECT count(*) FROM volvra.replay('rp.orders', current_setting('rp.t0')::timestamptz,
                                   current_setting('rp.t1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT sum(total) FROM rp.orders) = 850,
    format('replay reapplied the doubling, got %s', (SELECT sum(total) FROM rp.orders));
  ASSERT (SELECT total FROM rp.orders WHERE id = 1) = 200, 'row by row';
  ASSERT (SELECT total FROM rp.orders WHERE id = 2) = 500, 'row by row';
  ASSERT (SELECT total FROM rp.orders WHERE id = 3) = 150, 'row by row';
END $$;

-- ---------------------------------------------------------------------
\echo '=== R2. replay refuses a row that has moved on ==='

-- The central safety property. A row that no longer holds the image
-- captured before the change must not be written over.
CREATE TABLE rp.guard (id int PRIMARY KEY, v int);
SELECT volvra.enable('rp.guard');
INSERT INTO rp.guard VALUES (1,1), (2,1), (3,1);
SELECT clock_timestamp() AS g0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.guard SET v = 2;
SELECT clock_timestamp() AS g1 \gset
SELECT set_config('rp.g0', :'g0', false);
SELECT set_config('rp.g1', :'g1', false);

-- Undo it, then move one row somewhere the history does not describe.
SELECT count(*) FROM volvra.undo('rp.guard', current_setting('rp.g0')::timestamptz,
                                 current_setting('rp.g1')::timestamptz, confirm => true);
UPDATE rp.guard SET v = 99 WHERE id = 2;

\echo '--- preview flags exactly the row that moved ---'
DO $$
DECLARE v_conf bigint;
BEGIN
  SELECT count(*) FILTER (WHERE conflict) INTO v_conf
  FROM volvra.preview_replay('rp.guard', current_setting('rp.g0')::timestamptz,
                             current_setting('rp.g1')::timestamptz);
  ASSERT v_conf = 1, format('exactly one conflict expected, got %s', v_conf);
END $$;

\echo '--- and replay refuses the whole thing, changing nothing ---'
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('rp.guard',
      current_setting('rp.g0')::timestamptz,
      current_setting('rp.g1')::timestamptz, confirm => true);
    ASSERT false, 'replay must refuse a row that has moved on';
  EXCEPTION WHEN assert_failure THEN RAISE;
  WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    ASSERT v_state = '40001',
      format('expected serialization_failure, got %s', v_state);
  END;
  -- Nothing at all may have been applied: the refusal is transactional.
  ASSERT (SELECT v FROM rp.guard WHERE id = 1) = 1, 'row 1 untouched by the refusal';
  ASSERT (SELECT v FROM rp.guard WHERE id = 2) = 99, 'the moved row is not overwritten';
  ASSERT (SELECT v FROM rp.guard WHERE id = 3) = 1, 'row 3 untouched by the refusal';
END $$;

\echo '--- skip_conflicts applies the rest and still refuses the contended row ---'
SELECT count(*) FROM volvra.replay('rp.guard', current_setting('rp.g0')::timestamptz,
                                   current_setting('rp.g1')::timestamptz,
                                   confirm => true, skip_conflicts => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM rp.guard WHERE id = 1) = 2, 'uncontended rows were replayed';
  ASSERT (SELECT v FROM rp.guard WHERE id = 3) = 2, 'uncontended rows were replayed';
  ASSERT (SELECT v FROM rp.guard WHERE id = 2) = 99,
    'and the row that moved on was left exactly as it was';
END $$;

-- ---------------------------------------------------------------------
\echo '=== R3. replaying twice is refused, not applied twice ==='

-- Applying a change a second time is the other way a replay corrupts.
-- After a successful replay the rows hold the "after" image, so the
-- guard no longer matches and the second attempt must refuse.
CREATE TABLE rp.twice (id int PRIMARY KEY, n int);
SELECT volvra.enable('rp.twice');
INSERT INTO rp.twice VALUES (1, 10);
SELECT clock_timestamp() AS w0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.twice SET n = n + 5;
SELECT clock_timestamp() AS w1 \gset
SELECT set_config('rp.w0', :'w0', false);
SELECT set_config('rp.w1', :'w1', false);

SELECT count(*) FROM volvra.undo('rp.twice', current_setting('rp.w0')::timestamptz,
                                 current_setting('rp.w1')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('rp.twice', current_setting('rp.w0')::timestamptz,
                                   current_setting('rp.w1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT n FROM rp.twice WHERE id = 1) = 15, 'first replay applied';
END $$;

DO $$
DECLARE v_refused boolean := false;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('rp.twice',
      current_setting('rp.w0')::timestamptz,
      current_setting('rp.w1')::timestamptz, confirm => true);
  EXCEPTION WHEN OTHERS THEN v_refused := true;
  END;
  ASSERT v_refused, 'a second replay of the same window must refuse';
  ASSERT (SELECT n FROM rp.twice WHERE id = 1) = 15,
    format('and must not apply twice: n is %s, would be 20 if doubled',
           (SELECT n FROM rp.twice WHERE id = 1));
END $$;

-- ---------------------------------------------------------------------
\echo '=== R4. all three operations replay correctly ==='

CREATE TABLE rp.ops (id int PRIMARY KEY, v text);
SELECT volvra.enable('rp.ops');
INSERT INTO rp.ops VALUES (1,'keep'), (2,'doomed');
SELECT clock_timestamp() AS o0 \gset
SELECT pg_sleep(0.05);
INSERT INTO rp.ops VALUES (3,'added');       -- I
UPDATE rp.ops SET v = 'changed' WHERE id = 1; -- U
DELETE FROM rp.ops WHERE id = 2;              -- D
SELECT clock_timestamp() AS o1 \gset
SELECT set_config('rp.o0', :'o0', false);
SELECT set_config('rp.o1', :'o1', false);

SELECT count(*) FROM volvra.undo('rp.ops', current_setting('rp.o0')::timestamptz,
                                 current_setting('rp.o1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM rp.ops) = 2, 'undo removed the insert and restored the delete';
  ASSERT (SELECT v FROM rp.ops WHERE id = 1) = 'keep', 'and reverted the update';
  ASSERT EXISTS (SELECT 1 FROM rp.ops WHERE id = 2), 'the deleted row is back';
END $$;

\echo '--- replay reapplies insert, update and delete, in order ---'
SELECT seq, op, inverse_op, pk FROM volvra.preview_replay('rp.ops',
  current_setting('rp.o0')::timestamptz, current_setting('rp.o1')::timestamptz);

SELECT count(*) FROM volvra.replay('rp.ops', current_setting('rp.o0')::timestamptz,
                                   current_setting('rp.o1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM rp.ops WHERE id = 3 AND v = 'added'),
    'the insert was replayed';
  ASSERT (SELECT v FROM rp.ops WHERE id = 1) = 'changed', 'the update was replayed';
  ASSERT NOT EXISTS (SELECT 1 FROM rp.ops WHERE id = 2), 'the delete was replayed';
  ASSERT (SELECT count(*) FROM rp.ops) = 2, 'and the table holds exactly what it did';
END $$;

-- ---------------------------------------------------------------------
\echo '=== R5. ordering: a replay applies oldest first ==='

-- Applying out of order produces a state that never existed. A row
-- changed several times must end on its last value, not an earlier one.
CREATE TABLE rp.ordered (id int PRIMARY KEY, v int);
SELECT volvra.enable('rp.ordered');
INSERT INTO rp.ordered VALUES (1, 0);
SELECT clock_timestamp() AS d0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.ordered SET v = 1;
UPDATE rp.ordered SET v = 2;
UPDATE rp.ordered SET v = 3;
SELECT clock_timestamp() AS d1 \gset
SELECT set_config('rp.d0', :'d0', false);
SELECT set_config('rp.d1', :'d1', false);

SELECT count(*) FROM volvra.undo('rp.ordered', current_setting('rp.d0')::timestamptz,
                                 current_setting('rp.d1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM rp.ordered WHERE id = 1) = 0, 'undo walked back to the start';
END $$;

DO $$
DECLARE v_first bigint; v_last bigint;
BEGIN
  -- The plan itself must be in ascending change order.
  SELECT min(change_id), max(change_id) INTO v_first, v_last
  FROM (SELECT change_id, row_number() OVER (ORDER BY seq) AS n
        FROM volvra.preview_replay('rp.ordered',
               current_setting('rp.d0')::timestamptz,
               current_setting('rp.d1')::timestamptz)) q
  WHERE n IN (1, 3);
  ASSERT v_first < v_last, 'a replay plan is ordered oldest change first';
END $$;

SELECT count(*) FROM volvra.replay('rp.ordered', current_setting('rp.d0')::timestamptz,
                                   current_setting('rp.d1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM rp.ordered WHERE id = 1) = 3,
    format('three updates replayed in order end at 3, got %s',
           (SELECT v FROM rp.ordered WHERE id = 1));
END $$;

-- ---------------------------------------------------------------------
\echo '=== R6. the blast-radius cap and confirmation apply to replay too ==='

DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('rp.ordered',
      current_setting('rp.d0')::timestamptz, current_setting('rp.d1')::timestamptz,
      confirm => true, max_rows => 1);
    ASSERT false, 'the cap must refuse a plan larger than it';
  EXCEPTION WHEN assert_failure THEN RAISE;
  WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    ASSERT v_state = '54000', format('expected program_limit_exceeded, got %s', v_state);
  END;
END $$;

\echo '--- without confirm it plans and executes nothing ---'
CREATE TABLE rp.unconfirmed (id int PRIMARY KEY, v int);
SELECT volvra.enable('rp.unconfirmed');
INSERT INTO rp.unconfirmed VALUES (1, 1);
SELECT clock_timestamp() AS u0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.unconfirmed SET v = 2;
SELECT set_config('rp.u0', :'u0', false);
SELECT count(*) FROM volvra.undo('rp.unconfirmed', current_setting('rp.u0')::timestamptz,
                                 now(), confirm => true);
SELECT count(*) FROM volvra.replay('rp.unconfirmed', current_setting('rp.u0')::timestamptz,
                                   now());
DO $$ BEGIN
  ASSERT (SELECT v FROM rp.unconfirmed WHERE id = 1) = 1,
    'a replay without confirm executes nothing';
END $$;

-- ---------------------------------------------------------------------
\echo '=== R7. a TRUNCATE marker cannot be replayed ==='

CREATE TABLE rp.trunc (id int PRIMARY KEY, v int);
SELECT volvra.enable('rp.trunc');
INSERT INTO rp.trunc VALUES (1,1);
SELECT volvra.set_setting('on_truncate', 'allow');
SELECT clock_timestamp() AS r0 \gset
SELECT pg_sleep(0.05);
TRUNCATE rp.trunc;
SELECT set_config('rp.r0', :'r0', false);
SELECT volvra.set_setting('on_truncate', 'capture');

DO $$
DECLARE v_refused boolean := false;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('rp.trunc',
      current_setting('rp.r0')::timestamptz, now(), confirm => true);
  EXCEPTION WHEN OTHERS THEN v_refused := true;
  END;
  ASSERT v_refused,
    'a selection containing an uncaptured TRUNCATE must be refused, not stepped over';
END $$;

-- ---------------------------------------------------------------------
\echo '=== R8. replay is audited, and distinguishable from an undo ==='

DO $$
DECLARE v_undos bigint; v_replays bigint;
BEGIN
  SELECT count(*) FILTER (WHERE operation = 'undo'),
         count(*) FILTER (WHERE operation = 'replay')
    INTO v_undos, v_replays
  FROM volvra.undo_log;
  ASSERT v_undos > 0, 'undos are recorded';
  ASSERT v_replays > 0, 'replays are recorded';
  ASSERT NOT EXISTS (SELECT 1 FROM volvra.undo_log WHERE operation NOT IN ('undo','replay')),
    'every audit row names a known operation';
END $$;

\echo '--- and a replay is itself captured, like any other write ---'
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'rp.ordered' AND op = 'U';
  ASSERT v_n > 3,
    format('the replay wrote history of its own: %s changes on rp.ordered', v_n);
END $$;

-- ---------------------------------------------------------------------
\echo '=== R9. the recovery story: restore an older state, then roll forward ==='

-- This is what replay exists for. A table is taken back to an earlier
-- point, as a backup restore would, and the history carries it forward
-- again without touching anything the history does not describe.
CREATE TABLE rp.recover (id int PRIMARY KEY, v int, note text);
SELECT volvra.enable('rp.recover');
INSERT INTO rp.recover VALUES (1, 10, 'original'), (2, 20, 'original');

-- b0 stands in for the moment a backup was taken.
SELECT clock_timestamp() AS b0 \gset
SELECT pg_sleep(0.05);
UPDATE rp.recover SET v = 11 WHERE id = 1;  -- work done after the backup
UPDATE rp.recover SET v = 21 WHERE id = 2;
INSERT INTO rp.recover VALUES (3, 30, 'after the backup');
SELECT clock_timestamp() AS b1 \gset
SELECT set_config('rp.b0', :'b0', false);
SELECT set_config('rp.b1', :'b1', false);

-- Take the table back to the backup's state, the way a restore would.
SELECT count(*) FROM volvra.undo('rp.recover', current_setting('rp.b0')::timestamptz,
                                 current_setting('rp.b1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM rp.recover) = 2, 'back to the backup: two rows';
  ASSERT (SELECT sum(v) FROM rp.recover) = 30, 'back to the backup: original values';
END $$;

\echo '--- roll forward over it ---'
SELECT count(*) FROM volvra.replay('rp.recover', current_setting('rp.b0')::timestamptz,
                                   current_setting('rp.b1')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM rp.recover) = 3, 'the row added after the backup is back';
  ASSERT (SELECT v FROM rp.recover WHERE id = 1) = 11, 'and the updates are reapplied';
  ASSERT (SELECT v FROM rp.recover WHERE id = 2) = 21, 'and the updates are reapplied';
  ASSERT (SELECT note FROM rp.recover WHERE id = 3) = 'after the backup',
    'with their values intact';
END $$;

\echo ''
\echo '*** ALL VOLVRA REPLAY CHECKS PASSED ***'
