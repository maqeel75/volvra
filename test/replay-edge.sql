-- =====================================================================
-- Volvra replay -- edge cases
--
-- test/replay.sql covers the behaviour replay is specified to have.
-- This file covers the shapes and situations that could make it do
-- something else: unusual keys, derived columns, NULLs, foreign keys,
-- partitions, renames, and every way a selection can be wrong.
--
-- Where replay cannot do something, the assertion is that it refuses
-- clearly and changes nothing. A clear refusal is a supported outcome.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP SCHEMA IF EXISTS re CASCADE;
CREATE SCHEMA re;
SET search_path = re, public;

-- Every case takes a table back with an undo, then rolls it forward with a
-- replay over the same window.
--
-- Each window is bounded at both ends, and the upper bound is captured before
-- the undo runs. This matters: an undo is itself recorded, so a window ending
-- at now() would contain the undo's own changes and the replay would reapply
-- those too. Bounding the window is not tidiness, it is correctness.

-- ---------------------------------------------------------------------
\echo '=== E1. composite primary key ==='
CREATE TABLE re.comp (a int, b text, v int, PRIMARY KEY (a, b));
SELECT volvra.enable('re.comp');
INSERT INTO re.comp VALUES (1,'x',10), (1,'y',20), (2,'x',30);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE re.comp SET v = 0;
DELETE FROM re.comp WHERE a = 2;
SELECT clock_timestamp() AS t_end \gset
SELECT set_config('re.t', :'t', false);
SELECT set_config('re.t_end', :'t_end', false);

SELECT count(*) FROM volvra.undo('re.comp', current_setting('re.t')::timestamptz,
                                 current_setting('re.t_end')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('re.comp', current_setting('re.t')::timestamptz,
                                   current_setting('re.t_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.comp) = 2, 'composite key: the delete replayed';
  ASSERT (SELECT sum(v) FROM re.comp) = 0, 'composite key: the updates replayed';
  ASSERT NOT EXISTS (SELECT 1 FROM re.comp WHERE a = 2), 'the right row is gone';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E2. a generated column is derived, so no guard compares it ==='
-- PostgreSQL does not send generated columns through logical replication, so
-- an archive-restored image carries a null where the live row holds a
-- computed value. A guard that compared it would fail on every row of such a
-- table, for undo as well as replay.
CREATE TABLE re.gen (id int PRIMARY KEY, n int NOT NULL,
                     dbl int GENERATED ALWAYS AS (n * 2) STORED);
SELECT volvra.enable('re.gen');
INSERT INTO re.gen (id, n) VALUES (1, 5), (2, 7);

-- A change shaped exactly as the companion's restore produces one: the
-- derived column present and null. Writing it directly is the only way to
-- reproduce that here, and change_log is append-only, so it is an insert.
INSERT INTO volvra.change_log
  (table_name, op, pk, old_row, new_row, actor, db_user, txid)
SELECT 're.gen', 'U', jsonb_build_object('id', g),
       jsonb_build_object('id', g, 'n', CASE g WHEN 1 THEN 5 ELSE 7 END,
                          'dbl', NULL),
       jsonb_build_object('id', g, 'n', 50, 'dbl', NULL),
       'archive:test', 'archive', pg_current_xact_id()::text::bigint
FROM generate_series(1, 2) g;

DO $$
DECLARE v_conf bigint; v_n bigint;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE conflict) INTO v_n, v_conf
  FROM volvra.preview_replay('re.gen', predicate => $p$actor = 'archive:test'$p$);
  ASSERT v_n = 2, format('both archive-shaped changes are planned, got %s', v_n);
  ASSERT v_conf = 0,
    format('a null generated column must not read as a conflict, got %s', v_conf);
END $$;

SELECT count(*) FROM volvra.replay('re.gen',
  predicate => $p$actor = 'archive:test'$p$, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.gen WHERE n = 50) = 2,
    'an image whose generated column is null still replays';
  ASSERT (SELECT count(*) FROM re.gen WHERE dbl = n * 2) = 2,
    'and PostgreSQL recomputed the generated column rather than volvra writing it';
END $$;

\echo '=== E3. an identity column is never written by a replay ==='
CREATE TABLE re.ident (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v int);
SELECT volvra.enable('re.ident');
INSERT INTO re.ident (v) VALUES (1), (2);
SELECT clock_timestamp() AS i \gset
SELECT pg_sleep(0.05);
UPDATE re.ident SET v = 9;
SELECT clock_timestamp() AS i_end \gset
SELECT set_config('re.i', :'i', false);
SELECT set_config('re.i_end', :'i_end', false);
SELECT count(*) FROM volvra.undo('re.ident', current_setting('re.i')::timestamptz,
                                 current_setting('re.i_end')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('re.ident', current_setting('re.i')::timestamptz,
                                   current_setting('re.i_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.ident WHERE v = 9) = 2,
    'an always-identity table replays without trying to assign the identity';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E4. NULLs round-trip in both directions ==='
CREATE TABLE re.nulls (id int PRIMARY KEY, a text, b int);
SELECT volvra.enable('re.nulls');
INSERT INTO re.nulls VALUES (1, 'set', 1), (2, NULL, NULL);
SELECT clock_timestamp() AS n \gset
SELECT pg_sleep(0.05);
UPDATE re.nulls SET a = NULL, b = NULL WHERE id = 1;   -- value -> NULL
UPDATE re.nulls SET a = 'now set', b = 7 WHERE id = 2; -- NULL -> value
SELECT clock_timestamp() AS n_end \gset
SELECT set_config('re.n', :'n', false);
SELECT set_config('re.n_end', :'n_end', false);

SELECT count(*) FROM volvra.undo('re.nulls', current_setting('re.n')::timestamptz,
                                 current_setting('re.n_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT a FROM re.nulls WHERE id = 1) = 'set', 'undo restored a value';
  ASSERT (SELECT a FROM re.nulls WHERE id = 2) IS NULL, 'undo restored a NULL';
END $$;

SELECT count(*) FROM volvra.replay('re.nulls', current_setting('re.n')::timestamptz,
                                   current_setting('re.n_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT a FROM re.nulls WHERE id = 1) IS NULL,
    'replay set a column back to NULL rather than leaving it';
  ASSERT (SELECT b FROM re.nulls WHERE id = 1) IS NULL, 'both columns';
  ASSERT (SELECT a FROM re.nulls WHERE id = 2) = 'now set',
    'and replay set a NULL column to its value';
  ASSERT (SELECT b FROM re.nulls WHERE id = 2) = 7, 'both columns';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E5. foreign keys: a replay inserts parents before children ==='
CREATE TABLE re.parent (id int PRIMARY KEY, v int);
CREATE TABLE re.child (id int PRIMARY KEY,
                       p int NOT NULL REFERENCES re.parent(id) ON DELETE CASCADE);
SELECT volvra.enable('re.parent'); SELECT volvra.enable('re.child');
SELECT count(*) FROM volvra.make_fks_deferrable('re');
INSERT INTO re.parent VALUES (1, 1);
INSERT INTO re.child VALUES (1, 1);
SELECT clock_timestamp() AS f \gset
SELECT pg_sleep(0.05);
INSERT INTO re.parent VALUES (2, 2);      -- parent first, chronologically
INSERT INTO re.child VALUES (2, 2);       -- then its child
DELETE FROM re.parent WHERE id = 1;       -- cascades to child 1
SELECT clock_timestamp() AS f_end \gset
SELECT set_config('re.f', :'f', false);
SELECT set_config('re.f_end', :'f_end', false);

SELECT count(*) FROM volvra.undo(tables => ARRAY['re.parent','re.child']::regclass[],
                                 from_ts => current_setting('re.f')::timestamptz,
                                 to_ts => current_setting('re.f_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.parent) = 1, 'undo put the cascade back';
  ASSERT (SELECT count(*) FROM re.child) = 1, 'undo put the cascade back';
END $$;

SELECT count(*) FROM volvra.replay(tables => ARRAY['re.parent','re.child']::regclass[],
                                   from_ts => current_setting('re.f')::timestamptz,
                                   to_ts => current_setting('re.f_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.parent) = 1, 'replay reapplied the cascade delete';
  ASSERT (SELECT count(*) FROM re.child) = 1, 'and the child went with it';
  -- Replaying the parent delete re-fires the cascade, so the recorded child
  -- delete has nothing left to do. That is satisfied, not a conflict.
  ASSERT NOT EXISTS (SELECT 1 FROM re.child WHERE id = 1),
    'the cascaded child is gone exactly once';
  ASSERT EXISTS (SELECT 1 FROM re.parent WHERE id = 2), 'the new parent is there';
  ASSERT EXISTS (SELECT 1 FROM re.child WHERE id = 2 AND p = 2),
    'and its child, which could only be inserted after it';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E6. a partitioned table replays through its parent ==='
CREATE TABLE re.part (id int, at date NOT NULL, v int, PRIMARY KEY (id, at))
  PARTITION BY RANGE (at);
CREATE TABLE re.part_a PARTITION OF re.part
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE re.part_b PARTITION OF re.part
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
SELECT volvra.enable('re.part');
INSERT INTO re.part VALUES (1,'2026-01-15',10), (2,'2026-02-15',20);
SELECT clock_timestamp() AS p \gset
SELECT pg_sleep(0.05);
UPDATE re.part SET v = 0;
SELECT clock_timestamp() AS p_end \gset
SELECT set_config('re.p', :'p', false);
SELECT set_config('re.p_end', :'p_end', false);
SELECT count(*) FROM volvra.undo('re.part', current_setting('re.p')::timestamptz,
                                 current_setting('re.p_end')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('re.part', current_setting('re.p')::timestamptz,
                                   current_setting('re.p_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM re.part WHERE v = 0) = 2,
    'a replay reaches rows in every partition through the covered parent';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E7. replaying an insert whose row already exists is a conflict ==='
CREATE TABLE re.dup (id int PRIMARY KEY, v int);
SELECT volvra.enable('re.dup');
SELECT clock_timestamp() AS d \gset
SELECT pg_sleep(0.05);
INSERT INTO re.dup VALUES (1, 1);
SELECT clock_timestamp() AS d_end \gset
SELECT set_config('re.d', :'d', false);
SELECT set_config('re.d_end', :'d_end', false);
-- The row is still there, so replaying its insert must not raise a duplicate
-- key error: it must be reported as a conflict, like any other guard failure.
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('re.dup',
      current_setting('re.d')::timestamptz,
      current_setting('re.d_end')::timestamptz, confirm => true);
    ASSERT false, 'replaying an insert over an existing row must be refused';
  EXCEPTION WHEN assert_failure THEN RAISE;
  WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    ASSERT v_state = '40001',
      format('expected a conflict (40001), not a raw error; got %s', v_state);
  END;
  ASSERT (SELECT count(*) FROM re.dup) = 1, 'and nothing was duplicated';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E8. an already-absent delete is satisfied; a different row is not ==='
CREATE TABLE re.gone (id int PRIMARY KEY, v int);
SELECT volvra.enable('re.gone');
INSERT INTO re.gone VALUES (1, 1);
SELECT clock_timestamp() AS x \gset
SELECT pg_sleep(0.05);
DELETE FROM re.gone WHERE id = 1;
SELECT clock_timestamp() AS x_end \gset
SELECT set_config('re.x', :'x', false);
SELECT set_config('re.x_end', :'x_end', false);
-- The row is already absent, so the delete's goal is already met. That is
-- reported as satisfied rather than refused: absence is what the delete was
-- for, and nothing can be destroyed by not deleting an absent row.
DO $$
DECLARE v_sat bigint; v_other bigint;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'satisfied'),
         count(*) FILTER (WHERE status <> 'satisfied')
    INTO v_sat, v_other
  FROM volvra.replay('re.gone', current_setting('re.x')::timestamptz,
                     current_setting('re.x_end')::timestamptz, confirm => true);
  ASSERT v_sat = 1, format('an already-absent delete is satisfied, got %s', v_sat);
  ASSERT v_other = 0, 'and nothing else happened';
  ASSERT NOT EXISTS (SELECT 1 FROM re.gone WHERE id = 1), 'the row is still absent';
END $$;

\echo '--- but a different row at the same key is a real conflict ---'
INSERT INTO re.gone VALUES (1, 999);          -- same key, different content
DO $$
DECLARE v_refused boolean := false;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay('re.gone',
      current_setting('re.x')::timestamptz,
      current_setting('re.x_end')::timestamptz, confirm => true);
  EXCEPTION WHEN OTHERS THEN v_refused := true;
  END;
  ASSERT v_refused,
    'a row present but not matching the captured image must not be deleted';
  ASSERT (SELECT v FROM re.gone WHERE id = 1) = 999,
    'and it is still there, untouched';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E9. an empty selection is not an error ==='
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.replay('re.gone',
    now() + interval '1 hour', now() + interval '2 hours', confirm => true);
  ASSERT v_n = 0, format('an empty window replays nothing, got %s', v_n);
END $$;

-- ---------------------------------------------------------------------
\echo '=== E10. a replay is refused on a table that no longer exists ==='
CREATE TABLE re.dropped (id int PRIMARY KEY, v int);
SELECT volvra.enable('re.dropped');
INSERT INTO re.dropped VALUES (1, 1);
SELECT pg_sleep(0.05);
UPDATE re.dropped SET v = 2;
DROP TABLE re.dropped;
DO $$
DECLARE v_refused boolean := false; v_msg text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.replay(predicate => $p$table_name = 're.dropped'$p$,
                                        confirm => true);
  EXCEPTION WHEN OTHERS THEN v_refused := true; v_msg := SQLERRM;
  END;
  ASSERT v_refused, 'a replay naming a dropped table must refuse';
  ASSERT v_msg ILIKE '%no longer exists%' OR v_msg ILIKE '%coverage%'
      OR v_msg ILIKE '%not covered%',
    format('and say why; got: %s', v_msg);
END $$;

-- ---------------------------------------------------------------------
\echo '=== E11. excluded columns are not resurrected by a replay ==='
CREATE TABLE re.excl (id int PRIMARY KEY, keep int, secret text);
SELECT volvra.enable('re.excl');
SELECT count(*) FROM volvra.exclude_columns('re.excl', ARRAY['secret']);
INSERT INTO re.excl VALUES (1, 1, 'classified');
SELECT clock_timestamp() AS e \gset
SELECT pg_sleep(0.05);
UPDATE re.excl SET keep = 2, secret = 'changed';
SELECT clock_timestamp() AS e_end \gset
SELECT set_config('re.e', :'e', false);
SELECT set_config('re.e_end', :'e_end', false);
SELECT count(*) FROM volvra.undo('re.excl', current_setting('re.e')::timestamptz,
                                 current_setting('re.e_end')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('re.excl', current_setting('re.e')::timestamptz,
                                   current_setting('re.e_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT keep FROM re.excl WHERE id = 1) = 2, 'the captured column replayed';
  ASSERT (SELECT secret FROM re.excl WHERE id = 1) = 'changed',
    'and the excluded column was never written by volvra, in either direction';
  ASSERT (SELECT count(*) FROM volvra.change_log
           WHERE table_name = 're.excl' AND new_row ? 'secret') = 0,
    'the excluded column is not in the history at all';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E12. capture_updates = full replays as well as changed does ==='
SELECT volvra.set_setting('capture_updates', 'full');
CREATE TABLE re.fullmode (id int PRIMARY KEY, a int, b text);
SELECT volvra.enable('re.fullmode');
INSERT INTO re.fullmode VALUES (1, 1, 'one');
SELECT clock_timestamp() AS fm \gset
SELECT pg_sleep(0.05);
UPDATE re.fullmode SET a = 2 WHERE id = 1;
SELECT clock_timestamp() AS fm_end \gset
SELECT set_config('re.fm', :'fm', false);
SELECT set_config('re.fm_end', :'fm_end', false);
SELECT count(*) FROM volvra.undo('re.fullmode', current_setting('re.fm')::timestamptz,
                                 current_setting('re.fm_end')::timestamptz, confirm => true);
SELECT count(*) FROM volvra.replay('re.fullmode', current_setting('re.fm')::timestamptz,
                                   current_setting('re.fm_end')::timestamptz, confirm => true);
DO $$ BEGIN
  ASSERT (SELECT a FROM re.fullmode WHERE id = 1) = 2, 'full-image replay applied';
  ASSERT (SELECT b FROM re.fullmode WHERE id = 1) = 'one',
    'and the untouched column is unchanged';
END $$;
SELECT volvra.set_setting('capture_updates', 'changed');

-- ---------------------------------------------------------------------
\echo '=== E13. a replay does not touch rows outside the selection ==='
CREATE TABLE re.scope (id int PRIMARY KEY, v int);
SELECT volvra.enable('re.scope');
INSERT INTO re.scope VALUES (1, 1), (2, 1), (3, 1);
SELECT clock_timestamp() AS s \gset
SELECT pg_sleep(0.05);
UPDATE re.scope SET v = 2 WHERE id = 1;
SELECT clock_timestamp() AS s2 \gset
SELECT pg_sleep(0.05);
UPDATE re.scope SET v = 3 WHERE id = 2;
SELECT set_config('re.s', :'s', false);
SELECT set_config('re.s2', :'s2', false);

SELECT count(*) FROM volvra.undo('re.scope', current_setting('re.s')::timestamptz,
                                 now(), confirm => true);
-- Replay only the first window: row 2 must stay where the undo left it.
SELECT count(*) FROM volvra.replay('re.scope', current_setting('re.s')::timestamptz,
                                   current_setting('re.s2')::timestamptz,
                                   confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM re.scope WHERE id = 1) = 2, 'the selected row replayed';
  ASSERT (SELECT v FROM re.scope WHERE id = 2) = 1, 'the unselected row did not';
  ASSERT (SELECT v FROM re.scope WHERE id = 3) = 1, 'nor the untouched one';
END $$;

-- ---------------------------------------------------------------------
\echo '=== E14. a quoted, mixed-case, non-ASCII table replays ==='
CREATE TABLE re."Mixed Case.Tabla" ("Id" int PRIMARY KEY, "vä lue" text);
SELECT volvra.enable('re."Mixed Case.Tabla"');
INSERT INTO re."Mixed Case.Tabla" VALUES (1, 'before');
SELECT clock_timestamp() AS m \gset
SELECT pg_sleep(0.05);
UPDATE re."Mixed Case.Tabla" SET "vä lue" = 'after';
SELECT clock_timestamp() AS m_end \gset
SELECT set_config('re.m', :'m', false);
SELECT set_config('re.m_end', :'m_end', false);
SELECT count(*) FROM volvra.undo('re."Mixed Case.Tabla"',
                                 current_setting('re.m')::timestamptz,
      current_setting('re.m_end')::timestamptz,
                                 confirm => true);
SELECT count(*) FROM volvra.replay('re."Mixed Case.Tabla"',
                                   current_setting('re.m')::timestamptz,
      current_setting('re.m_end')::timestamptz,
                                   confirm => true);
DO $$ BEGIN
  ASSERT (SELECT "vä lue" FROM re."Mixed Case.Tabla" WHERE "Id" = 1) = 'after',
    'identifiers needing quotes survive a replay';
END $$;

\echo ''
\echo '*** ALL VOLVRA REPLAY EDGE CHECKS PASSED ***'
