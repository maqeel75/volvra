#!/usr/bin/env bash
# =====================================================================
# Volvra managed-provider verification.
#
# Everything else in test/ runs against a container we control. This
# runs against a real managed PostgreSQL -- Aurora, RDS, Cloud SQL,
# Supabase, Neon -- because that is the market Volvra's whole design
# exists for, and a claim that has only ever been tested in Docker is
# an untested claim.
#
# What it proves, in the order that matters:
#   1. Volvra installs as a non-superuser, which no provider gives you.
#   2. The parts providers restrict actually work: partitioning, RLS,
#      cluster-wide roles, statement triggers.
#   3. An undo round-trips real data.
#   4. preflight() reports nothing critical.
#   5. Whether the durable tier is available, and if not, exactly why.
#
#   ./test/provider.sh --dsn "postgres://user@host:5432/dbname"
#   PGHOST=... PGUSER=... ./test/provider.sh
#
# Point it at a THROWAWAY database. It installs Volvra and, unless
# --keep is given, removes the schema afterwards -- which destroys
# history. It refuses to run against a database whose change_log
# already holds rows.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSN=""; ASSUME_YES=0; KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dsn)  DSN="${2:?--dsn needs a value}"; shift 2 ;;
    --yes)  ASSUME_YES=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

PSQL=(psql -v ON_ERROR_STOP=1 -X)
[[ -n "$DSN" ]] && PSQL+=("$DSN")
# Notices are suppressed for value queries only. preview_undo() deliberately
# raises one, and with stderr merged it landed inside the value being compared
# -- so a correct answer of "3" arrived as "NOTICE: ...\n3" and failed. The
# sections that print output for the reader call psql directly and still show
# notices, which is where they belong.
q()  { PGOPTIONS='-c client_min_messages=warning' "${PSQL[@]}" -tAc "$1" 2>&1 \
         | tr -d '\r'; }
run(){ "${PSQL[@]}" -f "$1" 2>&1; }

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  --    %s\n' "$*"; SKIP=$((SKIP+1)); }
note() { printf '        %s\n' "$*"; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v psql >/dev/null || { echo "psql is not on PATH" >&2; exit 2; }

# ---------------------------------------------------------------------
head_ "0. connection"
WHOAMI=$(q "SELECT current_user")
if [[ -z "$WHOAMI" || "$WHOAMI" == *ERROR* || "$WHOAMI" == *error* ]]; then
  echo "  could not connect:"; printf '        %s\n' "$WHOAMI"; exit 1
fi
SRV=$(q "SHOW server_version")
DBNAME=$(q "SELECT current_database()")
IS_SUPER=$(q "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
note "database   $DBNAME"
note "server     $SRV"
note "role       $WHOAMI (superuser: $IS_SUPER)"
note "provider   $(q "SELECT coalesce(nullif(current_setting('rds.extensions', true), ''), 'n/a')" | cut -c1-48)"

# A provider's master user must NOT be a superuser. If it is, this is not
# the environment we mean to be testing.
if [[ "$IS_SUPER" == "f" ]]; then
  ok "the installing role is not a superuser, which is the point"
else
  bad "the installing role IS a superuser -- this is not a managed-provider test"
  note "Volvra's design exists because providers give you no superuser."
  note "Run this against the provider's own master user."
fi

# Safety: never destroy someone's real history.
EXISTING=$(q "SELECT count(*) FROM volvra.change_log" 2>/dev/null)
if [[ "$EXISTING" =~ ^[0-9]+$ && "$EXISTING" -gt 0 ]]; then
  echo
  echo "  REFUSING: volvra.change_log already holds $EXISTING row(s) here."
  echo "  This script removes the volvra schema when it finishes, which would"
  echo "  destroy that history. Point it at a throwaway database."
  exit 1
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  echo
  printf "  This installs Volvra into '%s' and %s afterwards. Continue? [y/N] " \
    "$DBNAME" "$([[ $KEEP -eq 1 ]] && echo 'keeps it' || echo 'drops the volvra schema')"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "  nothing was changed."; exit 1; }
fi

cleanup() {
  if [[ $KEEP -eq 1 ]]; then
    printf '\n  --keep: leaving the volvra schema and probe objects in place\n'
    return
  fi
  "${PSQL[@]}" -q -c "DROP SCHEMA IF EXISTS volvra_probe CASCADE" >/dev/null 2>&1
  "${PSQL[@]}" -q -c "DROP SCHEMA IF EXISTS volvra CASCADE" >/dev/null 2>&1
  "${PSQL[@]}" -q -c "SELECT pg_drop_replication_slot('volvra_probe_slot')" >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------
head_ "1. privileges the install needs"
for priv in CREATE; do
  if [[ "$(q "SELECT has_database_privilege(current_user, current_database(), '$priv')")" == "t" ]]; then
    ok "$priv on the database"
  else
    bad "$priv on the database -- the install cannot create its schema"
  fi
done
CREATEROLE=$(q "SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user")
if [[ "$CREATEROLE" == "t" ]]; then
  ok "CREATEROLE, so the three volvra_* roles can be created"
else
  bad "CREATEROLE is absent -- the volvra_* roles cannot be created"
  note "Without them the privilege checks degrade to permissive. Grant"
  note "CREATEROLE, or have an administrator create the roles."
fi

head_ "2. the three cluster-wide roles"
for r in volvra_viewer volvra_operator volvra_admin; do
  if [[ "$(q "SELECT count(*) FROM pg_roles WHERE rolname='$r'")" == "1" ]]; then
    ok "$r exists already"
  else
    OUT=$("${PSQL[@]}" -q -c "CREATE ROLE $r NOLOGIN" 2>&1)
    if [[ $? -eq 0 ]]; then ok "created $r"
    else bad "could not create $r"; printf '        | %s\n' "$(head -1 <<<"$OUT")"; fi
  fi
done
"${PSQL[@]}" -q -c "GRANT volvra_viewer TO volvra_operator" >/dev/null 2>&1
"${PSQL[@]}" -q -c "GRANT volvra_operator TO volvra_admin"  >/dev/null 2>&1

# ---------------------------------------------------------------------
head_ "3. the install itself"
OUT=$(run "$ROOT/sql/volvra.sql")
if grep -q "volvra installed" <<<"$OUT"; then
  ok "$(grep -o 'volvra installed.*' <<<"$OUT" | head -1)"
else
  bad "the install did not complete"
  grep -iE "error" <<<"$OUT" | head -4 | sed 's/^/        | /'
  exit 1
fi

OUT2=$(run "$ROOT/sql/volvra.sql")
grep -q "volvra installed" <<<"$OUT2" \
  && ok "and installing a second time is a no-op" \
  || bad "and installing a second time is a no-op"

# ---------------------------------------------------------------------
head_ "4. the features providers most often restrict"
[[ "$(q "SELECT relkind FROM pg_class WHERE oid='volvra.change_log'::regclass")" == "p" ]] \
  && ok "change_log is range-partitioned" \
  || bad "change_log is range-partitioned"
PARTS=$(q "SELECT count(*) FROM pg_inherits WHERE inhparent='volvra.change_log'::regclass")
[[ "${PARTS:-0}" -ge 2 ]] \
  && ok "$PARTS partitions were provisioned, including the default" \
  || bad "partitions were provisioned (got ${PARTS:-0})"
[[ "$(q "SELECT relrowsecurity FROM pg_class WHERE oid='volvra.change_log'::regclass")" == "t" ]] \
  && ok "row-level security is enabled on the history" \
  || bad "row-level security is enabled on the history"
[[ "$(q "SELECT count(*) FROM pg_policy WHERE polrelid='volvra.change_log'::regclass")" -ge 1 ]] \
  && ok "and its read policy exists" \
  || bad "and its read policy exists"

# ---------------------------------------------------------------------
head_ "5. an undo, on real data"
"${PSQL[@]}" -q >/dev/null 2>&1 <<'SQL'
DROP SCHEMA IF EXISTS volvra_probe CASCADE;
CREATE SCHEMA volvra_probe;
CREATE TABLE volvra_probe.salaries (id int PRIMARY KEY, name text, amount numeric);
SQL
COV=$(q "SELECT volvra.enable('volvra_probe.salaries')")
[[ "$COV" == *"capture enabled"* ]] && ok "enable() covered the table" \
                                   || { bad "enable() covered the table"; note "$COV"; }

"${PSQL[@]}" -q >/dev/null 2>&1 <<'SQL'
INSERT INTO volvra_probe.salaries VALUES (1,'ada',50000),(2,'grace',60000),(3,'alan',70000);
CREATE TABLE volvra_probe.mark AS SELECT clock_timestamp() AS at;
SELECT pg_sleep(0.2);
SET volvra.actor = 'provider-check';
UPDATE volvra_probe.salaries SET amount = 0;
SQL
[[ "$(q "SELECT count(*) FROM volvra.change_log WHERE table_name='volvra_probe.salaries'")" == "6" ]] \
  && ok "6 changes captured (3 inserts, 3 updates)" \
  || bad "6 changes captured (got $(q "SELECT count(*) FROM volvra.change_log WHERE table_name='volvra_probe.salaries'"))"
[[ "$(q "SELECT count(DISTINCT actor) FROM volvra.change_log WHERE actor='provider-check'")" -ge 1 ]] \
  && ok "and the application-declared actor was recorded" \
  || bad "and the application-declared actor was recorded"

PLAN=$(q "SELECT count(*) FROM volvra.preview_undo('volvra_probe.salaries',
            (SELECT at FROM volvra_probe.mark), now())")
[[ "$PLAN" == "3" ]] && ok "preview planned 3 compensating statements" \
                     || bad "preview planned 3 compensating statements (got $PLAN)"

"${PSQL[@]}" -q -c "SELECT count(*) FROM volvra.undo('volvra_probe.salaries',
     (SELECT at FROM volvra_probe.mark), now(), confirm => true)" >/dev/null 2>&1
RESTORED=$(q "SELECT string_agg(amount::text, ',' ORDER BY id) FROM volvra_probe.salaries")
[[ "$RESTORED" == "50000,60000,70000" ]] \
  && ok "the undo restored every value" \
  || bad "the undo restored every value (got '$RESTORED')"

head_ "6. TRUNCATE capture, which needs a statement trigger"
"${PSQL[@]}" -q -c "SELECT volvra.set_setting('on_truncate','capture')" >/dev/null 2>&1
"${PSQL[@]}" -q -c "CREATE TABLE volvra_probe.t2 AS SELECT * FROM volvra_probe.salaries" >/dev/null 2>&1
"${PSQL[@]}" -q -c "ALTER TABLE volvra_probe.t2 ADD PRIMARY KEY (id)" >/dev/null 2>&1
"${PSQL[@]}" -q -c "SELECT volvra.enable('volvra_probe.t2')" >/dev/null 2>&1
"${PSQL[@]}" -q -c "TRUNCATE volvra_probe.t2" >/dev/null 2>&1
[[ "$(q "SELECT count(*) FROM volvra.change_log WHERE table_name='volvra_probe.t2' AND op='D'")" == "3" ]] \
  && ok "a TRUNCATE was captured row by row" \
  || bad "a TRUNCATE was captured row by row"

# ---------------------------------------------------------------------
head_ "7. maintenance, sealing and verification"
"${PSQL[@]}" -q -c "SELECT count(*) FROM volvra.maintain()" >/dev/null 2>&1 \
  && ok "maintain() ran" || bad "maintain() ran"
SEALED=$(q "SELECT coalesce(sum(row_count),0) FROM volvra.seal")
[[ "${SEALED:-0}" -gt 0 ]] && ok "seal() covered $SEALED change(s)" \
                           || bad "seal() covered any changes (got ${SEALED:-0})"
[[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")" == "0" ]] \
  && ok "verify() found nothing wrong" \
  || bad "verify() found nothing wrong"

head_ "8. preflight"
"${PSQL[@]}" -c "SELECT severity, finding FROM volvra.preflight()
                 WHERE severity <> 'info' ORDER BY severity" 2>&1 | sed 's/^/        /'
CRIT=$(q "SELECT count(*) FROM volvra.preflight() WHERE severity='critical'")
if [[ "${CRIT:-1}" == "0" ]]; then
  ok "no critical findings"
else
  bad "$CRIT critical finding(s) -- an install here is not production-shaped"
fi

# ---------------------------------------------------------------------
head_ "9. the durable tier (optional; the trigger tier does not need it)"
WAL=$(q "SHOW wal_level")
note "wal_level = $WAL"
if [[ "$WAL" == "logical" ]]; then
  ok "wal_level is logical, so the companion can run"
  SLOT=$("${PSQL[@]}" -tAc "SELECT pg_create_logical_replication_slot('volvra_probe_slot','pgoutput')" 2>&1)
  if [[ "$SLOT" == *volvra_probe_slot* ]]; then
    ok "a pgoutput logical slot can be created"
    "${PSQL[@]}" -q -c "SELECT pg_drop_replication_slot('volvra_probe_slot')" >/dev/null 2>&1
  else
    bad "a pgoutput logical slot can be created"
    printf '        | %s\n' "$(head -1 <<<"$SLOT")"
    note "On RDS and Aurora the role needs rds_replication:"
    note "  GRANT rds_replication TO $WHOAMI;"
  fi
  "${PSQL[@]}" -c "SELECT step, object, detail FROM volvra.companion_setup('volvra_probe')" 2>&1 \
    | sed 's/^/        /' | head -8
else
  skip "wal_level is '$WAL', so the durable tier is unavailable here"
  note "This does NOT affect the trigger tier, which is what most"
  note "deployments use. To enable it on Aurora or RDS, set"
  note "rds.logical_replication = 1 in the DB cluster parameter group"
  note "and reboot the writer instance, then re-run this script."
fi

# ---------------------------------------------------------------------
printf '\n\033[1mresult\033[0m  %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
printf 'server  %s as %s (superuser: %s)\n' "$SRV" "$WHOAMI" "$IS_SUPER"
if [[ $FAIL -eq 0 ]]; then
  printf '\nVolvra works on this provider. Paste this block back when reporting.\n'
  exit 0
fi
printf '\n%d check(s) failed. Paste this whole output back when reporting.\n' "$FAIL"
exit 1
