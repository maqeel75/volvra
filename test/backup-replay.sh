#!/usr/bin/env bash
# =====================================================================
# Does replay actually add value after a restore?
#
# Every other test simulates the situation. This one creates it: a real
# pg_dump, a real DROP DATABASE, a real restore, and then the archive
# and volvra.replay used to carry the restored database forward over
# the work the backup predates.
#
# The assertion at the end is the only one that matters: the recovered
# database must be byte-identical to the database that was lost. Not
# close, not mostly -- identical, compared by hashing every row of
# every covered table in a stable order.
#
#   ./test/backup-replay.sh          # 14 15 16 17 18 19
#   ./test/backup-replay.sh 17
#
# Needs a Linux companion binary in VOLVRA_COMPANION_BIN.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

VERSIONS=("$@"); [[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)
image_for() { case "$1" in 19) echo "postgres:19beta1";; *) echo "postgres:$1";; esac; }

if [[ -z "${VOLVRA_COMPANION_BIN:-}" || ! -x "${VOLVRA_COMPANION_BIN}" ]]; then
  echo "VOLVRA_COMPANION_BIN must point at a linux companion binary:" >&2
  echo "  GOOS=linux go build -C companion -o /tmp/volvra-companion ." >&2
  exit 2
fi

LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
PASS=(); FAIL=()

for v in "${VERSIONS[@]}"; do
  img="$(image_for "$v")"; C="volvra-bkp-pg$v-$$"
  log="$LOGDIR/backup-replay-pg$v.log"; : >"$log"
  problems=()
  ok()  { printf '  ok   %s\n' "$*"; }
  bad() { printf '  FAIL %s\n' "$*"; problems+=("$*"); }

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ backup, loss, restore, replay on PostgreSQL $v"

  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=app \
    -v "$ROOT:/volvra:ro" "$img" -c wal_level=logical >/dev/null 2>&1
  volvra_wait_ready "$C" app || { echo "  ✗ not ready"; FAIL+=("$v"); continue; }

  q()   { docker exec "$C" psql -tA -U postgres -d app -c "$1" 2>>"$log" | tr -d '[:space:]'; }
  # q() strips every space, which is right for a count and wrong for a
  # timestamp: it turned "2026-09-11 16:43:04" into "2026-09-1116:43:04" and
  # every restored row was rejected as out of range. qv() trims the ends and
  # leaves the middle alone.
  qv()  { docker exec "$C" psql -tA -U postgres -d app -c "$1" 2>>"$log" \
            | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
  sql() { docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d app >>"$log" 2>&1; }

  docker cp "$VOLVRA_COMPANION_BIN" "$C:/volvra-companion" >>"$log" 2>&1
  docker exec "$C" chmod 0755 /volvra-companion >>"$log" 2>&1
  docker exec "$C" psql -q -U postgres -d app -f /volvra/sql/volvra.sql >>"$log" 2>&1

  # ------------------------------------------------------------------
  # A schema with the shapes that make replay hard: a foreign key, a
  # composite primary key, a generated column, and nullable columns.
  # ------------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE customers (id int PRIMARY KEY, name text NOT NULL, tier text);
CREATE TABLE orders (
  id int PRIMARY KEY,
  customer int NOT NULL REFERENCES customers(id),
  total numeric NOT NULL,
  note text,
  doubled numeric GENERATED ALWAYS AS (total * 2) STORED);
CREATE TABLE line_items (
  order_id int, line int, sku text NOT NULL, qty int,
  PRIMARY KEY (order_id, line));

SELECT volvra.enable('customers');
SELECT volvra.enable('orders');
SELECT volvra.enable('line_items');
SELECT count(*) FROM volvra.make_fks_deferrable('public');
SELECT step, object FROM volvra.companion_setup('public');

INSERT INTO customers VALUES (1,'acme','gold'), (2,'globex','bronze');
INSERT INTO orders (id, customer, total, note) VALUES (1,1,100,'first'), (2,2,250,NULL);
INSERT INTO line_items VALUES (1,1,'widget',5), (1,2,'gizmo',2), (2,1,'doohickey',1);
SQL

  # A stable hash of every covered table, used to compare states.
  state_hash() {
    q "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (
         SELECT 'c:'||id||':'||name||':'||coalesce(tier,'~') AS t FROM customers
         UNION ALL
         SELECT 'o:'||id||':'||customer||':'||total||':'||coalesce(note,'~')||':'||doubled FROM orders
         UNION ALL
         SELECT 'l:'||order_id||':'||line||':'||sku||':'||coalesce(qty::text,'~') FROM line_items
       ) s"
  }

  # PostgreSQL 18 refuses to UPDATE a table whose replica identity contains
  # generated columns the publication does not publish. companion_setup() sets
  # REPLICA IDENTITY FULL, so without publish_generated_columns the table
  # becomes unwritable -- which breaks the application, not just the archive.
  # Assert an ordinary UPDATE still works once the companion is set up.
  if docker exec "$C" psql -q -v ON_ERROR_STOP=1 -U postgres -d app \
       -c "UPDATE orders SET note = note WHERE id = 1" >>"$log" 2>&1; then
    ok "a covered table with a generated column is still updatable"
  else
    bad "a covered table with a generated column is still updatable"
    grep -A1 "cannot update table" "$log" | tail -2 | sed 's/^/       | /'
  fi

  BACKUP_STATE="$(state_hash)"
  BACKUP_AT="$(qv "SELECT clock_timestamp()")"
  [[ -n "$BACKUP_STATE" ]] && ok "baseline established" || bad "baseline established"

  # ------------------------------------------------------------------
  echo "  --- taking the backup ---"
  docker exec "$C" pg_dump -U postgres -Fc -f /tmp/app.dump app >>"$log" 2>&1 \
    && ok "pg_dump wrote a custom-format backup" \
    || bad "pg_dump wrote a custom-format backup"

  # ------------------------------------------------------------------
  echo "  --- the companion starts archiving, then a day's work happens ---"
  docker exec -d "$C" bash -c \
    "/volvra-companion run --dsn 'postgres://postgres:x@127.0.0.1:5432/app' \
       --archive /tmp/arch --slot volvra_companion --segment-bytes 8192 \
       >/tmp/comp.log 2>&1"
  sleep 4

  sql <<'SQL'
-- inserts, updates and deletes across all three tables, including a
-- foreign-key dependency created after the backup
INSERT INTO customers VALUES (3,'initech','silver');
INSERT INTO orders (id, customer, total, note) VALUES (3,3,75,'after backup');
INSERT INTO line_items VALUES (3,1,'sprocket',9);
UPDATE orders SET total = 199, note = 'revised' WHERE id = 1;
UPDATE customers SET tier = 'platinum' WHERE id = 1;
UPDATE customers SET tier = NULL WHERE id = 2;          -- set to NULL
UPDATE line_items SET qty = NULL WHERE order_id = 1 AND line = 2;
DELETE FROM line_items WHERE order_id = 1 AND line = 1;
DELETE FROM orders WHERE id = 2;
DELETE FROM customers WHERE id = 2;
SQL
  sleep 5

  FINAL_STATE="$(state_hash)"
  [[ "$FINAL_STATE" != "$BACKUP_STATE" ]] \
    && ok "the database moved on from the backup" \
    || bad "the database moved on from the backup"
  CHANGES=$(q "SELECT count(*) FROM volvra.change_log WHERE ts > '$BACKUP_AT'")
  [[ "${CHANGES:-0}" == "10" ]] \
    && ok "all 10 changes after the backup were captured" \
    || bad "all 10 changes after the backup were captured (got ${CHANGES:-0})"

  docker exec "$C" bash -c "pkill -INT -f volvra-companion" >>"$log" 2>&1
  sleep 3
  docker exec "$C" /volvra-companion verify --archive /tmp/arch >>"$log" 2>&1 \
    && ok "the archive verifies" || bad "the archive verifies"

  # ------------------------------------------------------------------
  echo "  --- the database is lost ---"
  docker exec "$C" psql -q -U postgres -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='app'" >>"$log" 2>&1
  docker exec "$C" psql -q -U postgres -d postgres -c "DROP DATABASE app" >>"$log" 2>&1
  [[ "$(docker exec "$C" psql -tA -U postgres -d postgres \
        -c "SELECT count(*) FROM pg_database WHERE datname='app'" | tr -d '[:space:]')" == "0" ]] \
    && ok "the database is gone, not merely emptied" \
    || bad "the database is gone, not merely emptied"

  echo "  --- restoring the backup ---"
  docker exec "$C" psql -q -U postgres -d postgres -c "CREATE DATABASE app" >>"$log" 2>&1
  docker exec "$C" pg_restore -U postgres -d app /tmp/app.dump >>"$log" 2>&1
  RESTORED="$(state_hash)"
  [[ "$RESTORED" == "$BACKUP_STATE" ]] \
    && ok "the restore brought back exactly the backup's state" \
    || bad "the restore brought back exactly the backup's state"
  [[ "$RESTORED" != "$FINAL_STATE" ]] \
    && ok "and that state is NOT what was lost -- a day's work is missing" \
    || bad "and that state is NOT what was lost"
  POST=$(q "SELECT count(*) FROM volvra.change_log WHERE ts > '$BACKUP_AT'")
  [[ "${POST:-0}" == "0" ]] \
    && ok "the restored history knows nothing of the work after the backup" \
    || bad "the restored history knows nothing after the backup (found $POST)"

  # ------------------------------------------------------------------
  echo "  --- the archive restores the missing history ---"
  docker exec "$C" /volvra-companion restore --archive /tmp/arch \
    --dsn "postgres://postgres:x@127.0.0.1:5432/app" >>"$log" 2>&1
  LOADED=$(q "SELECT count(*) FROM volvra.change_log WHERE ts > '$BACKUP_AT'")
  [[ "${LOADED:-0}" -ge 10 ]] \
    && ok "$LOADED archived changes are back in the history" \
    || bad "archived changes are back in the history (got ${LOADED:-0})"

  echo "  --- and replay carries the database forward ---"
  PLAN=$(q "SELECT count(*) FROM volvra.preview_replay(
              tables => ARRAY['customers','orders','line_items']::regclass[],
              from_ts => '$BACKUP_AT', to_ts => now())")
  CONF=$(q "SELECT count(*) FROM volvra.preview_replay(
              tables => ARRAY['customers','orders','line_items']::regclass[],
              from_ts => '$BACKUP_AT', to_ts => now()) WHERE conflict")
  [[ "${CONF:-1}" == "0" ]] \
    && ok "the plan of $PLAN change(s) has no conflicts against the restored state" \
    || bad "the plan has no conflicts against the restored state ($CONF of $PLAN)"

  docker exec "$C" psql -q -U postgres -d app -c \
    "SELECT count(*) FROM volvra.replay(
       tables => ARRAY['customers','orders','line_items']::regclass[],
       from_ts => '$BACKUP_AT', to_ts => now(),
       confirm => true, max_rows => 10000)" >>"$log" 2>&1
  RC=$?
  [[ $RC -eq 0 ]] && ok "replay completed" || bad "replay completed (rc=$RC)"

  # ------------------------------------------------------------------
  # The assertion this whole script exists for.
  # ------------------------------------------------------------------
  RECOVERED="$(state_hash)"
  if [[ "$RECOVERED" == "$FINAL_STATE" ]]; then
    ok "THE RECOVERED DATABASE IS IDENTICAL TO THE ONE THAT WAS LOST"
  else
    bad "THE RECOVERED DATABASE IS IDENTICAL TO THE ONE THAT WAS LOST"
    printf '       lost:      %s\n' "$FINAL_STATE"
    printf '       recovered: %s\n' "$RECOVERED"
    docker exec "$C" psql -U postgres -d app -c \
      "SELECT * FROM customers ORDER BY id" 2>&1 | sed 's/^/       /' | head -8
    docker exec "$C" psql -U postgres -d app -c \
      "SELECT id, customer, total, note FROM orders ORDER BY id" 2>&1 | sed 's/^/       /' | head -8
    docker exec "$C" psql -U postgres -d app -c \
      "SELECT * FROM line_items ORDER BY order_id, line" 2>&1 | sed 's/^/       /' | head -8
  fi

  # Replaying again must not double-apply anything.
  docker exec "$C" psql -q -U postgres -d app -c \
    "SELECT count(*) FROM volvra.replay(
       tables => ARRAY['customers','orders','line_items']::regclass[],
       from_ts => '$BACKUP_AT', to_ts => now(),
       confirm => true, max_rows => 10000)" >>"$log" 2>&1
  [[ "$(state_hash)" == "$FINAL_STATE" ]] \
    && ok "and replaying a second time changed nothing further" \
    || bad "and replaying a second time changed nothing further"

  docker rm -f "$C" >/dev/null 2>&1
  if [[ ${#problems[@]} -eq 0 ]]; then PASS+=("$v"); echo "  ✓ PASS"
  else FAIL+=("$v"); echo "  ✗ FAIL (see $log)"; fi
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
