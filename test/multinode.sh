#!/usr/bin/env bash
# =====================================================================
# Volvra on a multi-master cluster.
#
# Builds a real two-node Spock cluster from the pgEdge image and asks
# the only question that matters there: does a node hold history of
# changes its peers made?
#
# With ordinary triggers it does not, because PostgreSQL does not fire
# them for rows applied by replication. That is correct on one node and
# silently wrong on a cluster, which is why capture_replicated exists.
# This suite measures both settings rather than asserting either.
#
#   ./test/multinode.sh
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

IMG="${VOLVRA_PGEDGE_IMAGE:-pgedge/pgedge:latest}"
NET="volvra-spock-$$"
N1="volvra-sp1-$$"; N2="volvra-sp2-$$"
DB=pgedge_init; U=pgedge_init; PW=U2D2GY7F
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/multinode.log"; : >"$LOG"

problems=()
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; problems+=("$*"); }
note(){ printf '       %s\n' "$*"; }

cleanup() {
  docker rm -f "$N1" "$N2" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

# n1 and n2 run psql as the pgEdge init user.
# SQL goes in on stdin, never through `bash -lc "... -c \"$1\""`. That form
# expands the string a second time inside the container, so a dollar-quoted
# literal such as an op filter became the shell's process id.
q1() { printf '%s\n' "$1" | docker exec -i "$N1" psql -U "$U" -d "$DB" -tA 2>>"$LOG" | tr -d '[:space:]'; }
q2() { printf '%s\n' "$1" | docker exec -i "$N2" psql -U "$U" -d "$DB" -tA 2>>"$LOG" | tr -d '[:space:]'; }
x1() { printf '%s\n' "$1" | docker exec -i "$N1" psql -U "$U" -d "$DB" -q >>"$LOG" 2>&1; }
x2() { printf '%s\n' "$1" | docker exec -i "$N2" psql -U "$U" -d "$DB" -q >>"$LOG" 2>&1; }

echo "──────────────────────────────────────────────────────────────"
echo "▶ two-node Spock cluster ($IMG)"

docker network create "$NET" >/dev/null 2>&1
for n in "$N1" "$N2"; do
  docker run -d --name "$n" --network "$NET" -v "$ROOT:/volvra:ro" "$IMG" >/dev/null 2>&1
done

ready=0
for _ in $(seq 1 90); do
  if docker exec "$N1" psql -U "$U" -d "$DB" -tAc 'SELECT 1' >/dev/null 2>&1 \
  && docker exec "$N2" psql -U "$U" -d "$DB" -tAc 'SELECT 1' >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 2
done
[[ $ready -eq 1 ]] || { echo "  ✗ nodes never became ready"; exit 1; }

PGV="$(q1 "SHOW server_version")"
note "server $PGV, spock $(q1 "SELECT extversion FROM pg_extension WHERE extname='spock'")"

# ------------------------------------------------------------------
# Spock: n1 publishes, n2 subscribes. Structure sync is off because the
# table is created on both sides; leaving it on fails the subscription
# during its non-recoverable init step.
# ------------------------------------------------------------------
x1 "CREATE EXTENSION IF NOT EXISTS spock"
x2 "CREATE EXTENSION IF NOT EXISTS spock"
x1 "SELECT spock.node_create('n1','host=$N1 port=5432 dbname=$DB user=$U password=$PW')"
x2 "SELECT spock.node_create('n2','host=$N2 port=5432 dbname=$DB user=$U password=$PW')"
x1 "CREATE TABLE t (id int PRIMARY KEY, v int)"
x2 "CREATE TABLE t (id int PRIMARY KEY, v int)"
x1 "SELECT spock.repset_add_table('default','t')"

docker exec "$N2" psql -U "$U" -d "$DB" -q -f /volvra/sql/volvra.sql >>"$LOG" 2>&1
x2 "SELECT volvra.enable('t')"
x2 "SELECT spock.sub_create('s','host=$N1 port=5432 dbname=$DB user=$U password=$PW', ARRAY['default'], false, false)"

up=0
for _ in $(seq 1 30); do
  [[ "$(q2 "SELECT status FROM spock.sub_show_status()")" == "replicating" ]] && { up=1; break; }
  sleep 2
done
[[ $up -eq 1 ]] && ok "the subscription is replicating" \
                || { bad "the subscription is replicating"; docker logs "$N2" 2>&1 | tail -5 | sed 's/^/       | /'; }

# ------------------------------------------------------------------
echo "  --- capture_replicated = off, the default ---"
# ------------------------------------------------------------------
[[ "$(q2 "SELECT volvra.get_setting('capture_replicated')")" == "off" ]] \
  && ok "off is the default, so single-node behaviour is unchanged" \
  || bad "off is the default"

x1 "INSERT INTO t VALUES (1,10)"
sleep 6
[[ "$(q2 "SELECT count(*) FROM t")" == "1" ]] \
  && ok "the write replicated to the other node" \
  || bad "the write replicated to the other node"
CAP="$(q2 "SELECT count(*) FROM volvra.change_log WHERE table_name='public.t'")"
[[ "${CAP:-x}" == "0" ]] \
  && ok "and an ordinary trigger captured none of it, as PostgreSQL specifies" \
  || bad "an ordinary trigger captured none of it (got $CAP)"

\
# preflight must say so rather than leave it to be discovered later.
q2 "SELECT count(*) FROM volvra.preflight() WHERE finding LIKE '%receives replicated changes%'" \
  | grep -q '^1$' \
  && ok "preflight warns that replicated changes are not being captured" \
  || bad "preflight warns that replicated changes are not being captured"

# ------------------------------------------------------------------
echo "  --- capture_replicated = on ---"
# ------------------------------------------------------------------
x2 "SELECT count(*) FROM volvra.set_capture_replicated('on')"
[[ "$(q2 "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='t'::regclass AND tgname='volvra_capture'")" == "A" ]] \
  && ok "the capture trigger is now ENABLE ALWAYS" \
  || bad "the capture trigger is now ENABLE ALWAYS"

x1 "INSERT INTO t VALUES (2,20)"
x1 "UPDATE t SET v = 99 WHERE id = 2"
x1 "DELETE FROM t WHERE id = 1"
sleep 8

OPS="$(q2 "SELECT string_agg(op, '' ORDER BY id) FROM volvra.change_log WHERE table_name='public.t'")"
[[ "$OPS" == "IUD" ]] \
  && ok "every replicated operation is captured, in order: $OPS" \
  || bad "every replicated operation is captured, in order (got '$OPS')"

IMG_OK="$(q2 "SELECT count(*) FROM volvra.change_log
               WHERE table_name='public.t' AND op='U'
                 AND old_row->>'v' = '20' AND new_row->>'v' = '99'")"
[[ "$IMG_OK" == "1" ]] \
  && ok "with both images intact, so the history is usable for an undo" \
  || bad "with both images intact (got $IMG_OK)"

q2 "SELECT count(*) FROM volvra.preflight() WHERE finding LIKE '%receives replicated changes%'" \
  | grep -q '^0$' \
  && ok "and preflight stops warning" \
  || bad "and preflight stops warning"

# ------------------------------------------------------------------
echo "  --- an undo on the subscriber, driven by a peer's history ---"
# ------------------------------------------------------------------
# This is the point of the whole feature: n2 never wrote these rows, but
# it holds their history and can reverse them.
x2 "SELECT count(*) FROM volvra.undo('t', predicate => 'op = ''U''', confirm => true)"
V="$(q2 "SELECT v FROM t WHERE id = 2")"
[[ "$V" == "20" ]] \
  && ok "a node reverted a change it never made, using replicated history" \
  || bad "a node reverted a change it never made (v=$V)"

# ------------------------------------------------------------------
echo "  --- volvra's own tables must never replicate ---"
# ------------------------------------------------------------------
REPL="$(q2 "SELECT count(*) FROM spock.tables WHERE nspname = 'volvra' AND set_name IS NOT NULL")"
[[ "${REPL:-1}" == "0" ]] \
  && ok "no volvra table is in a replication set" \
  || bad "a volvra table is in a replication set ($REPL)"

echo "──────────────────────────────────────────────────────────────"
if [[ ${#problems[@]} -eq 0 ]]; then
  echo "✓ MULTI-NODE PASSED on $PGV"
  exit 0
fi
echo "✗ MULTI-NODE FAILED (${#problems[@]} problem(s), see $LOG)"
exit 1
