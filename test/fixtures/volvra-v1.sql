-- =====================================================================
-- Volvra — undo for Postgres (v0, trigger tier)
--
-- Pure SQL / PL/pgSQL. No C, no superuser required.
-- Tested on PostgreSQL 14 .. 18 (see test/run.sh).
--
-- Install:  psql -f sql/volvra.sql
-- =====================================================================

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS volvra;

-- Signatures that changed shape across versions must be dropped, not replaced.
DROP FUNCTION IF EXISTS volvra.set_setting(text, text);
DROP FUNCTION IF EXISTS volvra.get_setting(text);
DROP FUNCTION IF EXISTS volvra.history(regclass, jsonb);
DROP FUNCTION IF EXISTS volvra.undo(regclass, timestamptz, timestamptz, boolean, integer);
DROP FUNCTION IF EXISTS volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean);
DROP FUNCTION IF EXISTS volvra.preview_undo(regclass, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS volvra._plan(regclass, timestamptz, timestamptz, boolean, boolean);
-- CASCADE: _plan, preview_undo and undo all return this type.
DROP TYPE IF EXISTS volvra.undo_step CASCADE;

-- One row of an undo plan: the change that happened, and the statement that
-- would put it back.
CREATE TYPE volvra.undo_step AS (
  seq         bigint,
  change_id   bigint,
  table_name  text,
  op          char(1),
  inverse_op  char(1),
  pk          jsonb,
  actor       text,
  db_user     text,
  ts          timestamptz,
  conflict    boolean,   -- the live row no longer matches what was captured
  status      text,      -- planned / applied / skipped
  stmt        text
);

COMMENT ON SCHEMA volvra IS
  'Volvra: row-level undo / time machine for PostgreSQL (trigger capture tier).';

-- ---------------------------------------------------------------------
-- Roles
--
-- Created only if the installing role has CREATEROLE (or is superuser).
-- If they cannot be created, the privilege checks below degrade to
-- "unrestricted" and a WARNING is emitted -- acceptable for a laptop
-- install, NOT acceptable for production.
-- ---------------------------------------------------------------------
DO $bootstrap$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['volvra_viewer','volvra_operator','volvra_admin'] LOOP
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('CREATE ROLE %I NOLOGIN', r);
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE WARNING 'volvra: cannot create role % (no CREATEROLE); '
                    'privilege checks will be permissive -- set strict_roles=on '
                    'once the roles exist', r;
    END;
  END LOOP;
END
$bootstrap$;

-- Roles are cluster-wide, so on a second database in the same cluster they may
-- already exist and be administered by someone else.  Each grant therefore
-- stands on its own: one failure must not silently abandon the rest.
DO $hierarchy$
DECLARE
  g text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_admin') THEN
    RETURN;
  END IF;
  FOREACH g IN ARRAY ARRAY[
    'GRANT volvra_viewer TO volvra_operator',
    'GRANT volvra_operator TO volvra_admin',
    -- The installing role administers what it just installed.  Without this a
    -- non-superuser owner would create the roles and then be locked out of its
    -- own enable()/set_setting() -- superusers never notice, because
    -- pg_has_role always says yes for them.
    format('GRANT volvra_admin TO %I', current_user)
  ] LOOP
    BEGIN
      EXECUTE g;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'volvra: "%" failed: % -- grant it by hand as a role that '
                    'administers volvra_admin', g, SQLERRM;
    END;
  END LOOP;
END
$hierarchy$;

-- ---------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS volvra.change_log (
  id          bigserial PRIMARY KEY,
  table_name  text        NOT NULL,          -- quoted, schema-qualified
  -- I/U/D are row images.  T marks a TRUNCATE whose rows were NOT captured:
  -- a hole in the history that undo must refuse to step over silently.
  op          char(1)     NOT NULL CHECK (op IN ('I','U','D','T')),
  pk          jsonb       NOT NULL,
  old_row     jsonb,
  new_row     jsonb,
  actor       text        NOT NULL,   -- app-declared; SPOOFABLE by design
  db_user     text        NOT NULL DEFAULT session_user,  -- authoritative
  txid        bigint      NOT NULL,
  ts          timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE volvra.change_log ADD COLUMN IF NOT EXISTS db_user text
  NOT NULL DEFAULT session_user;

DO $upgrade$
BEGIN
  ALTER TABLE volvra.change_log DROP CONSTRAINT IF EXISTS change_log_op_check;
  ALTER TABLE volvra.change_log
    ADD CONSTRAINT change_log_op_check CHECK (op IN ('I','U','D','T'));
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'volvra: could not refresh the op constraint: %', SQLERRM;
END
$upgrade$;

CREATE INDEX IF NOT EXISTS change_log_table_ts_idx
  ON volvra.change_log (table_name, ts);
CREATE INDEX IF NOT EXISTS change_log_pk_idx
  ON volvra.change_log USING gin (pk jsonb_path_ops);
CREATE INDEX IF NOT EXISTS change_log_txid_idx
  ON volvra.change_log (txid);

COMMENT ON TABLE volvra.change_log IS
  'Append-only before/after images. UPDATE and DELETE are blocked by a guard trigger.';

-- Tables currently under capture
CREATE TABLE IF NOT EXISTS volvra.enabled_tables (
  table_name  text PRIMARY KEY,
  pk_columns  text[]      NOT NULL,
  enabled_at  timestamptz NOT NULL DEFAULT now(),
  enabled_by  text        NOT NULL DEFAULT current_user
);

-- Audit of every undo attempt, previewed or applied
CREATE TABLE IF NOT EXISTS volvra.undo_log (
  id          bigserial PRIMARY KEY,
  ts          timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor       text        NOT NULL,
  table_name  text        NOT NULL,
  from_ts     timestamptz,
  to_ts       timestamptz,
  db_user     text        NOT NULL DEFAULT current_user,
  row_count   bigint      NOT NULL,
  confirmed   boolean     NOT NULL,
  cap         bigint,
  cap_override boolean    NOT NULL DEFAULT false,
  txid        bigint      NOT NULL DEFAULT txid_current()
);

-- Configuration
CREATE TABLE IF NOT EXISTS volvra.settings (
  key   text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO volvra.settings(key, value) VALUES
  ('max_undo_rows', '10000'),
  -- 'on' => a missing volvra_* role is a hard error instead of a permissive
  --         no-op.  Turn this on for any deployment that matters.
  ('strict_roles',  'off'),
  -- What to do when a captured table is TRUNCATEd.  Row triggers do not fire on
  -- TRUNCATE, so the default is to capture every row first: silently losing a
  -- whole table is the one accident this tool must never miss.
  --   capture -- write a delete image per row, then allow the truncate
  --   block   -- refuse the truncate outright
  --   allow   -- let it through, recording only a T marker (history gap)
  ('on_truncate', 'capture'),
  -- Above this many rows, 'capture' refuses rather than quietly writing a copy
  -- of the whole table into the history.
  ('truncate_capture_max_rows', '100000')
  ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Append-only guard
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._guard_append_only() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- The only legitimate way past this guard is volvra.purge(), which opens a
  -- transaction-local window.  The GUC alone is NOT sufficient -- any role can
  -- SET it -- so membership in volvra_admin is required as well.
  IF TG_OP = 'DELETE'
     AND coalesce(current_setting('volvra.allow_purge', true), 'off') = 'on'
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_admin')
     AND pg_has_role(current_user, 'volvra_admin', 'USAGE')
  THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'volvra.% is append-only (attempted %)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'insufficient_privilege';
END
$$;

DROP TRIGGER IF EXISTS volvra_append_only ON volvra.change_log;
CREATE TRIGGER volvra_append_only
  BEFORE UPDATE OR DELETE ON volvra.change_log
  FOR EACH ROW EXECUTE FUNCTION volvra._guard_append_only();

DROP TRIGGER IF EXISTS volvra_no_truncate ON volvra.change_log;
CREATE TRIGGER volvra_no_truncate
  BEFORE TRUNCATE ON volvra.change_log
  FOR EACH STATEMENT EXECUTE FUNCTION volvra._guard_append_only();

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

-- Fully-qualified, quoted name. Stable regardless of search_path.
CREATE OR REPLACE FUNCTION volvra._fqname(target regclass) RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format('%I.%I', n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = target
$$;

-- Insertable / updatable columns (excludes dropped and GENERATED columns).
CREATE OR REPLACE FUNCTION volvra._columns(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated = ''
$$;

-- Columns that may appear in an UPDATE ... SET.  GENERATED ALWAYS AS IDENTITY
-- columns are excluded: Postgres forbids updating them, and by the same rule
-- they can never have changed, so there is nothing to restore.
CREATE OR REPLACE FUNCTION volvra._setcols(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attgenerated = ''
    AND a.attidentity <> 'a'
$$;

-- Primary key columns, in index order.
CREATE OR REPLACE FUNCTION volvra._pkcols(target regclass) RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(a.attname::text ORDER BY k.ord), '{}')
  FROM pg_index i
  CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
  WHERE i.indrelid = target AND i.indisprimary
$$;

-- Does the table have a GENERATED ALWAYS AS IDENTITY column?
CREATE OR REPLACE FUNCTION volvra._has_system_identity(target regclass) RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = target AND attnum > 0 AND NOT attisdropped AND attidentity = 'a'
  )
$$;

-- The authenticated principal, and the one place that decides what "who" means.
--
-- session_user alone is wrong: it ignores SET ROLE.  current_user alone is wrong
-- too: inside the SECURITY DEFINER capture trigger it is the function owner.
-- The `role` GUC survives the definer boundary and can only ever name a role the
-- caller is genuinely a member of, so it is both correct and unspoofable.
CREATE OR REPLACE FUNCTION volvra._db_user() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(nullif(current_setting('role', true), 'none'), session_user)
$$;

COMMENT ON FUNCTION volvra._db_user() IS
  'Authenticated principal: the SET ROLE target if one is active, else session_user. '
  'Never the SECURITY DEFINER owner.';

CREATE OR REPLACE FUNCTION volvra._actor() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(nullif(current_setting('volvra.actor', true), ''), volvra._db_user())
$$;

COMMENT ON FUNCTION volvra._actor() IS
  'Attributed actor: the volvra.actor GUC if the app sets one, else the '
  'authenticated principal. Spoofable by design -- db_user is the audit column.';

-- Extract the pk subset of a row image.
CREATE OR REPLACE FUNCTION volvra._extract_pk(row_img jsonb, pkcols text[]) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(jsonb_object_agg(c, row_img -> c), '{}'::jsonb)
  FROM unnest(pkcols) AS c
$$;

-- Membership check. Permissive if the role was never created (see bootstrap).
CREATE OR REPLACE FUNCTION volvra._require(role_name text) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    -- Fail closed when the operator asked us to.
    IF coalesce((SELECT value FROM volvra.settings WHERE key = 'strict_roles'), 'off') = 'on'
    THEN
      RAISE EXCEPTION 'volvra: role % does not exist and strict_roles is on', role_name
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN;
  END IF;
  IF NOT pg_has_role(current_user, role_name, 'USAGE') THEN
    RAISE EXCEPTION 'volvra: % is required for this operation (current_user=%)',
      role_name, current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- change_log holds complete row images, so reading it must never be a way
-- around the base table's own grants.  Enforced twice: explicitly here, and
-- by row-level security on change_log itself.
CREATE OR REPLACE FUNCTION volvra._require_read(target regclass) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT has_table_privilege(target, 'SELECT') THEN
    RAISE EXCEPTION 'volvra: permission denied to read history of %', target::text
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.get_setting(p_key text) RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT s.value FROM volvra.settings s WHERE s.key = p_key $$;

-- Parameters are p_-prefixed: bare `key`/`value` would be ambiguous against the
-- settings columns inside ON CONFLICT.
CREATE OR REPLACE FUNCTION volvra.set_setting(p_key text, p_value text) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_admin');
  INSERT INTO volvra.settings AS s (key, value) VALUES (p_key, p_value)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
END
$$;

-- ---------------------------------------------------------------------
-- Capture
--
-- SECURITY DEFINER so that arbitrary writers need no INSERT grant on
-- change_log -- that is what makes the history unforgeable by ordinary
-- application roles.  Install as a dedicated owner role, never as a
-- superuser, in production.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.capture() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_op      char(1);
  v_old     jsonb;
  v_new     jsonb;
  v_pk_src  jsonb;
  v_tbl     text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
BEGIN
  -- Refuse to write history for a table volvra.enable() did not arm.  Without
  -- this, anyone able to attach this trigger to a table of their own could
  -- forge change_log entries or fill the history table at will.
  IF NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e WHERE e.table_name = v_tbl) THEN
    RAISE EXCEPTION 'volvra.capture: % is not registered via volvra.enable()', v_tbl
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_op := 'I'; v_new := to_jsonb(NEW); v_pk_src := v_new;
  ELSIF TG_OP = 'UPDATE' THEN
    v_op := 'U'; v_old := to_jsonb(OLD); v_new := to_jsonb(NEW); v_pk_src := v_new;
  ELSE
    v_op := 'D'; v_old := to_jsonb(OLD); v_pk_src := v_old;
  END IF;

  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid)
  VALUES (
    v_tbl,
    v_op,
    volvra._extract_pk(v_pk_src, TG_ARGV),
    v_old,
    v_new,
    volvra._actor(),
    volvra._db_user(),
    txid_current()
  );

  RETURN NULL;  -- AFTER trigger; return value ignored
END
$$;

-- ---------------------------------------------------------------------
-- TRUNCATE capture
--
-- Row triggers do not fire on TRUNCATE, so without this a captured table can be
-- emptied with no history and no warning -- the largest possible accident being
-- the one the tool cannot see.  A statement trigger closes it.
--
-- Behaviour is set by the on_truncate setting: capture (default), block, allow.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.capture_truncate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl   text := format('%I.%I', TG_TABLE_SCHEMA, TG_TABLE_NAME);
  v_mode  text := coalesce(volvra.get_setting('on_truncate'), 'capture');
  v_cap   bigint := coalesce(volvra.get_setting('truncate_capture_max_rows')::bigint, 100000);
  v_pk    text[];
  v_rows  bigint;
BEGIN
  SELECT e.pk_columns INTO v_pk
  FROM volvra.enabled_tables e WHERE e.table_name = v_tbl;

  IF v_pk IS NULL THEN
    RAISE EXCEPTION 'volvra.capture_truncate: % is not registered via volvra.enable()', v_tbl
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_mode = 'block' THEN
    RAISE EXCEPTION 'volvra: TRUNCATE of % is blocked', v_tbl
      USING HINT = 'DELETE is captured and reversible. To allow truncates, set '
                   'on_truncate to capture or allow.',
            ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_mode = 'capture' THEN
    EXECUTE format('SELECT count(*) FROM %s', v_tbl) INTO v_rows;

    IF v_rows > v_cap THEN
      RAISE EXCEPTION 'volvra: refusing to capture % rows before truncating %',
        v_rows, v_tbl
        USING HINT = 'Raise truncate_capture_max_rows to copy them into the '
                     'history anyway, or set on_truncate to allow and accept '
                     'that these rows will be unrecoverable.',
              ERRCODE = 'program_limit_exceeded';
    END IF;

    EXECUTE format(
      'INSERT INTO volvra.change_log '
      '  (table_name, op, pk, old_row, new_row, actor, db_user, txid) '
      'SELECT %L, ''D'', volvra._extract_pk(to_jsonb(t), %L::text[]), to_jsonb(t), '
      '       NULL, volvra._actor(), volvra._db_user(), txid_current() '
      'FROM %s AS t', v_tbl, v_pk, v_tbl);

    RETURN NULL;
  END IF;

  -- 'allow': leave a marker so the gap is visible in history and undo refuses
  -- to step over it rather than silently half-restoring the table.
  INSERT INTO volvra.change_log
    (table_name, op, pk, old_row, new_row, actor, db_user, txid)
  VALUES (v_tbl, 'T', '{}'::jsonb, NULL, NULL,
          volvra._actor(), volvra._db_user(), txid_current());

  RETURN NULL;
END
$$;

-- ---------------------------------------------------------------------
-- enable / disable
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.enable(target regclass) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl    text   := volvra._fqname(target);
  v_pkcols text[] := volvra._pkcols(target);
  v_args   text;
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF split_part(v_tbl, '.', 1) = 'volvra' THEN
    RAISE EXCEPTION 'volvra.enable(%): volvra''s own tables cannot be captured', v_tbl;
  END IF;

  IF cardinality(v_pkcols) = 0 THEN
    RAISE EXCEPTION 'volvra.enable(%): table has no PRIMARY KEY; '
                    'v0 identifies rows by primary key', v_tbl;
  END IF;

  SELECT string_agg(quote_literal(c), ', ') INTO v_args FROM unnest(v_pkcols) AS c;

  EXECUTE format(
    'CREATE OR REPLACE TRIGGER volvra_capture '
    'AFTER INSERT OR UPDATE OR DELETE ON %s '
    'FOR EACH ROW EXECUTE FUNCTION volvra.capture(%s)', v_tbl, v_args);

  -- Registered first, then armed: capture_truncate() refuses tables it does not
  -- find in enabled_tables, so the row below must land before the trigger fires.
  INSERT INTO volvra.enabled_tables AS e (table_name, pk_columns)
  VALUES (v_tbl, v_pkcols)
  ON CONFLICT (table_name) DO UPDATE
    SET pk_columns = EXCLUDED.pk_columns,
        enabled_at = now(),
        enabled_by = current_user;

  EXECUTE format(
    'CREATE OR REPLACE TRIGGER volvra_capture_truncate '
    'BEFORE TRUNCATE ON %s '
    'FOR EACH STATEMENT EXECUTE FUNCTION volvra.capture_truncate()', v_tbl);

  RETURN format('volvra: capture enabled on %s (pk: %s)',
                v_tbl, array_to_string(v_pkcols, ', '));
END
$$;

CREATE OR REPLACE FUNCTION volvra.disable(target regclass) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tbl text := volvra._fqname(target);
BEGIN
  PERFORM volvra._require('volvra_admin');
  EXECUTE format('DROP TRIGGER IF EXISTS volvra_capture ON %s', v_tbl);
  EXECUTE format('DROP TRIGGER IF EXISTS volvra_capture_truncate ON %s', v_tbl);
  DELETE FROM volvra.enabled_tables WHERE table_name = v_tbl;
  RETURN format('volvra: capture disabled on %s (history retained)', v_tbl);
END
$$;

-- ---------------------------------------------------------------------
-- Arming a whole schema
--
-- enable() is per table, so a table created next month is silently
-- unprotected -- and "protection starts at setup" only holds if setup is
-- exhaustive.  These are idempotent, so the same call doubles as a sync after
-- a migration adds tables.
--
-- Deliberately not an event trigger: CREATE EVENT TRIGGER is superuser-only,
-- and the whole point of volvra is that it installs without one.  Call
-- enable_all() from your migration tooling instead.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.enable_all(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, status text, detail text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');

  IF p_schema = 'volvra' THEN
    RAISE EXCEPTION 'volvra: volvra''s own schema cannot be captured';
  END IF;

  FOR r IN
    SELECT c.oid::regclass AS rel, format('%I.%I', n.nspname, c.relname) AS fq,
           cardinality(volvra._pkcols(c.oid)) AS npk,
           EXISTS (SELECT 1 FROM volvra.enabled_tables e
                   WHERE e.table_name = format('%I.%I', n.nspname, c.relname)) AS armed
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema
      AND c.relkind IN ('r', 'p')          -- ordinary and partitioned tables
      AND c.relpersistence = 'p'           -- not temp, not unlogged
    ORDER BY c.relname
  LOOP
    table_name := r.fq;

    IF r.npk = 0 THEN
      status := 'skipped';
      detail := 'no primary key: volvra identifies rows by pk';
    ELSE
      BEGIN
        PERFORM volvra.enable(r.rel);
        status := CASE WHEN r.armed THEN 'already armed' ELSE 'armed' END;
        detail := NULL;
      EXCEPTION WHEN OTHERS THEN
        status := 'failed';
        detail := SQLERRM;
      END;
    END IF;

    RETURN NEXT;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION volvra.disable_all(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, status text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');
  FOR r IN
    SELECT e.table_name AS fq FROM volvra.enabled_tables e
    WHERE split_part(e.table_name, '.', 1) = quote_ident(p_schema)
       OR split_part(e.table_name, '.', 1) = p_schema
    ORDER BY e.table_name
  LOOP
    table_name := r.fq;
    IF to_regclass(r.fq) IS NULL THEN
      DELETE FROM volvra.enabled_tables WHERE enabled_tables.table_name = r.fq;
      status := 'table gone: registration removed';
    ELSE
      PERFORM volvra.disable(to_regclass(r.fq));
      status := 'disarmed (history retained)';
    END IF;
    RETURN NEXT;
  END LOOP;
END
$$;

-- Tables that exist, could be armed, and are not.  This is the drift alarm:
-- an unarmed table is a table with no undo.
CREATE OR REPLACE FUNCTION volvra.unarmed(p_schema text DEFAULT 'public')
RETURNS TABLE (table_name text, reason text)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT format('%I.%I', n.nspname, c.relname),
           CASE WHEN cardinality(volvra._pkcols(c.oid)) = 0
                THEN 'no primary key'
                ELSE 'never armed' END
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema
      AND c.relkind IN ('r', 'p')
      AND c.relpersistence = 'p'
      AND NOT EXISTS (SELECT 1 FROM volvra.enabled_tables e
                      WHERE e.table_name = format('%I.%I', n.nspname, c.relname))
    ORDER BY c.relname;
END
$$;

-- ---------------------------------------------------------------------
-- make_fks_deferrable
--
-- A one-time setup step that makes multi-table undo possible without
-- dependency-ordering every plan.  DEFERRABLE INITIALLY IMMEDIATE changes
-- nothing about day-to-day behaviour -- constraints are still checked at the
-- end of each statement -- it only grants undo the right to defer them to
-- COMMIT inside its own transaction.
--
-- Takes a brief ACCESS EXCLUSIVE lock per table, so run it in a maintenance
-- window like any other ALTER TABLE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.make_fks_deferrable(p_schema text DEFAULT 'public')
RETURNS TABLE (constraint_name text, table_name text, status text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  r record;
BEGIN
  PERFORM volvra._require('volvra_admin');
  FOR r IN
    SELECT con.conname, format('%I.%I', n.nspname, c.relname) AS fq
    FROM pg_constraint con
    JOIN pg_class c     ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE con.contype = 'f'
      AND n.nspname = p_schema
      AND NOT con.condeferrable
    ORDER BY c.relname, con.conname
  LOOP
    constraint_name := r.conname;
    table_name      := r.fq;
    BEGIN
      EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE',
                     r.fq, r.conname);
      status := 'now deferrable';
    EXCEPTION WHEN OTHERS THEN
      status := 'failed: ' || SQLERRM;
    END;
    RETURN NEXT;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- status -- one query that answers "is volvra doing its job?"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.status()
RETURNS TABLE (
  table_name    text,
  armed         boolean,
  truncate_safe boolean,
  changes       bigint,
  oldest_change timestamptz,
  newest_change timestamptz
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT e.table_name,
           -- registered *and* the trigger is really still attached: an owner can
           -- disable a trigger behind volvra's back.
           EXISTS (SELECT 1 FROM pg_trigger t
                   WHERE t.tgrelid = to_regclass(e.table_name)
                     AND t.tgname = 'volvra_capture' AND t.tgenabled <> 'D'),
           EXISTS (SELECT 1 FROM pg_trigger t
                   WHERE t.tgrelid = to_regclass(e.table_name)
                     AND t.tgname = 'volvra_capture_truncate' AND t.tgenabled <> 'D'),
           count(c.id),
           min(c.ts), max(c.ts)
    FROM volvra.enabled_tables e
    LEFT JOIN volvra.change_log c ON c.table_name = e.table_name
    GROUP BY e.table_name
    ORDER BY e.table_name;
END
$$;

-- ---------------------------------------------------------------------
-- history
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.history(target regclass, pk jsonb)
RETURNS TABLE (
  change_id bigint,
  ts        timestamptz,
  actor     text,
  db_user   text,
  op        char(1),
  txid      bigint,
  old_row   jsonb,
  new_row   jsonb
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_read(target);
  RETURN QUERY
    SELECT c.id, c.ts, c.actor, c.db_user, c.op, c.txid, c.old_row, c.new_row
    FROM volvra.change_log c
    WHERE c.table_name = volvra._fqname(history.target)
      AND c.pk @> history.pk
    ORDER BY c.id;
END
$$;

-- ---------------------------------------------------------------------
-- Schema drift
--
-- A row image captured before an ALTER TABLE may no longer fit the table it
-- came from.  Rather than carry a schema fingerprint on every captured row --
-- which would cost a catalog lookup per write -- the image is validated at
-- plan time, when it actually matters, against the columns that exist now.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._validate_image(target regclass, row_img jsonb)
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_gone    text[];
  v_missing text[];
BEGIN
  IF row_img IS NULL THEN
    RETURN;
  END IF;

  -- columns the image carries that the table no longer has
  SELECT array_agg(k ORDER BY k) INTO v_gone
  FROM jsonb_object_keys(row_img) AS k
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_attribute a
    WHERE a.attrelid = target AND a.attname = k
      AND a.attnum > 0 AND NOT a.attisdropped);

  -- columns the table now requires that the image cannot supply
  SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO v_missing
  FROM pg_attribute a
  WHERE a.attrelid = target
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attgenerated = '' AND a.attidentity = ''
    AND a.attnotnull
    AND NOT a.atthasdef
    AND NOT (row_img ? a.attname::text);

  IF v_gone IS NOT NULL OR v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'volvra: % has changed shape since this row was captured', target::text
      USING DETAIL = format('captured columns no longer present: %s; '
                            'required columns not in the captured row: %s',
                            coalesce(array_to_string(v_gone, ', '), 'none'),
                            coalesce(array_to_string(v_missing, ', '), 'none')),
            HINT = 'Restore these rows by hand, or narrow the window to changes '
                   'captured under the current schema.',
            ERRCODE = 'datatype_mismatch';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- Compensating-SQL generation
--
-- Statements embed their row image as a jsonb literal, so the text returned by
-- preview_undo is byte-identical to what undo executes.
--
-- Each statement also carries its own optimistic-concurrency guard: it only
-- matches if the live row is still exactly what was captured.  That turns
-- "someone changed this row after the accident" from silent data loss into a
-- statement that affects zero rows, which undo then reports as a conflict.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._stmt_insert(
  v_tbl text, v_cols text[], v_identity boolean, row_img jsonb, guarded boolean)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'INSERT INTO %s (%s)%s SELECT %s FROM jsonb_populate_record(NULL::%s, %L::jsonb)%s',
    v_tbl,
    (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_cols) AS c),
    CASE WHEN v_identity THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END,
    (SELECT string_agg(quote_ident(c), ', ') FROM unnest(v_cols) AS c),
    v_tbl,
    row_img,
    -- guard: the row must still be absent, or this is a conflict
    CASE WHEN guarded THEN ' ON CONFLICT DO NOTHING' ELSE '' END)
$$;

CREATE OR REPLACE FUNCTION volvra._stmt_delete(
  v_tbl text, v_pkcols text[], pk_img jsonb, expected jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'DELETE FROM %s AS tgt USING jsonb_populate_record(NULL::%s, %L::jsonb) AS k WHERE %s%s',
    v_tbl, v_tbl, pk_img,
    (SELECT string_agg(format('tgt.%1$I IS NOT DISTINCT FROM k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c),
    CASE WHEN expected IS NULL THEN ''
         ELSE format(' AND to_jsonb(tgt) = %L::jsonb', expected) END)
$$;

-- Locate the row by its *current* (post-change) pk, restore every column from
-- the old image -- so an UPDATE that changed the pk still reverts.
CREATE OR REPLACE FUNCTION volvra._stmt_update(
  v_tbl text, v_cols text[], v_pkcols text[],
  old_img jsonb, key_img jsonb, expected jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'UPDATE %s AS tgt SET %s FROM jsonb_populate_record(NULL::%s, %L::jsonb) AS src, '
    'jsonb_populate_record(NULL::%s, %L::jsonb) AS k WHERE %s%s',
    v_tbl,
    (SELECT string_agg(format('%1$I = src.%1$I', c), ', ') FROM unnest(v_cols) AS c),
    v_tbl, old_img,
    v_tbl, key_img,
    (SELECT string_agg(format('tgt.%1$I IS NOT DISTINCT FROM k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c),
    CASE WHEN expected IS NULL THEN ''
         ELSE format(' AND to_jsonb(tgt) = %L::jsonb', expected) END)
$$;

-- Read the live row image for a pk, or NULL if the row is gone.
CREATE OR REPLACE FUNCTION volvra._stmt_probe(
  v_tbl text, v_pkcols text[], pk_img jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT format(
    'SELECT to_jsonb(tgt) FROM %s AS tgt, jsonb_populate_record(NULL::%s, %L::jsonb) AS k '
    'WHERE %s',
    v_tbl, v_tbl, pk_img,
    (SELECT string_agg(format('tgt.%1$I IS NOT DISTINCT FROM k.%1$I', c), ' AND ')
     FROM unnest(v_pkcols) AS c))
$$;

-- ---------------------------------------------------------------------
-- The selector
--
-- Phase 1 could only answer "what happened to this table between these two
-- timestamps".  Real accidents are not shaped like that: a bad migration is one
-- transaction across several tables, and a misbehaving service is an actor.  So
-- every public entry point funnels through one selector, and the callers differ
-- only in which criteria they fill in.
--
-- p_predicate is a SQL fragment over the captured row (`old_row`, `new_row`,
-- `pk`, `actor`, `db_user`, `ts`, `txid`).  It is parenthesised before it is
-- spliced in, so it cannot chain a second statement, and it runs with the
-- caller's own privileges -- it is a WHERE clause, not an escalation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._where(
  p_tables    regclass[],
  p_from_ts   timestamptz,
  p_to_ts     timestamptz,
  p_txids     bigint[],
  p_actors    text[],
  p_db_users  text[],
  p_predicate text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_parts text[] := '{}';
  v_names text[];
BEGIN
  IF p_tables IS NOT NULL AND cardinality(p_tables) > 0 THEN
    SELECT array_agg(volvra._fqname(t)) INTO v_names FROM unnest(p_tables) AS t;
    v_parts := v_parts || format('c.table_name = ANY (%L::text[])', v_names);
  ELSE
    -- Never plan over tables volvra is not responsible for.
    -- ::text matters: an untyped literal makes Postgres pick array||array.
    v_parts := v_parts ||
      'c.table_name IN (SELECT e.table_name FROM volvra.enabled_tables e)'::text;
  END IF;

  IF p_from_ts  IS NOT NULL THEN v_parts := v_parts || format('c.ts > %L', p_from_ts); END IF;
  IF p_to_ts    IS NOT NULL THEN v_parts := v_parts || format('c.ts <= %L', p_to_ts); END IF;
  IF p_txids    IS NOT NULL THEN v_parts := v_parts || format('c.txid = ANY (%L::bigint[])', p_txids); END IF;
  IF p_actors   IS NOT NULL THEN v_parts := v_parts || format('c.actor = ANY (%L::text[])', p_actors); END IF;
  IF p_db_users IS NOT NULL THEN v_parts := v_parts || format('c.db_user = ANY (%L::text[])', p_db_users); END IF;

  IF p_predicate IS NOT NULL AND btrim(p_predicate) <> '' THEN
    -- The predicate is a WHERE fragment, not a statement.  Parenthesising it
    -- already stops it opening a second statement, but a semicolon or a comment
    -- opener has no legitimate use in an expression, so refuse them outright
    -- rather than rely on the parser to make the attempt fail.
    IF p_predicate ~ '(;|--|/\*)' THEN
      RAISE EXCEPTION 'volvra: predicate may not contain '';'', ''--'' or ''/*'''
        USING DETAIL = 'A predicate is a boolean expression over old_row, new_row, '
                       'pk, actor, db_user, ts and txid.',
              ERRCODE = 'syntax_error';
    END IF;
    v_parts := v_parts || format('(%s)', p_predicate);
  END IF;

  RETURN array_to_string(v_parts, ' AND ');
END
$$;

-- Per-table metadata, memoised for the life of one plan.  Without this a plan
-- spanning tables would re-read the catalog for every row.
CREATE OR REPLACE FUNCTION volvra._meta(target regclass) RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_build_object(
    'fq',       volvra._fqname(target),
    'cols',     to_jsonb(volvra._columns(target)),
    'setcols',  to_jsonb(volvra._setcols(target)),
    'pkcols',   to_jsonb(volvra._pkcols(target)),
    'identity', volvra._has_system_identity(target))
$$;

-- ---------------------------------------------------------------------
-- Plan: the selected change set in reverse chronological order, each row
-- paired with the statement that puts it back.
--
-- Reverse chronological across every selected table, not per table: undoing a
-- transaction means walking it backwards as a whole.
--
-- p_guard   -- emit statements carrying the optimistic-concurrency guard
-- p_probe   -- additionally read each live row to report conflicts up front
--              (preview does this; undo relies on the guard instead, so it
--              costs one statement per row rather than two)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._plan(
  p_tables    regclass[]  DEFAULT NULL,
  p_from_ts   timestamptz DEFAULT NULL,
  p_to_ts     timestamptz DEFAULT NULL,
  p_txids     bigint[]    DEFAULT NULL,
  p_actors    text[]      DEFAULT NULL,
  p_db_users  text[]      DEFAULT NULL,
  p_predicate text        DEFAULT NULL,
  p_guard     boolean     DEFAULT true,
  p_probe     boolean     DEFAULT false)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_where    text := volvra._where(p_tables, p_from_ts, p_to_ts, p_txids,
                                   p_actors, p_db_users, p_predicate);
  v_cache    jsonb := '{}'::jsonb;   -- table_name -> metadata
  v_m        jsonb;
  v_rel      regclass;
  v_i        bigint := 0;
  v_step     volvra.undo_step;
  v_live     jsonb;
  v_cols     text[];
  v_setcols  text[];
  v_pkcols   text[];
  r          record;
BEGIN
  FOR r IN EXECUTE format(
    'SELECT c.id, c.table_name, c.op, c.pk, c.old_row, c.new_row, '
    '       c.actor, c.db_user, c.ts '
    'FROM volvra.change_log c WHERE %s ORDER BY c.id DESC', v_where)
  LOOP
    -- A TRUNCATE whose rows were never captured cannot be inverted, and
    -- stepping over it would produce a half-restored table that looks whole.
    IF r.op = 'T' THEN
      RAISE EXCEPTION 'volvra: this selection contains a TRUNCATE of % that was not captured',
        r.table_name
        USING DETAIL = format('change %s at %s', r.id, r.ts),
              HINT = 'The rows are unrecoverable from history. Select either side '
                     'of the truncate, or restore it from a backup.',
              ERRCODE = 'data_exception';
    END IF;

    IF NOT (v_cache ? r.table_name) THEN
      v_rel := to_regclass(r.table_name);
      IF v_rel IS NULL THEN
        RAISE EXCEPTION 'volvra: % no longer exists, so its history cannot be replayed',
          r.table_name
          USING ERRCODE = 'undefined_table';
      END IF;
      v_cache := v_cache || jsonb_build_object(r.table_name, volvra._meta(v_rel));
    END IF;

    v_m       := v_cache -> r.table_name;
    v_rel     := to_regclass(r.table_name);
    v_cols    := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'cols'));
    v_setcols := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'setcols'));
    v_pkcols  := ARRAY(SELECT jsonb_array_elements_text(v_m -> 'pkcols'));

    IF cardinality(v_pkcols) = 0 THEN
      RAISE EXCEPTION 'volvra: % has no PRIMARY KEY', r.table_name;
    END IF;

    v_i := v_i + 1;
    v_step.seq        := v_i;
    v_step.change_id  := r.id;
    v_step.table_name := r.table_name;
    v_step.op         := r.op;
    v_step.pk         := r.pk;
    v_step.actor      := r.actor;
    v_step.db_user    := r.db_user;
    v_step.ts         := r.ts;
    v_step.status     := 'planned';
    v_step.conflict   := NULL;

    PERFORM volvra._validate_image(v_rel, coalesce(r.old_row, r.new_row));

    IF r.op = 'I' THEN
      v_step.inverse_op := 'D';
      v_step.stmt := volvra._stmt_delete(
        r.table_name, v_pkcols, r.pk, CASE WHEN p_guard THEN r.new_row END);
    ELSIF r.op = 'D' THEN
      v_step.inverse_op := 'I';
      v_step.stmt := volvra._stmt_insert(
        r.table_name, v_cols, (v_m ->> 'identity')::boolean, r.old_row, p_guard);
    ELSE
      v_step.inverse_op := 'U';
      v_step.stmt := volvra._stmt_update(
        r.table_name, v_setcols, v_pkcols, r.old_row, r.pk,
        CASE WHEN p_guard THEN r.new_row END);
    END IF;

    IF p_probe THEN
      EXECUTE volvra._stmt_probe(r.table_name, v_pkcols, r.pk) INTO v_live;
      v_step.conflict := CASE
        WHEN r.op = 'D' THEN v_live IS NOT NULL          -- should still be gone
        ELSE v_live IS DISTINCT FROM r.new_row           -- should be untouched
      END;
    END IF;

    RETURN NEXT v_step;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------
-- Scoping shared by preview_undo and undo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra._resolve_tables(
  target regclass, tables regclass[]) RETURNS regclass[]
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN tables IS NOT NULL AND cardinality(tables) > 0 THEN
      CASE WHEN target IS NULL THEN tables ELSE tables || target END
    WHEN target IS NOT NULL THEN ARRAY[target]
    ELSE NULL
  END
$$;

-- Reading any plan means reading full row images, so the caller must be able to
-- read every table the plan touches -- checked per table, not once.
CREATE OR REPLACE FUNCTION volvra._require_read_all(p_tables regclass[])
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  t regclass;
BEGIN
  IF p_tables IS NOT NULL AND cardinality(p_tables) > 0 THEN
    FOREACH t IN ARRAY p_tables LOOP
      PERFORM volvra._require_read(t);
    END LOOP;
    RETURN;
  END IF;

  -- Unscoped: the caller must be able to read every armed table, or they would
  -- learn about the ones they cannot.
  FOR t IN SELECT to_regclass(e.table_name) FROM volvra.enabled_tables e
           WHERE to_regclass(e.table_name) IS NOT NULL
  LOOP
    PERFORM volvra._require_read(t);
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION volvra._require_scope(
  p_tables regclass[], p_from_ts timestamptz, p_to_ts timestamptz,
  p_txids bigint[], p_actors text[], p_db_users text[], p_predicate text)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_tables IS NULL AND p_from_ts IS NULL AND p_to_ts IS NULL
     AND p_txids IS NULL AND p_actors IS NULL AND p_db_users IS NULL
     AND (p_predicate IS NULL OR btrim(p_predicate) = '') THEN
    RAISE EXCEPTION 'volvra: refusing to plan an undo with no scope at all'
      USING HINT = 'Name a table, a time window, a txid, an actor, or a predicate.',
            ERRCODE = 'null_value_not_allowed';
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- preview_undo -- never executes anything
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.preview_undo(
  target      regclass    DEFAULT NULL,
  from_ts     timestamptz DEFAULT NULL,
  to_ts       timestamptz DEFAULT NULL,
  txid        bigint      DEFAULT NULL,
  actor       text        DEFAULT NULL,
  db_user     text        DEFAULT NULL,
  predicate   text        DEFAULT NULL,
  tables      regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables    regclass[] := volvra._resolve_tables(target, tables);
  v_txids     bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors    text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers   text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_count     bigint;
  v_conflicts bigint;
  v_tabcount  bigint;
BEGIN
  PERFORM volvra._require('volvra_viewer');
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);

  SELECT count(*), count(*) FILTER (WHERE p.conflict), count(DISTINCT p.table_name)
    INTO v_count, v_conflicts, v_tabcount
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, true) p;

  IF v_conflicts > 0 THEN
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be reverted, but % row(s) '
                 'have changed since -- undo will refuse unless you pass skip_conflicts => true',
      v_count, v_tabcount, v_conflicts;
  ELSE
    RAISE NOTICE 'volvra: % change(s) across % table(s) would be reverted '
                 '(preview only, nothing executed)', v_count, v_tabcount;
  END IF;

  RETURN QUERY
    SELECT * FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors,
                               v_dbusers, predicate, true, true);
END
$$;

-- ---------------------------------------------------------------------
-- undo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.undo(
  target         regclass    DEFAULT NULL,
  from_ts        timestamptz DEFAULT NULL,
  to_ts          timestamptz DEFAULT NULL,
  confirm        boolean     DEFAULT false,
  max_rows       integer     DEFAULT NULL,
  -- On a row that has moved on since it was captured: refuse the whole undo
  -- (default), or revert everything else and leave that row alone.  There is
  -- deliberately no "overwrite anyway" option -- that is the data loss the
  -- conflict guard exists to prevent.
  skip_conflicts boolean     DEFAULT false,
  txid           bigint      DEFAULT NULL,
  actor          text        DEFAULT NULL,
  db_user        text        DEFAULT NULL,
  predicate      text        DEFAULT NULL,
  tables         regclass[]  DEFAULT NULL)
RETURNS SETOF volvra.undo_step
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_tables  regclass[] := volvra._resolve_tables(target, tables);
  v_txids   bigint[]   := CASE WHEN txid    IS NULL THEN NULL ELSE ARRAY[txid]    END;
  v_actors  text[]     := CASE WHEN actor   IS NULL THEN NULL ELSE ARRAY[actor]   END;
  v_dbusers text[]     := CASE WHEN db_user IS NULL THEN NULL ELSE ARRAY[db_user] END;
  v_cap     bigint := coalesce(max_rows, volvra.get_setting('max_undo_rows')::bigint, 10000);
  v_plan    volvra.undo_step[];
  v_step    volvra.undo_step;
  v_count   bigint;
  v_tabs    text[];
  v_skipped bigint := 0;
  v_rc      bigint;
  v_lock    text;
BEGIN
  IF confirm THEN
    PERFORM volvra._require('volvra_operator');
  ELSE
    PERFORM volvra._require('volvra_viewer');
  END IF;
  PERFORM volvra._require_scope(v_tables, from_ts, to_ts, v_txids, v_actors,
                                v_dbusers, predicate);
  PERFORM volvra._require_read_all(v_tables);

  IF from_ts IS NOT NULL AND to_ts IS NOT NULL AND from_ts >= to_ts THEN
    RAISE EXCEPTION 'volvra.undo: empty window (from_ts % >= to_ts %)', from_ts, to_ts;
  END IF;

  -- Build the plan exactly once.  The blast-radius cap has to be checked before
  -- anything is applied, which is why this is materialised rather than streamed.
  SELECT coalesce(array_agg(p ORDER BY p.seq), '{}')
    INTO v_plan
  FROM volvra._plan(v_tables, from_ts, to_ts, v_txids, v_actors, v_dbusers,
                    predicate, true, NOT confirm) p;

  v_count := cardinality(v_plan);

  SELECT array_agg(DISTINCT s.table_name ORDER BY s.table_name)
    INTO v_tabs FROM unnest(v_plan) AS s;

  IF v_count > v_cap THEN
    RAISE EXCEPTION 'volvra.undo: % rows exceeds cap of %', v_count, v_cap
      USING HINT = 'Narrow the selection, or pass max_rows => N to override deliberately.',
            ERRCODE = 'program_limit_exceeded';
  END IF;

  INSERT INTO volvra.undo_log
    (actor, table_name, from_ts, to_ts, row_count, confirmed, cap, cap_override, db_user)
  VALUES (volvra._actor(),
          coalesce(array_to_string(v_tabs, ', '), '(none)'),
          from_ts, to_ts, v_count, confirm, v_cap,
          max_rows IS NOT NULL, volvra._db_user());

  IF NOT confirm THEN
    RAISE NOTICE 'volvra: % change(s) would be reverted. '
                 'Nothing executed -- re-run with confirm => true.', v_count;
    RETURN QUERY SELECT * FROM unnest(v_plan);
    RETURN;
  END IF;

  -- Serialise undos table by table, in a stable order so two concurrent undos
  -- of overlapping selections queue rather than deadlock.  Concurrent *writers*
  -- need no lock: the per-statement guard turns them into conflicts, not races.
  IF v_tabs IS NOT NULL THEN
    FOREACH v_lock IN ARRAY v_tabs LOOP
      PERFORM pg_advisory_xact_lock(hashtextextended('volvra:' || v_lock, 0));
    END LOOP;
  END IF;

  -- Reverse-chronological order is right for the data but can trip a foreign
  -- key when a plan spans related tables -- undoing a cascade wants the parent
  -- back before its children.  Deferring the checks to COMMIT sidesteps the
  -- ordering entirely, but only works for constraints declared DEFERRABLE,
  -- which is what volvra.make_fks_deferrable() is for.
  BEGIN
    SET CONSTRAINTS ALL DEFERRED;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  FOREACH v_step IN ARRAY v_plan LOOP
    BEGIN
      EXECUTE v_step.stmt;
    EXCEPTION WHEN foreign_key_violation THEN
      RAISE EXCEPTION 'volvra.undo: a foreign key blocked reverting %', v_step.table_name
        USING DETAIL = format('row %s (change %s): %s', v_step.pk, v_step.change_id, SQLERRM),
              HINT = 'This plan spans related tables and the constraint is not '
                     'DEFERRABLE. Run volvra.make_fks_deferrable() once as an '
                     'admin, or undo one table at a time in dependency order.',
              ERRCODE = 'foreign_key_violation';
    END;
    GET DIAGNOSTICS v_rc = ROW_COUNT;

    IF v_rc = 1 THEN
      v_step.status   := 'applied';
      v_step.conflict := false;
    ELSIF skip_conflicts THEN
      -- apply what can still be applied; a row that moved on is left alone,
      -- never guessed at.
      v_step.status   := 'skipped';
      v_step.conflict := true;
      v_skipped       := v_skipped + 1;
    ELSE
      RAISE EXCEPTION 'volvra.undo: % has changed since it was captured', v_step.table_name
        USING DETAIL = format('row %s (change %s, %s by %s) no longer matches the '
                              'captured image, so reverting it would destroy a '
                              'later change',
                              v_step.pk, v_step.change_id, v_step.ts, v_step.db_user),
              HINT = 'Run preview_undo to see every conflicting row, narrow the '
                     'selection, or pass skip_conflicts => true to revert the rest '
                     'and leave these alone.',
              ERRCODE = 'serialization_failure';
    END IF;

    RETURN NEXT v_step;
  END LOOP;

  IF v_skipped > 0 THEN
    RAISE NOTICE 'volvra: reverted % change(s) across %, skipped % that had moved on',
      v_count - v_skipped, coalesce(array_to_string(v_tabs, ', '), 'nothing'), v_skipped;
  ELSE
    RAISE NOTICE 'volvra: reverted % change(s) across %',
      v_count, coalesce(array_to_string(v_tabs, ', '), 'nothing');
  END IF;
END
$$;

-- ---------------------------------------------------------------------
-- undo_txid -- "undo that migration"
--
-- The whole point of phase 2: one transaction is the unit a person actually
-- remembers, and it spans every table the migration touched.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.undo_txid(
  p_txid         bigint,
  confirm        boolean DEFAULT false,
  max_rows       integer DEFAULT NULL,
  skip_conflicts boolean DEFAULT false)
RETURNS SETOF volvra.undo_step
LANGUAGE sql
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT * FROM volvra.undo(txid => p_txid, confirm => confirm,
                            max_rows => max_rows, skip_conflicts => skip_conflicts)
$$;

CREATE OR REPLACE FUNCTION volvra.preview_undo_txid(p_txid bigint)
RETURNS SETOF volvra.undo_step
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT * FROM volvra.preview_undo(txid => p_txid)
$$;

-- ---------------------------------------------------------------------
-- transactions -- find the mistake before you undo it
--
-- Transaction-scoped undo is only usable if you can see which transaction was
-- the bad one.  This is that list.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.transactions(
  from_ts timestamptz DEFAULT NULL,
  to_ts   timestamptz DEFAULT NULL,
  p_limit integer     DEFAULT 25)
RETURNS TABLE (
  txid        bigint,
  started     timestamptz,
  ended       timestamptz,
  actors      text[],
  db_users    text[],
  tables      text[],
  inserts     bigint,
  updates     bigint,
  deletes     bigint,
  changes     bigint
)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM volvra._require('volvra_viewer');
  RETURN QUERY
    SELECT c.txid,
           min(c.ts), max(c.ts),
           array_agg(DISTINCT c.actor   ORDER BY c.actor),
           array_agg(DISTINCT c.db_user ORDER BY c.db_user),
           array_agg(DISTINCT c.table_name ORDER BY c.table_name),
           count(*) FILTER (WHERE c.op = 'I'),
           count(*) FILTER (WHERE c.op = 'U'),
           count(*) FILTER (WHERE c.op = 'D'),
           count(*)
    FROM volvra.change_log c
    WHERE (from_ts IS NULL OR c.ts >  from_ts)
      AND (to_ts   IS NULL OR c.ts <= to_ts)
    GROUP BY c.txid
    ORDER BY max(c.ts) DESC
    LIMIT p_limit;
END
$$;

-- ---------------------------------------------------------------------
-- purge -- retention / right-to-erasure
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION volvra.purge(older_than interval) RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_n bigint;
BEGIN
  PERFORM volvra._require('volvra_admin');
  PERFORM set_config('volvra.allow_purge', 'on', true);  -- transaction-local
  WITH gone AS (
    DELETE FROM volvra.change_log WHERE ts < now() - older_than RETURNING 1
  ) SELECT count(*) INTO v_n FROM gone;
  PERFORM set_config('volvra.allow_purge', 'off', true);
  RETURN v_n;
END
$$;

-- The audit trail is writable by any caller (every undo attempt must be able to
-- record itself) but never editable, and its identity column is stamped by the
-- server rather than trusted from the INSERT.
CREATE OR REPLACE FUNCTION volvra._stamp_audit() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  NEW.db_user := volvra._db_user();
  NEW.ts      := clock_timestamp();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS volvra_stamp_audit ON volvra.undo_log;
CREATE TRIGGER volvra_stamp_audit
  BEFORE INSERT ON volvra.undo_log
  FOR EACH ROW EXECUTE FUNCTION volvra._stamp_audit();

DROP TRIGGER IF EXISTS volvra_audit_append_only ON volvra.undo_log;
CREATE TRIGGER volvra_audit_append_only
  BEFORE UPDATE OR DELETE ON volvra.undo_log
  FOR EACH ROW EXECUTE FUNCTION volvra._guard_append_only();


-- ---------------------------------------------------------------------
-- Row-level security on the history
--
-- change_log holds complete before/after row images.  Without RLS it would be
-- a side channel around every base table's own SELECT grants.  Policy: you may
-- read a history row only if you may read the table it came from.
--
-- ENABLE (not FORCE) is deliberate: the schema owner bypasses it, which is
-- what lets the SECURITY DEFINER capture trigger write.
-- ---------------------------------------------------------------------
ALTER TABLE volvra.change_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE volvra.undo_log       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS change_log_read ON volvra.change_log;
CREATE POLICY change_log_read ON volvra.change_log FOR SELECT
  USING (
    pg_catalog.to_regclass(table_name) IS NOT NULL
    AND pg_catalog.has_table_privilege(pg_catalog.to_regclass(table_name), 'SELECT')
  );

-- The audit trail carries no row data, so it is readable by any viewer, and
-- appendable by any caller -- an undo attempt that could suppress its own audit
-- record would be worse than one that cannot.  The stamp trigger fixes the
-- identity, and the append-only guard makes the trail immutable.
DROP POLICY IF EXISTS undo_log_read ON volvra.undo_log;
CREATE POLICY undo_log_read ON volvra.undo_log FOR SELECT USING (true);

DROP POLICY IF EXISTS undo_log_append ON volvra.undo_log;
CREATE POLICY undo_log_append ON volvra.undo_log FOR INSERT WITH CHECK (true);

-- ---------------------------------------------------------------------
-- Grants -- least privilege
--
-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default, so every
-- function here must be revoked before anything is granted back.  Schema
-- USAGE is likewise never given to PUBLIC: a role with no volvra grants
-- cannot even name these objects.
-- ---------------------------------------------------------------------
REVOKE ALL ON SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA volvra FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA volvra FROM PUBLIC;

DO $grants$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'volvra_viewer') THEN
    RAISE WARNING 'volvra: roles absent, skipping grants -- '
                  'nothing but the installing role can use volvra';
    RETURN;
  END IF;

  -- Baseline: a viewer may read history and run the read-only helpers the
  -- public read functions are built from.  Those helpers are not a way around
  -- anything -- every one of them reads change_log, which is under RLS.
  EXECUTE 'GRANT USAGE ON SCHEMA volvra TO volvra_viewer';
  EXECUTE 'GRANT SELECT ON volvra.change_log, volvra.enabled_tables, '
          'volvra.undo_log, volvra.settings TO volvra_viewer';
  EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA volvra TO volvra_viewer';
  EXECUTE 'GRANT INSERT ON volvra.undo_log TO volvra_viewer';
  EXECUTE 'GRANT USAGE ON SEQUENCE volvra.undo_log_id_seq TO volvra_viewer';

  -- ...then take back everything that writes.  volvra_operator and
  -- volvra_admin inherit from volvra_viewer, so these must be revoked from the
  -- viewer role specifically before being granted onward.
  EXECUTE 'REVOKE ALL ON FUNCTION '
          '  volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '              bigint, text, text, text, regclass[]), '
          '  volvra.undo_txid(bigint, boolean, integer, boolean), '
          '  volvra.enable_all(text), '
          '  volvra.disable_all(text), '
          '  volvra.make_fks_deferrable(text), '
          '  volvra.enable(regclass), '
          '  volvra.disable(regclass), '
          '  volvra.set_setting(text, text), '
          '  volvra.purge(interval), '
          '  volvra.capture(), '
          '  volvra.capture_truncate(), '
          '  volvra._stamp_audit(), '
          '  volvra._guard_append_only() '
          'FROM volvra_viewer';

  -- operator: may apply an undo -- and still needs its own DML rights on the
  -- target table, because undo() is SECURITY INVOKER.
  EXECUTE 'GRANT EXECUTE ON FUNCTION '
          'volvra.undo(regclass, timestamptz, timestamptz, boolean, integer, boolean, '
          '            bigint, text, text, text, regclass[]), '
          'volvra.undo_txid(bigint, boolean, integer, boolean) '
          'TO volvra_operator';

  -- admin: configure, arm/disarm tables, enforce retention.
  EXECUTE 'GRANT EXECUTE ON FUNCTION volvra.enable(regclass), volvra.disable(regclass), '
          'volvra.set_setting(text, text), volvra.purge(interval), '
          'volvra.enable_all(text), volvra.disable_all(text), '
          'volvra.make_fks_deferrable(text) TO volvra_admin';
  EXECUTE 'GRANT INSERT, UPDATE, DELETE ON volvra.settings TO volvra_admin';
END
$grants$;

-- capture() is deliberately granted to nobody.  PostgreSQL checks EXECUTE on a
-- trigger function when the trigger is CREATED (by volvra_admin), not on every
-- firing, so ordinary writers still have their changes captured while being
-- unable to attach or call it themselves.
