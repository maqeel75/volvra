#!/usr/bin/env bash
# =====================================================================
# Volvra capture-overhead benchmark
#
# Every captured write becomes that write plus a full before-and-after row
# image.  Nobody arms a production table against an unknown number, so this
# measures it: throughput with and without capture, plus bytes of history and
# WAL per change.
#
#   ./test/bench.sh              # PostgreSQL 17, 10s per run
#   ./test/bench.sh 16 20 3      # version, seconds per run, reps
#
# The script is the deliverable -- run it on YOUR hardware.  Numbers from a
# laptop container are indicative only.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
VER="${1:-17}"
SECS="${2:-10}"
REPS="${3:-2}"
CLIENTS=4
ROWS=200000

IMG="postgres:$VER"; [[ "$VER" == "19" ]] && IMG="postgres:19beta1"
C="volvra-bench-$$"

cleanup() { docker rm -f "$C" >/dev/null 2>&1; }
trap cleanup EXIT

echo "▶ $IMG · ${SECS}s x ${REPS} reps (best of) · ${CLIENTS} clients · ${ROWS} rows"
docker run -d --name "$C" -e POSTGRES_PASSWORD=b -e POSTGRES_DB=bench \
  -v "$ROOT:/volvra:ro" "$IMG" >/dev/null
volvra_wait_ready "$C" bench || { echo "server never became ready -- not a benchmark result" >&2; exit 2; }

# -i matters: without it a heredoc never reaches psql and the fixtures are
# silently never created.
p()  { docker exec -i "$C" psql -q -v ON_ERROR_STOP=1 -U postgres -d bench "$@"; }
pv() { docker exec -i "$C" psql -tA -v ON_ERROR_STOP=1 -U postgres -d bench "$@"; }

p -f /volvra/sql/volvra.sql >/dev/null 2>&1

# Each configuration must start from an identical fixture, or whichever runs
# last is penalised by the bloat and growth the earlier ones left behind.
prepare() {
  case "$1" in
    narrow)
      p >/dev/null <<SQL
DROP TABLE IF EXISTS narrow;
CREATE TABLE narrow (id int PRIMARY KEY, a int NOT NULL, b text, c numeric);
INSERT INTO narrow SELECT g, g, 'row ' || g, g * 1.5 FROM generate_series(1,$ROWS) g;
VACUUM ANALYZE narrow;
SQL
      ;;
    wide)
      p >/dev/null <<SQL
DROP TABLE IF EXISTS wide;
-- Wide enough to TOAST, which is where comparing before and after images has
-- to detoast the value to know whether it changed.
CREATE TABLE wide (id int PRIMARY KEY, a int NOT NULL, blob text);
INSERT INTO wide SELECT g, g, repeat(md5(g::text), 128) FROM generate_series(1,$ROWS) g;
VACUUM ANALYZE wide;
SQL
      ;;
    ins_target)
      p >/dev/null <<SQL
DROP TABLE IF EXISTS ins_target;
DROP SEQUENCE IF EXISTS ins_seq;
CREATE TABLE ins_target (id bigint PRIMARY KEY, a int NOT NULL, b text);
CREATE SEQUENCE ins_seq;
SQL
      ;;
  esac
}

echo "  building fixtures…"
for f in narrow wide ins_target; do prepare "$f"; done

# pgbench scripts
docker exec -i "$C" bash -c 'cat > /tmp/upd_narrow.sql' <<'SQL'
\set id random(1, 200000)
UPDATE narrow SET a = a + 1 WHERE id = :id;
SQL
docker exec -i "$C" bash -c 'cat > /tmp/upd_wide.sql' <<'SQL'
\set id random(1, 200000)
UPDATE wide SET a = a + 1 WHERE id = :id;
SQL
docker exec -i "$C" bash -c 'cat > /tmp/ins.sql' <<'SQL'
INSERT INTO ins_target (id, a, b) VALUES (nextval('ins_seq'), 1, 'inserted');
SQL
# What an ORM writes when nothing on the form changed.
docker exec -i "$C" bash -c 'cat > /tmp/noop.sql' <<'SQL'
\set id random(1, 200000)
UPDATE narrow SET a = a, b = b, c = c WHERE id = :id;
SQL

run() {   # run <script> -> tps
  docker exec "$C" pgbench -n -T "$SECS" -c "$CLIENTS" -j 2 \
    -f "/tmp/$1" -U postgres bench 2>/dev/null \
    | awk '/^tps/ {print $3; exit}'
}

# Best of N, because interference only ever costs throughput -- the fastest
# observation is the one least polluted by the host.
best() {   # best <script> <fixture> <reps> <capture:0|1>
  local script="$1" fixture="$2" reps="$3" capture="$4" b=0 t
  for _ in $(seq 1 "$reps"); do
    # prepare() recreates the table, which takes its triggers with it -- so
    # coverage has to be re-established every rep, or the capture runs measure
    # nothing at all.
    prepare "$fixture"
    [[ "$capture" == "1" ]] && p -c "SELECT volvra.enable('$fixture')" >/dev/null
    reset_history
    t=$(run "$script")
    [[ -n "$t" ]] && b=$(awk -v a="$b" -v c="$t" 'BEGIN{print (c>a? c : a)}')
  done
  printf '%s' "$b"
}

# Each psql -c is its own session, so the purge window cannot be opened in one
# call and used in the next.  Use the supported entry point instead.
reset_history() {
  p -c "SELECT sum(rows_removed) FROM volvra.purge('0 seconds'::interval)" >/dev/null
}

# Three configurations, each best-of-REPS from an identical fixture: no
# capture at all, capture storing full row images, capture storing only the
# changed columns.
measure() {   # measure <label> <script> <table>
  local label="$1" script="$2" tbl="$3"
  local off full chg pct_full pct_chg rows

  off=$(best "$script" "$tbl" "$REPS" 0)

  p -c "SELECT volvra.set_setting('capture_updates','full')" >/dev/null
  full=$(best "$script" "$tbl" "$REPS" 1)

  p -c "SELECT volvra.set_setting('capture_updates','changed')" >/dev/null
  chg=$(best "$script" "$tbl" "$REPS" 1)

  rows=$(pv -c "SELECT count(*) FROM volvra.change_log WHERE table_name='public.$tbl'")

  if [[ -z "$off" || "$off" == "0" ]]; then
    printf '%-20s  BENCHMARK FAILED (no tps reported)\n' "$label"
    return 1
  fi

  pct_full=$(awk -v a="$off" -v b="$full" 'BEGIN{printf "%.1f", (1-b/a)*100}')
  pct_chg=$(awk  -v a="$off" -v b="$chg"  'BEGIN{printf "%.1f", (1-b/a)*100}')

  printf '%-20s %9.0f %9.0f %7s%% %9.0f %7s%% %10s\n' \
    "$label" "$off" "$full" "$pct_full" "$chg" "$pct_chg" "$rows"
}

declare -a RESULTS=()
printf '\n%-20s %9s %9s %8s %9s %8s %10s\n' \
  "workload" "no capture" "full" "cost" "changed" "cost" "changes"
printf '%s\n' "--------------------------------------------------------------------------------"

measure "UPDATE narrow row"  upd_narrow.sql narrow
measure "UPDATE wide (TOAST)" upd_wide.sql   wide
measure "INSERT narrow row"  ins.sql        ins_target
measure "UPDATE, no-op"      noop.sql       narrow

# The throughput runs leave purged-but-not-vacuumed bloat behind, so bytes per
# change has to be measured on a clean table or the figure is meaningless.
echo
echo "── storage cost per captured change (clean measurement) ──"
p >/dev/null <<SQL
SELECT sum(rows_removed) FROM volvra.purge('0 seconds'::interval);
SQL
p >/dev/null <<SQL
DROP TABLE IF EXISTS store_narrow;
DROP TABLE IF EXISTS store_wide;
DROP TABLE IF EXISTS store_narrow_seed;
DROP TABLE IF EXISTS store_wide_seed;
-- Seed tables are never covered and never updated, so each mode can rebuild
-- its fixture from a pristine copy.
CREATE TABLE store_narrow_seed (id int, a int NOT NULL, b text, c numeric);
CREATE TABLE store_wide_seed   (id int, a int NOT NULL, blob text);
INSERT INTO store_narrow_seed SELECT g, g, 'row ' || g, g*1.5 FROM generate_series(1,50000) g;
INSERT INTO store_wide_seed   SELECT g, g, repeat(md5(g::text), 128) FROM generate_series(1,50000) g;
VACUUM FULL volvra.change_log;
SQL

# Both capture modes, because the documented trade-off quotes bytes per change
# for each -- measuring only the default would leave half the table unsourced.
for mode in full changed; do
  p -c "SELECT volvra.set_setting('capture_updates','$mode')" >/dev/null
  for t in store_narrow store_wide; do
    # Rebuild the fixture per mode: the first mode's updates bloat the table,
    # which would make the second mode's history-to-table ratio meaningless.
    p >/dev/null <<SQL
DROP TABLE IF EXISTS $t;
CREATE TABLE $t AS SELECT * FROM ${t}_seed;
ALTER TABLE $t ADD PRIMARY KEY (id);
VACUUM (ANALYZE, FULL) $t;
SQL
    p -c "SELECT volvra.enable('$t')" >/dev/null
    p -c "SELECT sum(rows_removed) FROM volvra.purge('0 seconds'::interval)" >/dev/null
    p -c "VACUUM FULL volvra.change_log" >/dev/null
    before=$(pv -c "SELECT volvra._total_bytes('volvra.change_log'::regclass)")
    p -c "UPDATE $t SET a = a + 1" >/dev/null
    after=$(pv -c "SELECT volvra._total_bytes('volvra.change_log'::regclass)")
    n=$(pv -c "SELECT count(*) FROM volvra.change_log WHERE table_name='public.$t'")
    tb=$(pv -c "SELECT volvra._total_bytes('public.$t'::regclass)")
    awk -v m="$mode" -v t="$t" -v b="$before" -v a="$after" -v n="$n" -v tb="$tb" 'BEGIN{
      d=a-b;
      printf "%-8s %-14s %7d changes  %8.0f bytes/change  history %6.1f MB  table %6.1f MB  ratio %.2fx\n",
        m, t, n, (n>0? d/n : 0), d/1048576, tb/1048576, (tb>0? d/tb : 0)
    }'
  done
done
p -c "SELECT volvra.set_setting('capture_updates','changed')" >/dev/null

echo
echo "── WAL generated per captured change (clean measurement) ──"
# Capture inserts are themselves WAL-logged, so replication bandwidth and
# backup size grow too.  One statement, so the figure is deterministic rather
# than a pgbench average.
for t in store_narrow store_wide; do
  prepare_wal() {
    p >/dev/null <<SQL
DROP TABLE IF EXISTS wal_$t;
CREATE TABLE wal_$t AS SELECT * FROM $t;
ALTER TABLE wal_$t ADD PRIMARY KEY (id);
VACUUM (ANALYZE) wal_$t;
CHECKPOINT;
SQL
  }

  prepare_wal
  l0=$(pv -c "SELECT pg_current_wal_lsn()")
  p -c "UPDATE wal_$t SET a = a + 1" >/dev/null
  l1=$(pv -c "SELECT pg_current_wal_lsn()")
  wal_off=$(pv -c "SELECT pg_wal_lsn_diff('$l1','$l0')::bigint")

  prepare_wal
  p -c "SELECT volvra.enable('wal_$t')" >/dev/null
  p -c "SELECT sum(rows_removed) FROM volvra.purge('0 seconds'::interval)" >/dev/null
  l0=$(pv -c "SELECT pg_current_wal_lsn()")
  p -c "UPDATE wal_$t SET a = a + 1" >/dev/null
  l1=$(pv -c "SELECT pg_current_wal_lsn()")
  wal_on=$(pv -c "SELECT pg_wal_lsn_diff('$l1','$l0')::bigint")
  n=$(pv -c "SELECT count(*) FROM volvra.change_log WHERE table_name='public.wal_$t'")
  p -c "SELECT volvra.disable('wal_$t')" >/dev/null

  awk -v t="$t" -v off="$wal_off" -v on="$wal_on" -v n="$n" 'BEGIN{
    d = on - off;
    printf "%-14s %7d changes  WAL %7.1f MB -> %7.1f MB  (+%5.1f MB, %.2fx)  %6.0f extra bytes/change\n",
      t, n, off/1048576, on/1048576, d/1048576, (off>0? on/off : 0), (n>0? d/n : 0)
  }'
done

echo
echo "── storage() as volvra reports it ──"
docker exec "$C" psql -U postgres -d bench --pset=border=2 -c "
  SELECT table_name,
         pg_size_pretty(table_bytes)   AS \"table\",
         history_rows                  AS changes,
         pg_size_pretty(history_bytes) AS history,
         ratio                         AS \"history/table\"
  FROM volvra.storage() WHERE history_rows > 0 ORDER BY history_bytes DESC"

echo "── partition layout ──"
docker exec "$C" psql -U postgres -d bench --pset=border=2 -c "
  SELECT c.relname AS partition,
         pg_size_pretty(pg_total_relation_size(c.oid)) AS size
  FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid
  WHERE i.inhparent = 'volvra.change_log'::regclass
    AND pg_total_relation_size(c.oid) > 0
  ORDER BY pg_total_relation_size(c.oid) DESC"

echo
echo "server: $(pv -c 'SHOW server_version')"
echo "note:   measured inside Docker; re-run on your own hardware before"
echo "        quoting these numbers to anyone."
