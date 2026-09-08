#!/usr/bin/env bash
# The companion suite runs separately from test/run.sh because it needs a
# server started with wal_level=logical, a published port, and a Go build on
# the host -- the companion is deployed outside the database, so it is tested
# that way.
#
#   ./test/run-companion.sh            # 14 15 16 17 18 19
#   ./test/run-companion.sh 17
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS=("$@")
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)

PASS=(); FAIL=()
PORT=55440
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"

for v in "${VERSIONS[@]}"; do
  log="$LOGDIR/companion-pg$v.log"
  echo "──────────────────────────────────────────────────────────────"
  echo "▶ companion on PostgreSQL $v (host port $PORT)"
  if "$ROOT/test/companion.sh" "$v" "$PORT" >"$log" 2>&1; then
    echo "  ✓ PASS  ($log)"
    PASS+=("$v")
  else
    echo "  ✗ FAIL  — last lines of $log:"
    tail -n 20 "$log" | sed 's/^/      /'
    FAIL+=("$v")
  fi
  PORT=$((PORT + 1))
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
