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
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"

# Find a port nothing is listening on, rather than trusting a fixed one.
# A collision here surfaces as "server never became ready", which reads as a
# product failure and is not one: it cost a PG19 run when another suite's
# container still held the port.
free_port() {
  local p
  for p in $(seq 55440 55520); do
    if ! (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then
      echo "$p"; return 0
    fi
    exec 3<&- 2>/dev/null
  done
  echo "no free port in 55440-55520" >&2
  return 1
}

for v in "${VERSIONS[@]}"; do
  PORT="$(free_port)" || exit 1
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
