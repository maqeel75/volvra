#!/usr/bin/env bash
# =====================================================================
# pgVolvra scale suite (TESTPLAN priority 7).
#
# Every other suite runs on thousands of rows, so the limits volvra
# advertises -- the blast-radius cap, seal_max_rows,
# truncate_capture_max_rows -- have never met their own thresholds.
# A limit that has never been crossed is a number in a settings table,
# not a guarantee.
#
# This is deliberately outside the matrix: it takes minutes per
# version and it measures behaviour at size, not per-version
# behaviour.  Timings are printed for information and never asserted:
# a laptop under Docker is not a benchmark, and an assertion on
# duration would fail for reasons that have nothing to do with volvra.
#
#   ./test/scale.sh              # PG 17, 1,000,000 rows
#   ./test/scale.sh 17 200000    # smaller, for a quick check
#   ./test/scale.sh 16 1000000
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
PGV="${1:-17}"
ROWS="${2:-1000000}"

image_for() { case "$1" in 19) echo "postgres:19beta1";; *) echo "postgres:$1";; esac; }
IMG="$(image_for "$PGV")"
C="volvra-scale-pg$PGV-$$"
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/scale-pg$PGV.log"; : >"$LOG"

problems=()
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; problems+=("$*"); }
note() { printf '       %s\n' "$*"; }

echo "──────────────────────────────────────────────────────────────"
echo "▶ scale on PostgreSQL $PGV ($IMG), $ROWS rows"

docker rm -f "$C" >/dev/null 2>&1
# Sizes here are for a suite that writes a million rows of history, not
# recommendations: the point is to keep the test measuring volvra rather than
# measuring an under-configured server.
docker run -d --name "$C" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=scale \
  -v "$ROOT:/volvra:ro" --shm-size=1g "$IMG" \
  -c shared_buffers=512MB -c maintenance_work_mem=256MB \
  -c max_wal_size=8GB -c checkpoint_timeout=30min >/dev/null 2>&1
if ! volvra_wait_ready "$C" scale 180; then
  echo "✗ server never became ready -- not a product failure"
  docker rm -f "$C" >/dev/null 2>&1
  exit 2
fi

q()   { docker exec "$C" psql -tA -U postgres -d scale -c "$1" 2>>"$LOG" | tr -d '[:space:]'; }
sql() { docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d scale >>"$LOG" 2>&1; }
timed() {  # timed <label> <sql>  -- prints wall time, never asserts on it
  local label="$1" stmt="$2" t0 t1
  t0=$(date +%s)
  docker exec "$C" psql -q -U postgres -d scale -c "$stmt" >>"$LOG" 2>&1
  local rc=$?
  t1=$(date +%s)
  note "$label: $((t1 - t0))s"
  return $rc
}

docker exec "$C" psql -q -U postgres -d scale -f /volvra/sql/volvra.sql >>"$LOG" 2>&1

# ---------------------------------------------------------------------
echo "--- building $ROWS rows of history ---"
sql <<SQL
CREATE TABLE big (id bigint PRIMARY KEY, v bigint, pad text);
SELECT volvra.enable('big');
SQL

T0=$(date +%s)
docker exec "$C" psql -q -U postgres -d scale \
  -c "INSERT INTO big SELECT g, g, repeat('x', 40) FROM generate_series(1, $ROWS) g" \
  >>"$LOG" 2>&1
T1=$(date +%s)
note "insert of $ROWS captured rows: $((T1 - T0))s"

CAPTURED=$(q "SELECT count(*) FROM volvra.change_log WHERE table_name='public.big' AND op='I'")
[[ "$CAPTURED" == "$ROWS" ]] \
  && ok "every one of $ROWS inserts was captured" \
  || bad "every one of $ROWS inserts was captured (got $CAPTURED)"

# ---------------------------------------------------------------------
echo "--- the blast-radius cap at scale ---"
docker exec "$C" psql -q -U postgres -d scale -c "CREATE TABLE mk AS SELECT clock_timestamp() AS at" >>"$LOG" 2>&1
sleep 0.2
T0=$(date +%s)
docker exec "$C" psql -q -U postgres -d scale -c "UPDATE big SET v = 0" >>"$LOG" 2>&1
T1=$(date +%s)
note "update of $ROWS captured rows: $((T1 - T0))s"

# The cap defaults to 10,000, so a million-row undo must be refused, and the
# refusal has to arrive without first materialising the plan.
CAP_OUT=$(docker exec "$C" psql -U postgres -d scale \
  -c "SELECT count(*) FROM volvra.undo('big', (SELECT at FROM mk), now(), confirm => true)" 2>&1)
if grep -q "exceeds cap of" <<<"$CAP_OUT"; then
  ok "an undo of $ROWS rows is refused by the cap"
  note "$(grep -o 'volvra.undo:.*' <<<"$CAP_OUT" | head -1)"
else
  bad "an undo of $ROWS rows is refused by the cap"
  printf '%s\n' "$CAP_OUT" | head -3 | sed 's/^/       | /'
fi
[[ "$(q "SELECT count(*) FROM big WHERE v = 0")" == "$ROWS" ]] \
  && ok "and the refusal changed nothing" \
  || bad "and the refusal changed nothing"

# preview must also survive the size: it materialises the whole plan.
T0=$(date +%s)
PREV=$(q "SELECT count(*) FROM volvra.preview_undo('big', (SELECT at FROM mk), now())")
T1=$(date +%s)
note "preview of $ROWS rows: $((T1 - T0))s"
[[ "$PREV" == "$ROWS" ]] \
  && ok "preview plans all $ROWS rows without a cap" \
  || bad "preview plans all $ROWS rows without a cap (got $PREV)"

# ---------------------------------------------------------------------
echo "--- a $ROWS-row undo with the cap raised deliberately ---"
T0=$(date +%s)
docker exec "$C" psql -q -U postgres -d scale \
  -c "SELECT count(*) FROM volvra.undo('big', (SELECT at FROM mk), now(), confirm => true, max_rows => $((ROWS * 2)))" \
  >>"$LOG" 2>&1
URC=$?
T1=$(date +%s)
note "undo of $ROWS rows: $((T1 - T0))s"

if [[ $URC -eq 0 ]]; then
  ok "a $ROWS-row undo completes when the cap is raised"
else
  bad "a $ROWS-row undo completes when the cap is raised (rc=$URC)"
  grep -E "ERROR" "$LOG" | tail -2 | sed 's/^/       | /'
fi
WRONG=$(q "SELECT count(*) FROM big WHERE v <> id")
[[ "$WRONG" == "0" ]] \
  && ok "and every row holds its original value again" \
  || bad "and every row holds its original value again ($WRONG wrong)"

# The undo is itself captured, so the history has roughly tripled.  This is the
# property that surprises people, so it is asserted rather than described.
TOTAL=$(q "SELECT count(*) FROM volvra.change_log")
[[ "${TOTAL:-0}" -ge $((ROWS * 3)) ]] \
  && ok "the undo was itself captured: history now holds $TOTAL changes" \
  || bad "the undo was itself captured (history holds $TOTAL, expected >= $((ROWS * 3)))"

# ---------------------------------------------------------------------
echo "--- seal() at and past seal_max_rows ---"
# Force several batches rather than one, which is the path never taken before:
# seal() walks its span row by row, and seal_max_rows is what bounds one call.
docker exec "$C" psql -q -U postgres -d scale \
  -c "SELECT volvra.set_setting('seal_max_rows', '$((ROWS / 4))')" >>"$LOG" 2>&1

T0=$(date +%s)
SEAL1=$(q "SELECT coalesce(sum(row_count), 0) FROM volvra.seal()")
T1=$(date +%s)
note "first seal (max $((ROWS / 4)) rows): $((T1 - T0))s, $SEAL1 rows"

# Batched, not refused: a backlog longer than seal_max_rows must still seal.
# Refusing was the original behaviour, and because maintain() calls seal() in
# one transaction it aborted partition maintenance and retention along with it.
[[ "${SEAL1:-0}" -gt 0 && "${SEAL1:-0}" -le $((ROWS / 4)) ]] \
  && ok "one seal() call seals a batch and stops at seal_max_rows ($SEAL1 rows)" \
  || bad "one seal() call seals a batch and stops at seal_max_rows (sealed '${SEAL1:-}', limit $((ROWS / 4)))"

# And maintain() must survive a backlog larger than the limit, because that is
# the failure that took retention down with it.
if docker exec "$C" psql -q -v ON_ERROR_STOP=1 -U postgres -d scale \
     -c "SELECT count(*) FROM volvra.maintain(1, false, true)" >>"$LOG" 2>&1; then
  ok "maintain() completes with more unsealed history than seal_max_rows"
else
  bad "maintain() completes with more unsealed history than seal_max_rows"
fi

# Repeated calls must make progress and never overlap.
for _ in 1 2 3 4 5; do
  docker exec "$C" psql -q -U postgres -d scale -c "SELECT count(*) FROM volvra.seal()" >>"$LOG" 2>&1
done
SEALED=$(q "SELECT coalesce(sum(row_count), 0) FROM volvra.seal")
SPANS=$(q "SELECT count(*) FROM volvra.seal")
[[ "${SEALED:-0}" -gt "${SEAL1:-0}" ]] \
  && ok "repeated seals make progress: $SEALED rows across $SPANS spans" \
  || bad "repeated seals make progress ($SEAL1 then $SEALED)"
[[ "$(q "SELECT count(*) FROM volvra.seal a JOIN volvra.seal b ON a.id < b.id AND a.to_id >= b.from_id AND a.from_id <= b.to_id")" == "0" ]] \
  && ok "and no two spans overlap" \
  || bad "and no two spans overlap"

T0=$(date +%s)
BAD=$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")
T1=$(date +%s)
note "verify of $SPANS spans: $((T1 - T0))s"
[[ "$BAD" == "0" ]] \
  && ok "verify() re-hashes $SEALED sealed rows and finds nothing wrong" \
  || bad "verify() re-hashes $SEALED sealed rows and finds nothing wrong ($BAD findings)"

# Tampering must still be caught at this size, or the seal proves nothing.
docker exec "$C" psql -q -U postgres -d scale -c \
  "UPDATE volvra.change_log SET actor = 'tampered' WHERE id = (SELECT min(from_id) FROM volvra.seal)" \
  >>"$LOG" 2>&1 || true
TAMPER=$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")
if [[ "${TAMPER:-0}" -gt 0 ]]; then
  ok "and a single altered row in $SEALED is still detected"
else
  # If the append-only guard refused the UPDATE, the row was never altered --
  # a stronger outcome, but it must not read as a passing tamper check.
  if grep -q "append-only\|permission denied" "$LOG"; then
    ok "the append-only guard refused to alter a sealed row at all"
  else
    bad "a single altered row in $SEALED is still detected"
  fi
fi

# ---------------------------------------------------------------------
echo "--- truncate_capture_max_rows at scale ---"
# The table holds more rows than the truncate cap, so 'capture' must refuse
# rather than quietly copy the whole table into the history.
docker exec "$C" psql -q -U postgres -d scale \
  -c "SELECT volvra.set_setting('on_truncate', 'capture')" >>"$LOG" 2>&1
TR_OUT=$(docker exec "$C" psql -U postgres -d scale -c "TRUNCATE big" 2>&1)
if grep -q "refusing to capture" <<<"$TR_OUT"; then
  ok "TRUNCATE of a $ROWS-row table is refused by truncate_capture_max_rows"
  note "$(grep -o 'volvra: refusing.*' <<<"$TR_OUT" | head -1)"
else
  bad "TRUNCATE of a $ROWS-row table is refused by truncate_capture_max_rows"
  printf '%s\n' "$TR_OUT" | head -3 | sed 's/^/       | /'
fi
[[ "$(q "SELECT count(*) FROM big")" == "$ROWS" ]] \
  && ok "and the table still has its rows" \
  || bad "and the table still has its rows"

# ---------------------------------------------------------------------
echo "--- history across many partitions, and retention dropping several ---"
# Spread history over twelve past months. ensure_partitions() only provisions
# months *ahead*, so back-dated rows would land in the DEFAULT partition and
# retention would have no partition to drop -- which is exactly what the first
# version of this check measured, and why it reported zero. Past months have to
# be created explicitly.
# `sql` rather than a bare `docker exec`: docker exec needs -i for a heredoc,
# and without it psql is handed no stdin and exits silently -- no output, no
# error, nothing in the log. This block did nothing at all for two runs, and
# the assertions after it passed anyway because they were measuring the
# partitions the install had already created.
sql <<'SQL'
DO $$
DECLARE m int;
BEGIN
  FOR m IN 1..12 LOOP
    PERFORM volvra._create_partition((date_trunc('month', now())
                                      - (m || ' months')::interval)::date);
  END LOOP;

  -- Writing change_log directly is legitimate here and nowhere else:
  -- producing a year of history by waiting is not an option.
  FOR m IN 1..12 LOOP
    INSERT INTO volvra.change_log
      (ts, table_name, op, pk, old_row, new_row, actor, db_user, txid)
    SELECT date_trunc('month', now()) - (m || ' months')::interval
             + interval '5 days',
           'public.big', 'U', jsonb_build_object('id', g),
           jsonb_build_object('v', g), jsonb_build_object('v', 0),
           'backdated', current_user, pg_current_xact_id()::text::bigint
    FROM generate_series(1, 20000) g;
  END LOOP;
END $$;
SQL

# Partitions are named change_log_yYYYYmMM, so the pattern has to allow for
# the y: 'change_log_2%' matched nothing and reported zero partitions.
#
# Count only partitions whose whole range is in the past. The install
# provisions a year ahead, so a plain count is satisfied by partitions this
# section never touched -- it passed at 13 while this section was doing
# nothing at all. Retention can only drop a partition that is entirely older
# than the cutoff, so those are the only ones that make the next check mean
# anything.
PARTS=$(q "SELECT count(*) FROM pg_class c
             JOIN pg_inherits i ON i.inhrelid = c.oid
            WHERE i.inhparent = 'volvra.change_log'::regclass
              AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE 'DEFAULT%'
              AND ((regexp_match(pg_get_expr(c.relpartbound, c.oid),
                                 'TO \(''([^'']+)''\)'))[1])::timestamptz
                  <= now() - interval '90 days'")
[[ "${PARTS:-0}" -ge 6 ]] \
  && ok "history spans $PARTS month partitions older than the cutoff" \
  || bad "history spans several month partitions older than the cutoff (got ${PARTS:-0})"

# Two assertions, not one. "No back-dated rows in the default partition" is
# true when they are correctly placed AND when they were never inserted at
# all, so on its own it is vacuous -- the same trap as asserting a size is
# >= 0. Assert they exist first.
BACKDATED=$(q "SELECT count(*) FROM volvra.change_log WHERE actor='backdated'")
[[ "${BACKDATED:-0}" == "240000" ]] \
  && ok "the back-dated history was written ($BACKDATED rows)" \
  || bad "the back-dated history was written (got '${BACKDATED:-}', expected 240000)"
INDEF=$(q "SELECT count(*) FROM volvra.change_log_default WHERE actor='backdated'")
[[ "${INDEF:-0}" == "0" ]] \
  && ok "and it is in month partitions, not the default one" \
  || bad "and it is in month partitions, not the default one ($INDEF in default)"

T0=$(date +%s)
# Capture the whole result, so a failure can say what purge actually did
# instead of only that the count was wrong.
PURGE_OUT=$(docker exec "$C" psql -U postgres -d scale \
  -c "SELECT action, object, rows_removed FROM volvra.purge('90 days'::interval)" 2>&1)
T1=$(date +%s)
printf '%s\n' "$PURGE_OUT" >>"$LOG"
DROPPED=$(grep -c "dropped partition" <<<"$PURGE_OUT")
note "purge across $PARTS partitions: $((T1 - T0))s"
if [[ "${DROPPED:-0}" -ge 2 ]]; then
  ok "retention dropped $DROPPED whole partitions rather than deleting rows"
else
  bad "retention dropped several whole partitions (dropped ${DROPPED:-0})"
  printf '%s\n' "$PURGE_OUT" | head -8 | sed 's/^/       | /'
fi
[[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict IN ('TAMPERED','CHAIN BROKEN','SEAL FORGED')")" == "0" ]] \
  && ok "and dropping partitions is not mistaken for tampering" \
  || bad "and dropping partitions is not mistaken for tampering"

# ---------------------------------------------------------------------
echo "--- the reporting functions against a large history ---"
for fn in "storage()" "activity()" "health()" "status()" "transactions()"; do
  T0=$(date +%s)
  N=$(q "SELECT count(*) FROM volvra.$fn")
  T1=$(date +%s)
  if [[ -n "$N" ]]; then
    ok "$fn returned $N row(s) in $((T1 - T0))s"
  else
    bad "$fn returned nothing against a large history"
  fi
done

# storage() must report a real size for a partitioned parent, which is the
# figure that read as ~0 before _total_bytes() learned about partitions.
BYTES=$(q "SELECT max(history_bytes) FROM volvra.storage()")
[[ "${BYTES:-0}" -gt 1000000 ]] \
  && ok "storage() reports a real size for the partitioned history ($BYTES bytes)" \
  || bad "storage() reports a real size for the partitioned history (got ${BYTES:-0})"

echo "──────────────────────────────────────────────────────────────"
docker rm -f "$C" >/dev/null 2>&1

if [[ ${#problems[@]} -eq 0 ]]; then
  echo "✓ SCALE PASSED on PostgreSQL $PGV at $ROWS rows"
  exit 0
else
  echo "✗ SCALE FAILED on PostgreSQL $PGV (${#problems[@]} problem(s), see $LOG)"
  exit 1
fi
