#!/usr/bin/env bash
# =====================================================================
# Volvra CLI test -- runs inside the container against the real database.
# Every command is exercised, and the destructive one is checked twice:
# once that it refuses without confirmation, once that it works with it.
# =====================================================================
set -uo pipefail

V="/volvra/bin/volvra"
# PGDATABASE comes from the runner so this suite gets a clean database of
# its own -- other phases deliberately leave damage behind.
export PGUSER=postgres
: "${PGDATABASE:=volvra_test}"; export PGDATABASE
FAILED=0

ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }

# Run a command, report pass/fail, and on failure show why -- a CLI test that
# only says FAIL is a test you have to re-run by hand to learn anything from.
try() {
  local label="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    ok "$label"
  else
    bad "$label"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# Never pipe a volvra command straight into grep: grep -q closes the pipe on
# the first match, the command's next query dies with SIGPIPE, and pipefail
# turns that into a spurious failure.  Capture the output first.
says() {   # says <label> <needle> <cmd...>
  local label="$1" needle="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  case "$out" in
    *"$needle"*) ok "$label" ;;
    *)           bad "$label"; printf '%s\n' "$out" | sed 's/^/       | /' ;;
  esac
}

q() { psql -tA -v ON_ERROR_STOP=1 -c "$1"; }

printf '=== C0. fixture ===\n'
psql -q -v ON_ERROR_STOP=1 <<'SQL'
DROP TABLE IF EXISTS cli_orders;
CREATE TABLE cli_orders (id int PRIMARY KEY, customer text, total numeric);
SQL

printf '=== C1. help and status ===\n'
"$V" --help  >/dev/null 2>&1 && ok "--help"         || bad "--help"
"$V" status  >/dev/null 2>&1 && ok "status"          || bad "status"
"$V" uncovered >/dev/null 2>&1 && ok "uncovered"         || bad "uncovered"
says "uncovered lists the new table" cli_orders "$V" uncovered

printf '=== C2. cover ===\n'
"$V" cover cli_orders >/dev/null 2>&1 && ok "cover" || bad "cover"
says "status shows it covered" cli_orders "$V" status

psql -q -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO cli_orders VALUES (1,'acme',100), (2,'globex',250);
SQL

printf '=== C3. the accident, then log ===\n'
BAD_TXID=$(psql -tA -v ON_ERROR_STOP=1 <<'SQL' | tail -1
BEGIN;
SELECT txid_current();
UPDATE cli_orders SET total = 0;
COMMIT;
SQL
)
BAD_TXID=$(psql -tA -c "SELECT txid FROM volvra.transactions() ORDER BY ended DESC LIMIT 1")
[[ -n "$BAD_TXID" ]] && ok "captured txid $BAD_TXID" || bad "could not read a txid"
"$V" log -n 3 >/dev/null 2>&1 && ok "log" || bad "log"
says "log shows the bad transaction" "$BAD_TXID" "$V" log -n 3

printf '=== C4. history ===\n'
"$V" history cli_orders '{"id":1}' >/dev/null 2>&1 && ok "history" || bad "history"
HIST=$("$V" history cli_orders '{"id":1}' 2>&1)
[[ "$(printf '%s\n' "$HIST" | grep -c '|')" -ge 3 ]] \
  && ok "history shows both versions" || bad "history shows both versions"

printf '=== C5. preview changes nothing ===\n'
"$V" preview --txid "$BAD_TXID" >/dev/null 2>&1 && ok "preview" || bad "preview"
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 0")" == "2" ]] \
  && ok "preview executed nothing" || bad "preview executed nothing"

printf '=== C6. a selector is mandatory ===\n'
"$V" undo --yes >/dev/null 2>&1 && bad "undo with no selector was allowed" \
                                || ok "undo with no selector is refused"
"$V" preview --bogus x >/dev/null 2>&1 && bad "unknown option accepted" \
                                       || ok "unknown option rejected"

printf '=== C7. undo will not apply without confirmation ===\n'
# no tty and no --yes: must refuse rather than assume
"$V" undo --txid "$BAD_TXID" </dev/null >/dev/null 2>&1 \
  && bad "undo applied without confirmation" \
  || ok "undo refuses without a confirmation"
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 0")" == "2" ]] \
  && ok "still nothing applied" || bad "still nothing applied"

printf '=== C8. undo --yes applies it ===\n'
"$V" undo --yes --txid "$BAD_TXID" >/dev/null 2>&1 && ok "undo --yes" || bad "undo --yes"
[[ "$(q "SELECT total FROM cli_orders WHERE id = 1")" == "100" ]] \
  && ok "order 1 restored" || bad "order 1 restored"
[[ "$(q "SELECT total FROM cli_orders WHERE id = 2")" == "250" ]] \
  && ok "order 2 restored" || bad "order 2 restored"

printf '=== C9. selector variants ===\n'
# A precise lower bound: '1 minute ago' would also sweep in C8's own undo.
SINCE=$(q "SELECT clock_timestamp()")
psql -q -v ON_ERROR_STOP=1 -c "SELECT pg_sleep(0.05)" >/dev/null
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_orders SET customer = 'wrong'"
try "undo --table --since --where" \
  "$V" undo --yes --table cli_orders --since "$SINCE" \
       --where "old_row->>'customer' = 'acme'"
[[ "$(q "SELECT customer FROM cli_orders WHERE id = 1")" == "acme" ]] \
  && ok "predicate limited the undo" || bad "predicate limited the undo"
[[ "$(q "SELECT customer FROM cli_orders WHERE id = 2")" == "wrong" ]] \
  && ok "the non-matching row was untouched" || bad "the non-matching row was untouched"

printf '=== C10. a predicate cannot inject ===\n'
"$V" preview --table cli_orders --where "true); DROP TABLE cli_orders; --" \
     >/dev/null 2>&1 && bad "injection accepted" || ok "injection rejected"
[[ "$(q "SELECT to_regclass('public.cli_orders') IS NOT NULL")" == "t" ]] \
  && ok "table still exists" || bad "table still exists"

printf '=== C11. schema-wide cover and uncover ===\n'
"$V" cover --schema public    >/dev/null 2>&1 && ok "cover --schema"    || bad "cover --schema"
"$V" uncover cli_orders      >/dev/null 2>&1 && ok "uncover"          || bad "uncover"

printf '=== C12. marks ===\n'
# C11 uncovered the table, so nothing after it would be captured.
try "re-cover for the marks test" "$V" cover cli_orders
try "mark"   "$V" mark cli-point --note 'from the cli test'
says "marks lists it" "cli-point" "$V" marks
psql -q -v ON_ERROR_STOP=1 -c "UPDATE cli_orders SET total = 42" >/dev/null
[[ "$(q "SELECT changes_since FROM volvra.marks() WHERE name='cli-point'")" -ge 2 ]] \
  && ok "marks counts what undoing would touch" || bad "marks counts what undoing would touch"
try "undo --to" "$V" undo --yes --to cli-point
[[ "$(q "SELECT count(*) FROM cli_orders WHERE total = 42")" == "0" ]] \
  && ok "undo --to reverted everything since the mark" \
  || bad "undo --to reverted everything since the mark"
try "unmark" "$V" unmark cli-point
"$V" mark >/dev/null 2>&1 && bad "mark with no name accepted" || ok "mark needs a name"

printf '=== C13. preflight and maintain ===\n'
# preflight exits 2 when it finds something critical -- here it will, because
# this database was installed by a superuser.
"$V" preflight >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "preflight exits 2 on a critical finding" \
               || bad "preflight exits 2 on a critical finding"
says "preflight names the superuser owner" "superuser" "$V" preflight
try "maintain" "$V" maintain
[[ "$(q "SELECT count(*) FROM volvra.change_log c
          WHERE c.id > coalesce((SELECT max(to_id) FROM volvra.seal),0)")" == "0" ]] \
  && ok "maintain left nothing unsealed" || bad "maintain left nothing unsealed"

printf '=== C14. seal, verify, forget ===\n'
try "seal"   "$V" seal
try "verify" "$V" verify
VER=$("$V" verify 2>&1)
[[ "$(printf '%s\n' "$VER" | grep -c 'TAMPERED')" == "0" ]] \
  && ok "verify reports no tampering" || bad "verify reports no tampering"

# forget must not apply without confirmation, exactly like undo
"$V" forget cli_orders '{"id":2}' </dev/null >/dev/null 2>&1 \
  && bad "forget applied without confirmation" \
  || ok "forget refuses without a confirmation"
[[ "$(q "SELECT count(*) FROM volvra.change_log
          WHERE table_name='public.cli_orders' AND pk @> '{\"id\":2}'
            AND new_row IS NOT NULL")" != "0" ]] \
  && ok "and nothing was erased" || bad "and nothing was erased"

try "forget --yes" "$V" forget cli_orders '{"id":2}' --yes --reason 'cli test'
[[ "$(q "SELECT count(*) FROM volvra.change_log
          WHERE table_name='public.cli_orders' AND pk @> '{\"id\":2}'
            AND (old_row IS NOT NULL OR new_row IS NOT NULL)")" == "0" ]] \
  && ok "the subject's row images are gone" || bad "the subject's row images are gone"
[[ "$(q "SELECT count(*) FROM volvra.erasure_log WHERE reason = 'cli test'")" == "1" ]] \
  && ok "and the erasure is recorded" || bad "and the erasure is recorded"

printf '=== C15. nothing to undo is not an error ===\n'
"$V" undo --yes --txid 999999999 >/dev/null 2>&1 \
  && ok "empty selection exits cleanly" || bad "empty selection exits cleanly"

if [[ $FAILED -eq 0 ]]; then
  printf '\n*** ALL VOLVRA CLI CHECKS PASSED ***\n'
else
  printf '\n!!! VOLVRA CLI CHECKS FAILED !!!\n'
  exit 1
fi
