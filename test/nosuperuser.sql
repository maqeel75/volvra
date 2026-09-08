-- =====================================================================
-- Volvra installed and driven by a NON-SUPERUSER role.
--
-- This is the product's central claim -- that it works on RDS, Aurora,
-- Cloud SQL, Supabase and Neon -- so it is a test, not a README sentence.
-- Runs in its own database, owned by a role with CREATEROLE/CREATEDB and
-- nothing more.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

\echo '=== N0. confirm we really are not a superuser ==='
SELECT current_user, current_setting('is_superuser') AS is_superuser;
DO $$
BEGIN
  ASSERT current_setting('is_superuser') = 'off',
         'this suite is meaningless unless the installing role is unprivileged';
  ASSERT NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user),
         'installing role must not be a superuser';
END $$;

\echo '=== N1. enable / capture / preview / undo / history, all unprivileged ==='
CREATE TABLE orders (id int PRIMARY KEY, customer text, total numeric);
SELECT volvra.enable('orders');
INSERT INTO orders VALUES (1, 'acme', 100), (2, 'globex', 42.50);

SELECT clock_timestamp() AS t0 \gset
SELECT pg_sleep(0.05);
UPDATE orders SET total = 0;

SELECT set_config('test.t0', :'t0', false);

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM volvra.preview_undo(
            'orders', current_setting('test.t0')::timestamptz, now())) = 2,
         'preview works without superuser';
  ASSERT (SELECT count(*) FROM orders WHERE total = 0) = 2,
         'preview executed nothing';
END $$;

SELECT count(*) AS reverted
FROM volvra.undo('orders', :'t0', now(), confirm => true);

DO $$
BEGIN
  ASSERT (SELECT total FROM orders WHERE id = 1) = 100,   'undo without superuser';
  ASSERT (SELECT total FROM orders WHERE id = 2) = 42.50, 'undo without superuser';
  ASSERT (SELECT count(*) FROM volvra.history('orders', '{"id":1}')) = 3,
         'history without superuser (insert + bad update + undo)';
END $$;

\echo '=== N2. the roles were created by a CREATEROLE, non-superuser owner ==='
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM pg_roles
          WHERE rolname IN ('volvra_viewer','volvra_operator','volvra_admin')) = 3,
         'volvra roles must exist after an unprivileged install';
END $$;

\echo '=== N3. append-only still holds against the schema owner ==='
DO $$
DECLARE v_state text;
BEGIN
  BEGIN
    DELETE FROM volvra.change_log WHERE true;
    RAISE EXCEPTION 'SECURITY FAILURE: the owner deleted history';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state := 'blocked';
  END;
  ASSERT v_state = 'blocked', 'append-only guard applies to the owner too';
END $$;

\echo ''
\echo '*** VOLVRA NON-SUPERUSER INSTALL PASSED ***'
