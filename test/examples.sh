#!/usr/bin/env bash
# =====================================================================
# Verify every file in examples/ against a real database.
#
# Documentation that drifts from the code is worse than none, and
# examples are the documentation people actually run.  This asserts the
# end state of each one rather than just that psql exited, because two
# of them print an ERROR on purpose.
#
#   ./test/examples.sh            # 14 15 16 17 18 19
#   ./test/examples.sh 17
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS=("$@")
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)

PASS=(); FAIL=()
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"

image_for() { case "$1" in 19) echo "postgres:19beta1";; *) echo "postgres:$1";; esac; }

for v in "${VERSIONS[@]}"; do
  img="$(image_for "$v")"
  C="volvra-examples-pg$v-$$"
  log="$LOGDIR/examples-pg$v.log"; : >"$log"
  problems=()

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ examples on PostgreSQL $v ($img)"

  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=ex \
    -v "$ROOT:/volvra:ro" "$img" >/dev/null 2>&1
  for _ in $(seq 1 60); do
    docker exec "$C" pg_isready -U postgres -d ex >/dev/null 2>&1 && break; sleep 1
  done

  q() { docker exec "$C" psql -tA -U postgres -d ex -c "$1" 2>/dev/null | tr -d '[:space:]'; }
  run_example() { docker exec "$C" psql -U postgres -d ex -f "/volvra/examples/$1" >>"$log" 2>&1; }

  docker exec "$C" psql -q -U postgres -d ex -f /volvra/sql/volvra.sql >>"$log" 2>&1

  check() {  # check <label> <actual> <expected>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s (got %s, expected %s)\n' "$1" "$2" "$3"; problems+=("$1"); fi
  }

  # --- 01 -------------------------------------------------------------
  run_example 01_simple_undo.sql
  check "01 salaries restored" \
    "$(q "SELECT string_agg(salary::text,',' ORDER BY id) FROM employees")" \
    "50000,60000,70000"

  # --- 02 -------------------------------------------------------------
  run_example 02_undo_a_delete.sql
  check "02 deleted row resurrected" "$(q "SELECT count(*) FROM customers")" "2"
  check "02 payload identical" \
    "$(q "SELECT email FROM customers WHERE id=1")" "ada@example.com"
  check "02 actor recorded on the delete" \
    "$(q "SELECT actor FROM volvra.change_log WHERE table_name='public.customers' AND op='D'")" \
    "svc:billing"

  # --- 03 -------------------------------------------------------------
  run_example 03_conflict_guard.sql
  check "03 two rows reverted, the fix preserved" \
    "$(q "SELECT string_agg(amount::text,',' ORDER BY id) FROM invoices")" \
    "100,555,300"
  grep -q "has changed since it was captured" "$log" \
    && printf '  ok   %s\n' "03 the refusal happened" \
    || { printf '  FAIL %s\n' "03 the refusal happened"; problems+=("03 refusal"); }

  # --- 04 -------------------------------------------------------------
  run_example 04_bad_migration.sql
  check "04 prices restored" \
    "$(q "SELECT string_agg(price::text,',' ORDER BY id) FROM products")" "9.99,19.99"
  check "04 stock restored" \
    "$(q "SELECT string_agg(qty::text,',' ORDER BY id) FROM stock")" "100,200"
  check "04 accidental row gone" "$(q "SELECT count(*) FROM stock WHERE id=12")" "0"

  # --- 05 -------------------------------------------------------------
  run_example 05_truncate_and_integrity.sql
  check "05 truncate fully undone" "$(q "SELECT count(*) FROM audit_rows")" "50"
  grep -q "is append-only" "$log" \
    && printf '  ok   %s\n' "05 history refused to be rewritten" \
    || { printf '  FAIL %s\n' "05 history refused to be rewritten"; problems+=("05 append-only"); }
  check "05 tampering detected" \
    "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict='TAMPERED'")" "1"

  # --- 06 -------------------------------------------------------------
  run_example 06_marks.sql
  check "06 rewound to the mark" \
    "$(q "SELECT string_agg(total::text,',' ORDER BY id) FROM orders")" "100,200"
  check "06 mark removed" \
    "$(q "SELECT count(*) FROM volvra.restore_point WHERE name='before-deploy'")" "0"
  check "06 history kept after unmark" \
    "$(q "SELECT count(*)>0 FROM volvra.change_log WHERE table_name='public.orders'")" "t"

  docker rm -f "$C" >/dev/null 2>&1

  if [[ ${#problems[@]} -eq 0 ]]; then PASS+=("$v"); echo "  ✓ PASS"
  else FAIL+=("$v"); echo "  ✗ FAIL: ${problems[*]} (see $log)"; fi
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
