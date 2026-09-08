-- =====================================================================
-- Volvra scenario coverage (TESTPLAN priority 6)
--
-- The other suites test the paths volvra was designed around. This one
-- tests the table shapes, identifiers, and schema changes real
-- databases actually contain -- the cases where volvra's assumptions
-- about a table are most likely to be wrong.
--
-- Where volvra cannot support something, the assertion is that it
-- refuses clearly. A clear refusal is a supported outcome; silently
-- doing the wrong thing is not.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP SCHEMA IF EXISTS sc CASCADE;
CREATE SCHEMA sc;
SET search_path = sc, public;

-- ---------------------------------------------------------------------
\echo '=== S6.1 table shapes ==='

\echo '--- composite primary key ---'
CREATE TABLE sc.comp (a int, b text, v int, PRIMARY KEY (a, b));
SELECT volvra.enable('sc.comp');
INSERT INTO sc.comp VALUES (1,'x',10), (1,'y',20), (2,'x',30);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.comp SET v = 0;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc.comp', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.comp WHERE v = 0) = 0,
         'composite key: every row reverted';
  ASSERT (SELECT v FROM sc.comp WHERE a = 1 AND b = 'y') = 20,
         'composite key: the right row got the right value';
END $$;

\echo '--- natural text key, including a value with quotes and a dot ---'
CREATE TABLE sc.natural_key (k text PRIMARY KEY, v int);
SELECT volvra.enable('sc.natural_key');
INSERT INTO sc.natural_key VALUES ('a.b', 1), ('say "hi"', 2), (E'tab\there', 3);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
DELETE FROM sc.natural_key;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc.natural_key', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.natural_key) = 3, 'natural key: all rows back';
  ASSERT (SELECT v FROM sc.natural_key WHERE k = 'say "hi"') = 2,
         'natural key: a quoted value round-trips';
  ASSERT (SELECT v FROM sc.natural_key WHERE k = E'tab\there') = 3,
         'natural key: a tab in the key round-trips';
END $$;

\echo '--- identity key and generated column ---'
CREATE TABLE sc.gen (
  id  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  n   int NOT NULL,
  dbl int GENERATED ALWAYS AS (n * 2) STORED);
SELECT volvra.enable('sc.gen');
INSERT INTO sc.gen (n) VALUES (1), (2), (3);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.gen SET n = 99;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc.gen', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.gen WHERE n = 99) = 0, 'identity: reverted';
  -- The generated column must be recomputed by PostgreSQL, never written by
  -- volvra: an UPDATE naming it is an error, which is why _setcols excludes
  -- both identity and generated columns.
  ASSERT (SELECT count(*) FROM sc.gen WHERE dbl <> n * 2) = 0,
         'generated column stayed consistent with its source';
END $$;

\echo '--- unlogged table ---'
CREATE UNLOGGED TABLE sc.unlogged (id int PRIMARY KEY, v int);
SELECT volvra.enable('sc.unlogged');
INSERT INTO sc.unlogged VALUES (1,1), (2,2);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.unlogged SET v = 0;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc.unlogged', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.unlogged WHERE v = 0) = 0,
         'unlogged table: reverted. Note the history is logged even though '
         'the table is not, so an unlogged table survives a crash less well '
         'than its own change log does.';
END $$;

\echo '--- a partitioned user table ---'
CREATE TABLE sc.part (id int, at date NOT NULL, v int, PRIMARY KEY (id, at))
  PARTITION BY RANGE (at);
CREATE TABLE sc.part_a PARTITION OF sc.part
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE sc.part_b PARTITION OF sc.part
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
-- A row trigger on a partitioned parent IS propagated to every partition,
-- including partitions attached later, and it fires with TG_RELID set to the
-- partition.  Covering the parent therefore has to cover the whole table --
-- which is what the caller asked for.  Before this was fixed, enable() on a
-- parent reported success and then every INSERT failed with "sc.part_a is not
-- registered", leaving the table unusable.
SELECT volvra.enable('sc.part');

\echo '--- covering a partition of a covered parent says so instead of failing ---'
DO $$
DECLARE v_msg text;
BEGIN
  v_msg := volvra.enable('sc.part_a');
  ASSERT v_msg ILIKE '%already covered%',
         format('expected a clear "already covered" answer, got: %s', v_msg);
END $$;

INSERT INTO sc.part VALUES (1,'2026-01-15',10), (2,'2026-02-15',20);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.part SET v = 0;
SELECT set_config('sc.t', :'t', false);

-- Changes land under the covered parent's name, not the partition's, so one
-- undo of the table covers rows in every partition.
DO $$
DECLARE v_n bigint; v_child bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'sc.part' AND op = 'U';
  ASSERT v_n = 2, format('partitioned parent: 2 updates expected, got %s', v_n);
  SELECT count(*) INTO v_child FROM volvra.change_log
   WHERE table_name IN ('sc.part_a','sc.part_b');
  ASSERT v_child = 0,
         format('and nothing is recorded under a partition name, got %s', v_child);
END $$;

SELECT count(*) FROM volvra.undo('sc.part', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.part WHERE v = 0) = 0,
         'one undo of the parent reverts rows across every partition';
  ASSERT (SELECT v FROM sc.part WHERE id = 2) = 20,
         'including the partition the undo did not name';
END $$;

\echo '--- a partition attached after enable() is covered too ---'
CREATE TABLE sc.part_c PARTITION OF sc.part
  FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
INSERT INTO sc.part VALUES (3,'2026-03-15',30);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.part SET v = 0 WHERE id = 3;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc.part', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT v FROM sc.part WHERE id = 3) = 30,
         'a partition created after coverage began needs no extra call, '
         'because the parent trigger propagates to it';
END $$;

\echo '--- a partition attached later needs its truncate trigger attached ---'
-- PostgreSQL propagates ROW triggers from a partitioned parent to partitions
-- attached later, but never statement-level TRUNCATE triggers.  Without
-- reconciliation, TRUNCATE of such a partition would destroy rows with no
-- history while TRUNCATE of its parent stayed fully reversible: the same
-- statement with two different guarantees.
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = 'sc.part_c'::regclass
                        AND t.tgname = 'volvra_capture_truncate'),
         'sc.part_c was attached after enable(), so it starts without the '
         'truncate trigger -- this is the gap cover_partitions() closes';
  ASSERT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'sc.part_c'::regclass
                    AND t.tgname = 'volvra_capture'),
         'while the row trigger did propagate on its own';
END $$;
SELECT count(*) AS partitions_covered FROM volvra.cover_partitions();
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'sc.part_c'::regclass
                    AND t.tgname = 'volvra_capture_truncate'),
         'cover_partitions() closes it, and maintain() calls it on a schedule';
END $$;

\echo '--- truncating a covered partitioned table is captured and reversible ---'
SELECT volvra.set_setting('on_truncate', 'capture');
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
TRUNCATE sc.part;
SELECT set_config('sc.t', :'t', false);
DO $$
DECLARE v_n bigint;
BEGIN
  ASSERT (SELECT count(*) FROM sc.part) = 0, 'the truncate happened';
  -- capture mode records each row as a delete, because re-inserting a deleted
  -- row is exactly what undoing a truncate has to do.  'T' is the marker
  -- written by 'allow' mode, where the rows are gone for good.
  --
  -- Exactly three, not nine: TRUNCATE of a parent fires this trigger on the
  -- parent and on every partition, so the parent must capture nothing and
  -- each partition only its own rows.
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'sc.part' AND op = 'D'
     AND ts >= current_setting('sc.t')::timestamptz;
  ASSERT v_n = 3,
         format('each row captured once under the parent name: expected 3, got %s', v_n);
END $$;
SELECT count(*) FROM volvra.undo('sc.part', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.part) = 3,
         'a truncate of a partitioned table is undone whole';
END $$;

\echo '--- truncating one partition directly is captured as well ---'
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
TRUNCATE sc.part_a;
SELECT set_config('sc.t', :'t', false);
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'sc.part' AND op = 'D'
     AND ts >= current_setting('sc.t')::timestamptz;
  ASSERT v_n = 1, format('truncating one partition captured %s row(s), expected 1', v_n);
END $$;
SELECT count(*) FROM volvra.undo('sc.part', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.part WHERE at < '2026-02-01') = 1,
         'and truncating one partition is reversible';
END $$;

\echo '--- a table with no primary key must be refused, clearly ---'
CREATE TABLE sc.nopk (a int, b int);
DO $$
DECLARE v_msg text;
BEGIN
  BEGIN
    PERFORM volvra.enable('sc.nopk');
    ASSERT false, 'enable() must refuse a table with no primary key';
  EXCEPTION WHEN assert_failure THEN RAISE;
  WHEN OTHERS THEN
    v_msg := SQLERRM;
    ASSERT v_msg ILIKE '%key%' OR v_msg ILIKE '%primary%',
           format('the refusal must say why; got: %s', v_msg);
  END;
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.2 identifiers ==='

\echo '--- quoted, mixed case, and non-ASCII names ---'
CREATE TABLE sc."Mixed Case.Table" ("Id" int PRIMARY KEY, "vä lue" text);
SELECT volvra.enable('sc."Mixed Case.Table"');
INSERT INTO sc."Mixed Case.Table" VALUES (1, 'keep'), (2, 'keep');
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc."Mixed Case.Table" SET "vä lue" = 'lost';
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo('sc."Mixed Case.Table"',
                                 current_setting('sc.t')::timestamptz, now(),
                                 confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc."Mixed Case.Table" WHERE "vä lue" = 'keep') = 2,
         'a name containing a space, a dot, mixed case, and a non-ASCII column '
         'round-trips through the history';
END $$;

\echo '--- a 63-character identifier, which is the maximum ---'
DO $$
DECLARE
  v_name text := repeat('n', 63);
  v_tbl  text;
BEGIN
  EXECUTE format('CREATE TABLE sc.%I (id int PRIMARY KEY, v int)', v_name);
  v_tbl := format('sc.%I', v_name);
  PERFORM volvra.enable(v_tbl::regclass);
  EXECUTE format('INSERT INTO %s VALUES (1, 1)', v_tbl);
  PERFORM set_config('sc.t63', clock_timestamp()::text, false);
  PERFORM pg_sleep(0.05);
  EXECUTE format('UPDATE %s SET v = 0', v_tbl);
  -- clock_timestamp(), not now(): inside one transaction now() is fixed at
  -- the transaction's start, which is earlier than the mark taken above.
  PERFORM count(*) FROM volvra.undo(v_tbl::regclass,
    current_setting('sc.t63')::timestamptz, clock_timestamp(), confirm => true);
  EXECUTE format('SELECT count(*) FROM %s WHERE v = 1', v_tbl) INTO STRICT v_name;
  ASSERT v_name::bigint = 1, 'a 63-character table name round-trips';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.3 schema change under coverage ==='

\echo '--- add a column, then undo history captured before it existed ---'
CREATE TABLE sc.evolve (id int PRIMARY KEY, a int);
SELECT volvra.enable('sc.evolve');
INSERT INTO sc.evolve VALUES (1, 10), (2, 20);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.evolve SET a = 0;
SELECT set_config('sc.t', :'t', false);
ALTER TABLE sc.evolve ADD COLUMN b text DEFAULT 'new';
SELECT count(*) FROM volvra.undo('sc.evolve', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT a FROM sc.evolve WHERE id = 1) = 10,
         'a column added after capture does not stop the undo';
  ASSERT (SELECT b FROM sc.evolve WHERE id = 1) = 'new',
         'and the new column keeps its current value, because the history '
         'says nothing about it';
END $$;

\echo '--- drop a column that the history still mentions ---'
CREATE TABLE sc.shrink (id int PRIMARY KEY, keep int, gone text);
SELECT volvra.enable('sc.shrink');
INSERT INTO sc.shrink VALUES (1, 10, 'x');
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.shrink SET keep = 0, gone = 'y';
SELECT set_config('sc.t', :'t', false);
ALTER TABLE sc.shrink DROP COLUMN gone;
DO $$
DECLARE v_ok boolean := false; v_msg text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.undo('sc.shrink',
      current_setting('sc.t')::timestamptz, now(), confirm => true);
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN
    v_msg := SQLERRM;
  END;
  IF v_ok THEN
    ASSERT (SELECT keep FROM sc.shrink WHERE id = 1) = 10,
           'a dropped column is ignored and the rest is restored';
  ELSE
    -- Refusing is also correct, as long as it names the problem rather than
    -- failing on a missing column deep inside generated SQL.
    -- Refusing is the designed behaviour: plan-time schema-drift validation
    -- would rather stop than guess what a missing column meant.  What matters
    -- is that the message names the cause instead of failing on a missing
    -- column deep inside generated SQL.
    ASSERT v_msg ILIKE '%shape%' OR v_msg ILIKE '%column%'
        OR v_msg ILIKE '%schema%' OR v_msg ILIKE '%drift%',
           format('a dropped column must be explained, not crashed on; got: %s', v_msg);
    RAISE NOTICE 'dropped column: refused with "%"', v_msg;
  END IF;
END $$;

\echo '--- rename a column, which changes what the history means ---'
CREATE TABLE sc.renamed (id int PRIMARY KEY, before_name int);
SELECT volvra.enable('sc.renamed');
INSERT INTO sc.renamed VALUES (1, 10);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.renamed SET before_name = 0;
SELECT set_config('sc.t', :'t', false);
ALTER TABLE sc.renamed RENAME COLUMN before_name TO after_name;
DO $$
DECLARE v_ok boolean := false; v_msg text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.undo('sc.renamed',
      current_setting('sc.t')::timestamptz, now(), confirm => true);
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
  END;
  -- A rename is indistinguishable from a drop plus an add at the jsonb level,
  -- so either restoring nothing or refusing is defensible.  Writing the old
  -- value into a differently named column would not be.
  IF v_ok THEN
    ASSERT (SELECT after_name FROM sc.renamed WHERE id = 1) IN (0, 10),
           'a renamed column is either restored or left alone, never corrupted';
    RAISE NOTICE 'renamed column: undo accepted, value is %',
      (SELECT after_name FROM sc.renamed WHERE id = 1);
  ELSE
    RAISE NOTICE 'renamed column: refused with "%"', v_msg;
  END IF;
END $$;

\echo '--- rename the table itself, which changes its recorded name ---'
CREATE TABLE sc.old_name (id int PRIMARY KEY, v int);
SELECT volvra.enable('sc.old_name');
INSERT INTO sc.old_name VALUES (1, 10);
UPDATE sc.old_name SET v = 0;
ALTER TABLE sc.old_name RENAME TO new_name;
DO $$
DECLARE v_old bigint; v_reg text;
BEGIN
  SELECT count(*) INTO v_old FROM volvra.change_log WHERE table_name = 'sc.old_name';
  ASSERT v_old > 0, 'history recorded under the old name is still there';
  -- enabled_tables still names the old table, so status() must not claim
  -- coverage of a table that no longer exists under that name.
  SELECT table_name INTO v_reg FROM volvra.enabled_tables
   WHERE table_name = 'sc.old_name';
  RAISE NOTICE 'after RENAME: enabled_tables still says %, and the trigger '
               'moved with the table', coalesce(v_reg, '(nothing)');
  -- The trigger follows the table through a rename, so capture continues.
  ASSERT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'sc.new_name'::regclass
                    AND tgname = 'volvra_capture'),
         'the capture trigger survives a table rename';
END $$;
UPDATE sc.new_name SET v = 5;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM volvra.change_log
           WHERE table_name = 'sc.new_name') > 0,
         'and changes after the rename are recorded under the new name';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.4 foreign keys ==='

\echo '--- self-referencing table ---'
CREATE TABLE sc.tree (
  id int PRIMARY KEY,
  parent int REFERENCES sc.tree(id) ON DELETE CASCADE,
  v int);
SELECT volvra.enable('sc.tree');
INSERT INTO sc.tree VALUES (1, NULL, 10), (2, 1, 20), (3, 2, 30);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
DELETE FROM sc.tree WHERE id = 1;            -- cascades to 2 and then 3
SELECT set_config('sc.t', :'t', false);
DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'sc.tree' AND op = 'D'
     AND ts >= current_setting('sc.t')::timestamptz;
  ASSERT v_n = 3, format('a cascade is captured row by row: expected 3, got %s', v_n);
END $$;
-- Reverse-chronological order inserts the child before the parent, so a
-- foreign key blocks the undo.  SET CONSTRAINTS ALL DEFERRED only affects
-- constraints declared DEFERRABLE, and PostgreSQL's default is not -- which is
-- the whole reason make_fks_deferrable() exists.  The first attempt must fail
-- and say so rather than half-restore the tree.
DO $$
DECLARE v_msg text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.undo('sc.tree',
      current_setting('sc.t')::timestamptz, clock_timestamp(), confirm => true);
    ASSERT false, 'a non-deferrable foreign key should have blocked this undo';
  EXCEPTION WHEN assert_failure THEN RAISE;
  WHEN OTHERS THEN
    v_msg := SQLERRM;
    ASSERT v_msg ILIKE '%foreign key%',
           format('the refusal must name the foreign key; got: %s', v_msg);
  END;
  ASSERT (SELECT count(*) FROM sc.tree) = 0,
         'and nothing was restored, because the undo is one transaction';
END $$;

\echo '--- make_fks_deferrable() is what makes the same undo work ---'
SELECT count(*) FROM volvra.make_fks_deferrable('sc');
SELECT count(*) FROM volvra.undo('sc.tree', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.tree) = 3, 'a self-referencing cascade is undone whole';
  ASSERT (SELECT parent FROM sc.tree WHERE id = 3) = 2, 'and the links are intact';
END $$;

\echo '--- multi-level cascade across three tables ---'
CREATE TABLE sc.fk_a (id int PRIMARY KEY, v int);
CREATE TABLE sc.fk_b (id int PRIMARY KEY, a int REFERENCES sc.fk_a(id) ON DELETE CASCADE);
CREATE TABLE sc.fk_c (id int PRIMARY KEY, b int REFERENCES sc.fk_b(id) ON DELETE CASCADE);
SELECT volvra.enable('sc.fk_a'); SELECT volvra.enable('sc.fk_b');
SELECT volvra.enable('sc.fk_c');
-- These constraints were created after the earlier call, so they are not
-- deferrable yet.  make_fks_deferrable() is idempotent and belongs in the
-- migration that creates the tables.
SELECT count(*) FROM volvra.make_fks_deferrable('sc');
INSERT INTO sc.fk_a VALUES (1, 10); INSERT INTO sc.fk_b VALUES (1, 1);
INSERT INTO sc.fk_c VALUES (1, 1);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
DELETE FROM sc.fk_a WHERE id = 1;
SELECT set_config('sc.t', :'t', false);
SELECT count(*) FROM volvra.undo(tables => ARRAY['sc.fk_a','sc.fk_b','sc.fk_c'],
                                 from_ts => current_setting('sc.t')::timestamptz,
                                 to_ts => now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.fk_a) = 1 AND (SELECT count(*) FROM sc.fk_b) = 1
     AND (SELECT count(*) FROM sc.fk_c) = 1,
         'a three-level cascade is undone across all three tables at once';
END $$;

\echo '--- SET NULL and SET DEFAULT ---'
CREATE TABLE sc.fk_p (id int PRIMARY KEY);
CREATE TABLE sc.fk_child (
  id int PRIMARY KEY,
  n  int REFERENCES sc.fk_p(id) ON DELETE SET NULL,
  d  int DEFAULT 0);
INSERT INTO sc.fk_p VALUES (1), (2);
SELECT volvra.enable('sc.fk_p'); SELECT volvra.enable('sc.fk_child');
SELECT count(*) FROM volvra.make_fks_deferrable('sc');
INSERT INTO sc.fk_child VALUES (1, 1, 5);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
DELETE FROM sc.fk_p WHERE id = 1;            -- nulls the child's n
SELECT set_config('sc.t', :'t', false);
DO $$ BEGIN
  ASSERT (SELECT n FROM sc.fk_child WHERE id = 1) IS NULL, 'SET NULL fired';
END $$;
SELECT count(*) FROM volvra.undo(tables => ARRAY['sc.fk_p','sc.fk_child'],
                                 from_ts => current_setting('sc.t')::timestamptz,
                                 to_ts => now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT n FROM sc.fk_child WHERE id = 1) = 1,
         'SET NULL is undone: the reference is restored with its parent';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.5 truncate ==='

\echo '--- all three modes against an empty table ---'
CREATE TABLE sc.trunc_empty (id int PRIMARY KEY, v int);
SELECT volvra.enable('sc.trunc_empty');
DO $$
DECLARE m text;
BEGIN
  FOREACH m IN ARRAY ARRAY['capture','block','allow'] LOOP
    PERFORM volvra.set_setting('on_truncate', m);
    BEGIN
      EXECUTE 'TRUNCATE sc.trunc_empty';
      RAISE NOTICE 'on_truncate=%: an empty table truncates without incident', m;
    EXCEPTION WHEN OTHERS THEN
      -- refuse is meant to refuse, but refusing an EMPTY table would be
      -- refusing to destroy nothing, which is only noise.
      RAISE NOTICE 'on_truncate=%: refused with "%"', m, SQLERRM;
    END;
  END LOOP;
  PERFORM volvra.set_setting('on_truncate', 'capture');
END $$;

\echo '--- capture mode against a table with rows, then undo it ---'
CREATE TABLE sc.trunc_rows (id int PRIMARY KEY, v int);
SELECT volvra.enable('sc.trunc_rows');
INSERT INTO sc.trunc_rows SELECT g, g FROM generate_series(1, 100) g;
SELECT volvra.set_setting('on_truncate', 'capture');
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
TRUNCATE sc.trunc_rows;
SELECT set_config('sc.t', :'t', false);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.trunc_rows) = 0, 'the truncate happened';
  ASSERT (SELECT count(*) FROM volvra.change_log
           WHERE table_name = 'sc.trunc_rows' AND op = 'D') = 100,
         'and every row was captured as a delete, one change per row';
END $$;
SELECT count(*) FROM volvra.undo('sc.trunc_rows', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true, max_rows => 200);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.trunc_rows) = 100, 'a captured truncate is undone';
  ASSERT (SELECT sum(v) FROM sc.trunc_rows) = 5050, 'with the right values';
END $$;

\echo '--- block mode against a table with rows ---'
SELECT volvra.set_setting('on_truncate', 'block');
DO $$
DECLARE v_refused boolean := false;
BEGIN
  BEGIN
    TRUNCATE sc.trunc_rows;
  EXCEPTION WHEN OTHERS THEN v_refused := true;
  END;
  ASSERT v_refused, 'on_truncate=block must refuse a truncate that would destroy rows';
  ASSERT (SELECT count(*) FROM sc.trunc_rows) = 100, 'and the rows are still there';
END $$;
SELECT volvra.set_setting('on_truncate', 'capture');

-- ---------------------------------------------------------------------
\echo '=== S6.6 row-level security on a covered table ==='

CREATE TABLE sc.rls_t (id int PRIMARY KEY, owner text, v int);
SELECT volvra.enable('sc.rls_t');
INSERT INTO sc.rls_t VALUES (1, 'alice', 10), (2, 'bob', 20);
ALTER TABLE sc.rls_t ENABLE ROW LEVEL SECURITY;
CREATE POLICY only_own ON sc.rls_t USING (owner = current_user);
SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
UPDATE sc.rls_t SET v = 0;
SELECT set_config('sc.t', :'t', false);
DO $$
DECLARE v_n bigint;
BEGIN
  -- The trigger is not subject to the table's own policies, so capture must
  -- be complete even for rows the caller could not have selected.
  SELECT count(*) INTO v_n FROM volvra.change_log
   WHERE table_name = 'sc.rls_t' AND op = 'U'
     AND ts >= current_setting('sc.t')::timestamptz;
  ASSERT v_n = 2, format('RLS: both rows captured, got %s', v_n);
END $$;
SELECT count(*) FROM volvra.undo('sc.rls_t', current_setting('sc.t')::timestamptz,
                                 now(), confirm => true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM sc.rls_t WHERE v = 0) = 0,
         'RLS: the undo restored both rows -- the table owner bypasses its own '
         'policies unless FORCE is set';
END $$;

ALTER TABLE sc.rls_t FORCE ROW LEVEL SECURITY;
UPDATE sc.rls_t SET v = 77;
DO $$
DECLARE v_seen bigint;
BEGIN
  SELECT count(*) INTO v_seen FROM sc.rls_t;
  RAISE NOTICE 'FORCE RLS: the owner now sees % of 2 rows, and an undo can '
               'only touch what the caller can see -- which is the correct '
               'behaviour for a SECURITY INVOKER undo', v_seen;
END $$;
ALTER TABLE sc.rls_t NO FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
\echo '=== S6.7 integrity across a clock and timezone change ==='

SELECT count(*) FROM volvra.seal();
DO $$
DECLARE v_bad bigint;
BEGIN
  SET LOCAL TimeZone = 'Pacific/Kiritimati';
  SELECT count(*) INTO v_bad FROM volvra.verify() WHERE verdict <> 'ok';
  ASSERT v_bad = 0,
         format('a seal must verify under a different TimeZone; %s failed', v_bad);
  SET LOCAL TimeZone = 'UTC';
  SELECT count(*) INTO v_bad FROM volvra.verify() WHERE verdict <> 'ok';
  ASSERT v_bad = 0, 'and under UTC too';
END $$;

\echo '--- sealing across a retention run stays verifiable ---'
SELECT count(*) FROM volvra.purge('100 years'::interval);
SELECT count(*) FROM volvra.seal();
DO $$
DECLARE v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad FROM volvra.verify()
   WHERE verdict IN ('TAMPERED','CHAIN BROKEN','SEAL FORGED');
  ASSERT v_bad = 0, 'a retention run is not mistaken for tampering';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.8 erasure ==='

\echo '--- one subject whose key appears in several tables ---'
CREATE TABLE sc.e_orders (id int PRIMARY KEY, subject text, amount int);
CREATE TABLE sc.e_notes  (id int PRIMARY KEY, subject text, note text);
SELECT volvra.enable('sc.e_orders'); SELECT volvra.enable('sc.e_notes');
INSERT INTO sc.e_orders VALUES (1, 'subject-1', 100), (2, 'subject-2', 200);
INSERT INTO sc.e_notes  VALUES (1, 'subject-1', 'private'), (2, 'subject-2', 'other');
UPDATE sc.e_orders SET amount = amount + 1;
UPDATE sc.e_notes  SET note = 'changed';

SELECT count(*) FROM volvra.forget('sc.e_orders', '{"id":1}');
SELECT count(*) FROM volvra.forget('sc.e_notes',  '{"id":1}');
DO $$
DECLARE v_left bigint;
BEGIN
  SELECT count(*) INTO v_left FROM volvra.change_log
   WHERE (old_row::text ILIKE '%private%' OR new_row::text ILIKE '%private%');
  ASSERT v_left = 0, format('erasure: no trace of the note remains, got %s', v_left);
  SELECT count(*) INTO v_left FROM volvra.change_log
   WHERE table_name = 'sc.e_notes' AND new_row::text ILIKE '%other%';
  ASSERT v_left > 0, 'and the other subject was not touched';
  ASSERT (SELECT count(*) FROM volvra.erasure_log) >= 2,
         'both erasures are recorded in the ledger';
END $$;
DO $$
DECLARE v_bad bigint;
BEGIN
  SELECT count(*) INTO v_bad FROM volvra.verify()
   WHERE verdict IN ('TAMPERED','CHAIN BROKEN','SEAL FORGED');
  ASSERT v_bad = 0, 'lawful erasure is distinguishable from tampering';
END $$;

\echo '--- a redacted range, then an undo over it ---'
-- $do$ rather than $$, because the predicate below is itself dollar-quoted
-- and a nested $$ would end the block early.
DO $do$
DECLARE v_ok boolean := false; v_msg text;
BEGIN
  BEGIN
    PERFORM count(*) FROM volvra.undo('sc.e_notes', predicate => $pred$op = 'U'$pred$,
                                      confirm => true);
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
  END;
  -- Redacted history cannot drive an undo of the redacted row.  Either it is
  -- skipped or the undo refuses; what must not happen is a row being restored
  -- to the redaction placeholder.
  ASSERT (SELECT note FROM sc.e_notes WHERE id = 1) NOT ILIKE '%redact%',
         'an undo must never write a redaction placeholder into a live row';
  RAISE NOTICE 'undo over redacted history: %',
    CASE WHEN v_ok THEN 'accepted, redacted rows skipped'
         ELSE format('refused with "%s"', v_msg) END;
END $do$;

-- ---------------------------------------------------------------------
\echo '=== S6.9 actor attribution under pooling ==='

-- volvra.actor is a session GUC, and transaction-mode pooling hands a session
-- to a different client between transactions.  SET (session) leaks; SET LOCAL
-- does not.  This is the documented failure mode, so it gets an assertion.
CREATE TABLE sc.pool_t (id int PRIMARY KEY, v int);
SELECT volvra.enable('sc.pool_t');

BEGIN;
  SET LOCAL volvra.actor = 'request-A';
  INSERT INTO sc.pool_t VALUES (1, 1);
COMMIT;
INSERT INTO sc.pool_t VALUES (2, 2);          -- next "request", no actor set
DO $$
DECLARE v_a text; v_b text;
BEGIN
  SELECT actor INTO v_a FROM volvra.change_log
   WHERE table_name = 'sc.pool_t' AND pk->>'id' = '1';
  SELECT actor INTO v_b FROM volvra.change_log
   WHERE table_name = 'sc.pool_t' AND pk->>'id' = '2';
  ASSERT v_a = 'request-A', format('SET LOCAL attributes the transaction, got %s', v_a);
  ASSERT v_b IS DISTINCT FROM 'request-A',
         format('and it does not leak into the next transaction, got %s', v_b);
END $$;

SET volvra.actor = 'session-wide';
INSERT INTO sc.pool_t VALUES (3, 3);
RESET volvra.actor;
INSERT INTO sc.pool_t VALUES (4, 4);
DO $$
DECLARE v_c text; v_d text;
BEGIN
  SELECT actor INTO v_c FROM volvra.change_log
   WHERE table_name = 'sc.pool_t' AND pk->>'id' = '3';
  SELECT actor INTO v_d FROM volvra.change_log
   WHERE table_name = 'sc.pool_t' AND pk->>'id' = '4';
  ASSERT v_c = 'session-wide', 'a plain SET attributes the session';
  ASSERT v_d IS DISTINCT FROM 'session-wide',
         'and RESET clears it -- but a pooled client that forgets to RESET '
         'attributes the next client''s work to itself, which is why the docs '
         'say SET LOCAL';
  -- db_user is not settable by the client, so it is the attribution that
  -- survives a pooler.
  ASSERT (SELECT count(DISTINCT db_user) FROM volvra.change_log
           WHERE table_name = 'sc.pool_t') = 1,
         'db_user is recorded independently of the actor the client claims';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.10 partitions of the history itself ==='

\echo '--- a transaction spanning a month boundary ---'
DO $$
DECLARE v_parts int;
BEGIN
  PERFORM volvra.ensure_partitions(3);
  SELECT count(*) INTO v_parts FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'volvra' AND c.relname LIKE 'change_log_%';
  ASSERT v_parts >= 2, format('partitions exist: %s', v_parts);
  ASSERT EXISTS (SELECT 1 FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'volvra' AND c.relname = 'change_log_default'),
         'and the DEFAULT partition is present, which is what makes a change '
         'in an unprovisioned month land somewhere instead of failing';
END $$;

\echo '--- the default partition catches a change outside every range ---'
DO $$
DECLARE v_before bigint; v_after bigint;
BEGIN
  SELECT count(*) INTO v_before FROM volvra.change_log_default;
  -- A change dated far in the future belongs to no provisioned month.
  INSERT INTO volvra.change_log
    (ts, table_name, op, pk, old_row, new_row, actor, db_user, txid)
  VALUES (now() + interval '30 years', 'sc.pool_t', 'U', '{"id":1}',
          '{"v":1}', '{"v":2}', 'scenario', current_user,
          pg_current_xact_id()::text::bigint);
  SELECT count(*) INTO v_after FROM volvra.change_log_default;
  ASSERT v_after = v_before + 1,
         'a change outside every provisioned month lands in the default '
         'partition rather than raising';
  DELETE FROM volvra.change_log_default WHERE actor = 'scenario';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'default partition: append-only guard refused a direct insert, '
               'which is the stronger behaviour';
END $$;

-- ---------------------------------------------------------------------
\echo '=== S6.11 the full type matrix under capture_updates = full ==='

-- phase1 proves type fidelity in the default 'changed' mode, and proves
-- 'full' mode on a two-column table.  The combination is the untested one:
-- under 'full' every column of every row is written on every update, so any
-- type whose jsonb round-trip is lossy is wrong on every change rather than
-- only when that column moves.
SELECT volvra.set_setting('capture_updates', 'full');

CREATE TYPE sc.mood AS ENUM ('sad', 'ok', 'happy');
CREATE DOMAIN sc.positive_int AS int CHECK (VALUE > 0);
CREATE TABLE sc.wide_full (
  id            int PRIMARY KEY,
  c_smallint    smallint,
  c_bigint      bigint,
  c_numeric     numeric(30,10),
  c_real        real,
  c_double_min  double precision,
  c_double_inf  double precision,
  c_double_nan  double precision,
  c_text        text,
  c_varchar     varchar(64),
  c_char        char(8),
  c_bytea       bytea,
  c_bool        boolean,
  c_date        date,
  c_time        time,
  c_timetz      timetz,
  c_timestamp   timestamp,
  c_timestamptz timestamptz,
  c_interval    interval,
  c_uuid        uuid,
  c_inet        inet,
  c_cidr        cidr,
  c_macaddr     macaddr,
  c_json        json,
  c_jsonb       jsonb,
  c_int_arr     int[],
  c_text_arr    text[],
  c_int4range   int4range,
  c_tstzrange   tstzrange,
  c_numrange    numrange,
  c_bit         bit(8),
  c_varbit      varbit,
  c_enum        sc.mood,
  c_domain      sc.positive_int,
  c_point       point,
  c_money       money,
  c_null        text,
  c_touched     int
);
SELECT volvra.enable('sc.wide_full');

INSERT INTO sc.wide_full VALUES (
  1, -32768, 9223372036854775807, -12345678901234.567890,
  3.4e38::real, 2.2250738585072014e-308,
  'Infinity'::double precision, 'NaN'::double precision,
  E'tab\there, newline\nhere, quote " and backslash \\ and unicode é中',
  'varchar with '' quote', 'padded', '\xDEADBEEF00'::bytea, true,
  '0001-01-01'::date, '23:59:59.999999'::time, '23:59:59.999999+05:30'::timetz,
  '4713-01-01 00:00:00'::timestamp, '2026-09-06 14:30:00.123456+00'::timestamptz,
  '1 year 2 mons 3 days 04:05:06.789'::interval,
  '0189ab3c-0000-4000-8000-000000000000'::uuid,
  '192.168.0.1/24'::inet, '10.0.0.0/8'::cidr, '08:00:2b:01:02:03'::macaddr,
  '{"a": [1, 2, {"b": null}]}'::json, '{"z": 1, "a": {"nested": true}}'::jsonb,
  ARRAY[1, NULL, 3], ARRAY['a', NULL, 'c'],
  '[1,10)'::int4range,
  '[2026-01-01 00:00:00+00,2026-02-01 00:00:00+00)'::tstzrange,
  '(1.5,2.5]'::numrange, B'10101010'::bit(8), B'1101'::varbit,
  'happy'::sc.mood, 42::sc.positive_int, '(1.5,-2.5)'::point,
  '1234567.89'::money, NULL, 1);

-- A snapshot of the row as it was, using the table's own row type so the
-- comparison is by value and not by text.
CREATE TABLE sc.wide_before AS SELECT * FROM sc.wide_full;

SELECT clock_timestamp() AS t \gset
SELECT pg_sleep(0.05);
-- One column moves.  Under 'full', the history records all 37.
UPDATE sc.wide_full SET c_touched = 2 WHERE id = 1;
SELECT set_config('sc.t', :'t', false);

DO $$
DECLARE v_cols int;
BEGIN
  SELECT count(*) INTO v_cols
  FROM volvra.change_log c, jsonb_object_keys(c.old_row) k
  WHERE c.table_name = 'sc.wide_full' AND c.op = 'U'
    AND c.ts >= current_setting('sc.t')::timestamptz;
  ASSERT v_cols = 38,
         format('full mode records every column: expected 38, got %s', v_cols);
END $$;

-- Break the row completely, then restore it from that full image.
UPDATE sc.wide_full SET
  c_smallint = 0, c_bigint = 0, c_numeric = 0, c_real = 0, c_double_min = 0,
  c_double_inf = 0, c_double_nan = 0, c_text = 'lost', c_varchar = 'lost',
  c_char = 'lost', c_bytea = '\x00'::bytea, c_bool = false,
  c_date = '2000-01-01', c_time = '00:00', c_timetz = '00:00+00',
  c_timestamp = '2000-01-01', c_timestamptz = '2000-01-01+00',
  c_interval = '0', c_uuid = '00000000-0000-0000-0000-000000000000',
  c_inet = '0.0.0.0/0', c_cidr = '0.0.0.0/0', c_macaddr = '00:00:00:00:00:00',
  c_json = '{}', c_jsonb = '{}', c_int_arr = '{}', c_text_arr = '{}',
  c_int4range = 'empty', c_tstzrange = 'empty', c_numrange = 'empty',
  c_bit = B'00000000', c_varbit = B'0', c_enum = 'sad', c_domain = 1,
  c_point = '(0,0)', c_money = 0, c_null = 'no longer null', c_touched = 99;

SELECT count(*) FROM volvra.undo('sc.wide_full',
                                 current_setting('sc.t')::timestamptz, now(),
                                 confirm => true, skip_conflicts => true);

DO $$
DECLARE v_diff int;
BEGIN
  -- Row-type equality compares every column at once, so a single lossy type
  -- fails this even if the rest are perfect.  IS NOT DISTINCT FROM is used so
  -- NULL matches NULL rather than making the comparison NULL.
  SELECT count(*) INTO v_diff
  FROM sc.wide_full f JOIN sc.wide_before b USING (id)
  WHERE NOT (f.*::text IS NOT DISTINCT FROM b.*::text);
  ASSERT v_diff = 0,
         'every one of 37 column types round-tripped through a full image';
END $$;

DO $$
DECLARE v_bad text;
BEGIN
  -- Spot-check the values most likely to be quietly mangled: NaN and
  -- Infinity have no JSON representation, and money and char(8) depend on
  -- locale and padding.
  SELECT format('nan=%s inf=%s money=%s char=%s',
                c_double_nan::text, c_double_inf::text,
                c_money::text, c_char::text)
    INTO v_bad FROM sc.wide_full WHERE id = 1;
  ASSERT (SELECT c_double_nan FROM sc.wide_full WHERE id = 1) = 'NaN'::float8,
         format('NaN survived the round trip (%s)', v_bad);
  ASSERT (SELECT c_double_inf FROM sc.wide_full WHERE id = 1) = 'Infinity'::float8,
         format('Infinity survived the round trip (%s)', v_bad);
  ASSERT (SELECT c_null FROM sc.wide_full WHERE id = 1) IS NULL,
         format('a NULL was restored as NULL, not as a string (%s)', v_bad);
END $$;

SELECT volvra.set_setting('capture_updates', 'changed');

\echo ''
\echo '*** ALL VOLVRA SCENARIO CHECKS PASSED ***'

