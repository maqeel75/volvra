#!/usr/bin/env bash
# =====================================================================
# Volvra test matrix.
#
# Every suite runs TWICE per PostgreSQL version, in two privilege
# contexts:
#
#   owner  -- installed and operated by a non-superuser owning the
#             database, holding CREATEROLE and CREATEDB.  This is what a
#             managed provider gives you, and it is the recommended
#             production install.
#   super  -- installed and operated by a superuser.  Convenient, and
#             what volvra.preflight() grades as critical.
#
# Running both is the point.  Until this existed, 263 of 272 assertions
# had only ever executed as a superuser, which is how two GRANT
# statements silently failed to apply and no test noticed.
#
# The owner context runs FIRST, deliberately: the volvra_* roles are
# cluster-wide, and whichever context installs first creates them and
# holds admin option on them.  A non-superuser cannot grant roles it
# does not administer, so reversing the order breaks the owner context.
#
#   ./test/run.sh                # 14 15 16 17 18 19
#   ./test/run.sh 16 17          # just those
#   ./test/run.sh --context super 17    # one context only
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONTEXTS=(owner super)
VERSIONS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXTS=("${2:?--context needs owner or super}"); shift 2 ;;
    *)         VERSIONS+=("$1"); shift ;;
  esac
done
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)

# PostgreSQL 19 has no GA image yet; the beta tag is the closest thing.
image_for() {
  case "$1" in
    19) echo "postgres:19beta1" ;;
     *) echo "postgres:$1" ;;
  esac
}

# Every marker a full battery must print.
MARKERS=(
  'ALL VOLVRA ACCEPTANCE CHECKS PASSED'
  'ALL VOLVRA SECURITY CHECKS PASSED'
  'ALL VOLVRA PHASE 1 CHECKS PASSED'
  'ALL VOLVRA PHASE 2 CHECKS PASSED'
  'ALL VOLVRA PHASE 3 CHECKS PASSED'
  'ALL VOLVRA PHASE 4 CHECKS PASSED'
  'ALL VOLVRA PRIVILEGE MATRIX CHECKS PASSED'
)

PASS=(); FAIL=()
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"

for v in "${VERSIONS[@]}"; do
  img="$(image_for "$v")"
  cname="volvra-test-pg$v-$$"

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ PostgreSQL $v  ($img)"

  docker rm -f "$cname" >/dev/null 2>&1
  if ! docker run -d --name "$cname" \
        -e POSTGRES_PASSWORD=volvra -e POSTGRES_DB=postgres \
        -v "$ROOT:/volvra:ro" "$img" >/dev/null 2>"$LOGDIR/pg$v-start.log"; then
    echo "  ✗ could not start container"
    FAIL+=("$v (container start)"); continue
  fi

  ready=0
  for _ in $(seq 1 60); do
    docker exec "$cname" pg_isready -U postgres -d postgres >/dev/null 2>&1 \
      && { ready=1; break; }
    sleep 1
  done
  if [[ $ready -ne 1 ]]; then
    echo "  ✗ server never became ready"
    docker logs "$cname" >>"$LOGDIR/pg$v-start.log" 2>&1
    docker rm -f "$cname" >/dev/null 2>&1
    FAIL+=("$v (not ready)"); continue
  fi

  server_version="$(docker exec "$cname" psql -U postgres -d postgres -tAc \
                    'SHOW server_version' 2>/dev/null | tr -d '[:space:]')"
  echo "  server_version = $server_version"

  su_psql() { docker exec "$cname" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }

  # The unprivileged owner is created once per cluster and owns its own
  # database; REPLICATION is not granted, because the trigger tier must not
  # need it.
  su_psql -c "CREATE ROLE volvra_owner LOGIN PASSWORD 'volvra' CREATEROLE CREATEDB" \
    >/dev/null 2>&1


  version_ok=1

  for ctx in "${CONTEXTS[@]}"; do
    case "$ctx" in
      owner) ctx_user=volvra_owner; ctx_db=volvra_owner_db ;;
      super) ctx_user=postgres;     ctx_db=volvra_super_db ;;
      *) echo "  ✗ unknown context $ctx"; version_ok=0; continue ;;
    esac

    log="$LOGDIR/pg$v-$ctx.log"
    : >"$log"

    if [[ "$ctx" == "owner" ]]; then
      su_psql -c "CREATE DATABASE $ctx_db OWNER $ctx_user" >/dev/null 2>&1
    else
      su_psql -c "CREATE DATABASE $ctx_db" >/dev/null 2>&1
    fi

    q() { docker exec "$cname" psql -v ON_ERROR_STOP=1 -U "$ctx_user" -d "$ctx_db" "$@"; }

    # Roles are cluster-wide: whichever context installs first creates the
    # volvra_* roles and holds admin option on them, and a non-superuser cannot
    # grant a role it does not administer.  A superuser hands the owner what it
    # needs, which is what a real DBA would do and what makes the order of the
    # contexts irrelevant.  Idempotent, and a no-op before the first install.
    su_psql -c "DO \$\$ BEGIN
                  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='volvra_admin') THEN
                    EXECUTE 'GRANT volvra_admin TO volvra_owner WITH ADMIN OPTION';
                  END IF;
                END \$\$" >/dev/null 2>&1

    {
      echo "### context: $ctx (as $ctx_user) ###"
      echo "### install ###"
      q -f /volvra/sql/volvra.sql
      echo "### reinstall (idempotency) ###"
      q -f /volvra/sql/volvra.sql
      echo "### acceptance ###"
      q -f /volvra/test/acceptance.sql
      echo "### security ###"
      q -f /volvra/test/security.sql
      echo "### phase 1 (correctness) ###"
      q -f /volvra/test/phase1.sql
      echo "### phase 2 (scope) ###"
      q -f /volvra/test/phase2.sql
      echo "### phase 3 (scale) ###"
      q -f /volvra/test/phase3.sql
      echo "### phase 4 (trust) ###"
      q -f /volvra/test/phase4.sql
      echo "### privilege matrix ###"
      q -f /volvra/test/privileges.sql
    } >>"$log" 2>&1
    rc=$?

    missing=()
    for m in "${MARKERS[@]}"; do
      grep -q "$m" "$log" || missing+=("${m#ALL VOLVRA }")
    done

    if [[ $rc -eq 0 && ${#missing[@]} -eq 0 ]]; then
      echo "  ✓ $ctx: install×2 + acceptance + security + phase1-4 + privileges"
    else
      echo "  ✗ $ctx: FAILED (rc=$rc)${missing[*]+, missing: ${missing[*]}}"
      grep -nE "^psql.*ERROR|^ERROR" "$log" | head -3 | sed 's/^/        /'
      version_ok=0
    fi
  done

  # Suites that need a database of their own, run once per version.
  su_psql -c "GRANT volvra_admin TO volvra_owner WITH ADMIN OPTION" >/dev/null 2>&1

  extra_log="$LOGDIR/pg$v-extra.log"
  : >"$extra_log"
  {
    # The non-superuser install assertions get a database of their own, so the
    # owner-context battery's fixtures do not collide with theirs.
    echo "### non-superuser install assertions ###"
    su_psql -c "CREATE DATABASE volvra_nosuper OWNER volvra_owner"
    docker exec "$cname" psql -v ON_ERROR_STOP=1 -U volvra_owner -d volvra_nosuper \
      -f /volvra/sql/volvra.sql
    docker exec "$cname" psql -v ON_ERROR_STOP=1 -U volvra_owner -d volvra_nosuper \
      -f /volvra/test/nosuperuser.sql

    # The CLI suite gets a clean database: phase 4 deliberately plants
    # tampering, and `volvra verify` is supposed to report it.
    echo "### cli ###"
    su_psql -c "CREATE DATABASE volvra_cli"
    docker exec "$cname" psql -v ON_ERROR_STOP=1 -U postgres -d volvra_cli \
      -f /volvra/sql/volvra.sql
    docker exec -e PGDATABASE=volvra_cli "$cname" bash /volvra/test/cli.sh

    # Scenarios assert that verify() is clean, and phase 4 deliberately plants
    # tampering, so this needs a database of its own.  Run as the unprivileged
    # owner: it is the weaker privilege context and the recommended install.
    echo "### scenarios ###"
    su_psql -c "CREATE DATABASE volvra_scenarios OWNER volvra_owner"
    docker exec "$cname" psql -v ON_ERROR_STOP=1 -U volvra_owner -d volvra_scenarios \
      -f /volvra/sql/volvra.sql
    docker exec "$cname" psql -v ON_ERROR_STOP=1 -U volvra_owner -d volvra_scenarios \
      -f /volvra/test/scenarios.sql

    # Upgrade path: the previous released schema, real history, then the
    # current schema installed over it twice.
    echo "### upgrade from v1 ###"
    su_psql -c "CREATE DATABASE volvra_upgrade"
    u() { docker exec "$cname" psql -v ON_ERROR_STOP=1 -U postgres -d volvra_upgrade "$@"; }
    u -f /volvra/test/fixtures/volvra-v1.sql
    u -f /volvra/test/upgrade-seed.sql
    u -f /volvra/sql/volvra.sql
    u -f /volvra/sql/volvra.sql
    u -f /volvra/test/upgrade-verify.sql
  } >>"$extra_log" 2>&1
  erc=$?

  emissing=()
  for m in 'VOLVRA NON-SUPERUSER INSTALL PASSED' \
           'ALL VOLVRA CLI CHECKS PASSED' \
           'ALL VOLVRA SCENARIO CHECKS PASSED' \
           'VOLVRA UPGRADE FROM V1 PASSED'; do
    grep -q "$m" "$extra_log" || emissing+=("$m")
  done

  if [[ $erc -eq 0 && ${#emissing[@]} -eq 0 ]]; then
    echo "  ✓ extra: non-superuser install + cli + scenarios + upgrade"
  else
    echo "  ✗ extra: FAILED (rc=$erc)${emissing[*]+, missing: ${emissing[*]}}"
    grep -nE "^psql.*ERROR|^ERROR|FAIL " "$extra_log" | head -3 | sed 's/^/        /'
    version_ok=0
  fi

  if [[ $version_ok -eq 1 ]]; then
    PASS+=("$v/$server_version")
  else
    FAIL+=("$v")
  fi

  docker rm -f "$cname" >/dev/null 2>&1
done

echo "──────────────────────────────────────────────────────────────"
echo "contexts: ${CONTEXTS[*]}"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
