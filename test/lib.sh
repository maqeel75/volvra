# =====================================================================
# Shared helpers for the Volvra shell suites.
#
# Source this, do not execute it:
#     . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =====================================================================

# Wait until a postgres container is genuinely ready to serve queries.
#
#     volvra_wait_ready <container> <database> [timeout_seconds]
#
# pg_isready alone is not enough, and trusting it cost two CI jobs that
# reported fifteen product failures apiece when the real problem was a server
# that had not finished starting.  The official postgres image runs initdb and
# brings up a temporary server so that the init scripts can run, then shuts it
# down and starts the real one.  pg_isready answers yes during that window, so a
# client can connect, get refused a moment later, and every assertion after it
# reads as empty -- which looks exactly like the product being broken.
#
# So: wait for the entrypoint to say the init phase is over, then require a real
# query to succeed twice in a row.  Two consecutive successes rule out the gap
# between the temporary server stopping and the real one accepting.
volvra_wait_ready() {
  local c="$1" db="$2" timeout="${3:-90}"
  local deadline=$(( $(date +%s) + timeout ))
  local hits=0

  while [[ $(date +%s) -lt $deadline ]]; do
    # "ready for start up" is the entrypoint's own line, printed after initdb
    # and the init scripts, immediately before the real server starts.  A
    # container whose data directory already existed never prints it, so its
    # absence is not a failure -- only a reason to keep polling.
    if docker exec "$c" psql -qtAX -U postgres -d "$db" -c 'SELECT 1' \
         >/dev/null 2>&1; then
      hits=$(( hits + 1 ))
      [[ $hits -ge 2 ]] && return 0
    else
      hits=0
    fi
    sleep 1
  done

  # Say why, on stderr, with the server's own last words.  A suite that dies
  # here must not be mistaken for a suite that found bugs.
  {
    echo "volvra_wait_ready: $c did not accept queries on '$db' within ${timeout}s"
    echo "--- last 20 lines of container log ---"
    docker logs --tail 20 "$c" 2>&1 | sed 's/^/  /'
  } >&2
  return 1
}
