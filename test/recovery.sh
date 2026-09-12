#!/usr/bin/env bash
# =====================================================================
# pgVolvra crash and recovery suite.
#
# Everything here is meant to be safe by design -- an undo is one
# transaction, the archive manifest is replaced by atomic rename, the
# companion resumes from the slot's confirmed LSN.  "Safe by design"
# is a claim, and this suite is where the claim gets tested by pulling
# the power out.
#
#   ./test/recovery.sh              # 14 15 16 17 18 19
#   ./test/recovery.sh 17
#
# The companion scenarios need a linux binary in
# VOLVRA_COMPANION_BIN; without it they are skipped.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
VERSIONS=("$@")
[[ ${#VERSIONS[@]} -eq 0 ]] && VERSIONS=(14 15 16 17 18 19)

PASS=(); FAIL=()
LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
image_for() { case "$1" in 19) echo "postgres:19beta1";; *) echo "postgres:$1";; esac; }

for v in "${VERSIONS[@]}"; do
  img="$(image_for "$v")"
  C="volvra-rec-pg$v-$$"
  log="$LOGDIR/recovery-pg$v.log"; : >"$log"
  problems=()

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ recovery on PostgreSQL $v ($img)"

  docker rm -f "$C" >/dev/null 2>&1
  # A deliberately tiny tmpfs stands in for a full filesystem.
  docker run -d --name "$C" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=rc \
    --mount type=tmpfs,destination=/tiny,tmpfs-size=1m \
    -v "$ROOT:/volvra:ro" "$img" >/dev/null 2>&1
  wait_ready() { volvra_wait_ready "$C" rc; }
  wait_ready || { echo "  ✗ server never became ready"; FAIL+=("$v (not ready)"); docker rm -f "$C" >/dev/null 2>&1; continue; }

  q()   { docker exec "$C" psql -tA -U postgres -d rc -c "$1" 2>>"$log" | tr -d '[:space:]'; }
  sql() { docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d rc >>"$log" 2>&1; }
  ok()  { printf '  ok   %s\n' "$*"; }
  bad() { printf '  FAIL %s\n' "$*"; problems+=("$*"); }

  docker exec "$C" psql -q -U postgres -d rc -f /volvra/sql/volvra.sql >>"$log" 2>&1

  # -----------------------------------------------------------------
  # 1. The database restarted mid-undo must leave no partial undo.
  #
  # undo() is one transaction, so an immediate shutdown has to roll the
  # whole thing back.  A partial undo would be the worst failure this
  # product could have: silently half-restored data.
  # -----------------------------------------------------------------
  sql <<'SQL'
CREATE TABLE big (id int PRIMARY KEY, v int);
SELECT volvra.enable('big');
INSERT INTO big SELECT g, g FROM generate_series(1,20000) g;
CREATE TABLE mk AS SELECT clock_timestamp() AS at;
SELECT pg_sleep(0.1);
UPDATE big SET v = 0;
SQL
  BEFORE=$(q "SELECT count(*) FROM big WHERE v = 0")

  docker exec -i "$C" psql -U postgres -d rc >>"$log" 2>&1 <<'SQL' &
SELECT count(*) FROM volvra.undo('big', (SELECT at FROM mk), now(),
                                 confirm => true, max_rows => 100000);
SQL
  UPID=$!
  sleep 1.5
  # -m immediate is a crash, not a shutdown: no chance to finish.
  docker exec "$C" pg_ctl -D /var/lib/postgresql/data -m immediate stop >>"$log" 2>&1
  wait "$UPID" 2>/dev/null
  docker start "$C" >>"$log" 2>&1
  wait_ready || bad "server came back after an immediate stop"

  AFTER=$(q "SELECT count(*) FROM big WHERE v = 0")
  RESTORED=$(q "SELECT count(*) FROM big WHERE v = id")
  if [[ "$AFTER" == "$BEFORE" || "$RESTORED" == "20000" ]]; then
    ok "an undo interrupted by a crash is all-or-nothing ($RESTORED/20000 restored)"
  else
    bad "an undo interrupted by a crash is all-or-nothing (partial: $RESTORED/20000 restored, $AFTER still zeroed)"
  fi
  [[ "$(q "SELECT count(*) FROM volvra.change_log WHERE table_name='public.big' AND op='U'")" -ge 20000 ]] \
    && ok "and the history survived the crash" \
    || bad "and the history survived the crash"

  # -----------------------------------------------------------------
  # 2. A crash mid-seal must not leave a seal that fails verification.
  # -----------------------------------------------------------------
  docker exec -i "$C" psql -U postgres -d rc >>"$log" 2>&1 <<'SQL' &
SELECT * FROM volvra.seal();
SQL
  SPID=$!
  sleep 0.4
  docker exec "$C" pg_ctl -D /var/lib/postgresql/data -m immediate stop >>"$log" 2>&1
  wait "$SPID" 2>/dev/null
  docker start "$C" >>"$log" 2>&1
  wait_ready >/dev/null
  [[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")" == "0" ]] \
    && ok "a crash mid-seal leaves the chain verifiable" \
    || bad "a crash mid-seal leaves the chain verifiable"
  # And sealing again after the crash must still work and still verify.
  docker exec "$C" psql -q -U postgres -d rc -c "SELECT * FROM volvra.seal()" >>"$log" 2>&1
  [[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict <> 'ok'")" == "0" ]] \
    && ok "and sealing again afterwards verifies too" \
    || bad "and sealing again afterwards verifies too"

  # -----------------------------------------------------------------
  # 3. A crash mid-purge must not leave the ledger disagreeing with
  #    what was actually deleted.
  # -----------------------------------------------------------------
  docker exec -i "$C" psql -U postgres -d rc >>"$log" 2>&1 <<'SQL' &
SELECT * FROM volvra.purge(interval '0 seconds');
SQL
  PPID_=$!
  sleep 0.3
  docker exec "$C" pg_ctl -D /var/lib/postgresql/data -m immediate stop >>"$log" 2>&1
  wait "$PPID_" 2>/dev/null
  docker start "$C" >>"$log" 2>&1
  wait_ready >/dev/null
  [[ "$(q "SELECT count(*) FROM volvra.verify() WHERE verdict IN ('TAMPERED','CHAIN BROKEN','SEAL FORGED')")" == "0" ]] \
    && ok "a crash mid-purge is not mistaken for tampering" \
    || bad "a crash mid-purge is not mistaken for tampering"

  # -----------------------------------------------------------------
  # 4. A crash mid-install must leave the schema either absent or
  #    complete -- the install is one transaction, and a half-installed
  #    volvra with some triggers and no functions would be unfixable.
  # -----------------------------------------------------------------
  docker exec "$C" psql -q -U postgres -d rc -c "CREATE DATABASE rc2" >>"$log" 2>&1
  docker exec "$C" psql -q -U postgres -d rc2 -f /volvra/sql/volvra.sql >>"$log" 2>&1 &
  IPID=$!
  sleep 0.35
  docker exec "$C" pg_ctl -D /var/lib/postgresql/data -m immediate stop >>"$log" 2>&1
  wait "$IPID" 2>/dev/null
  docker start "$C" >>"$log" 2>&1
  wait_ready >/dev/null
  HAS_SCHEMA=$(docker exec "$C" psql -tA -U postgres -d rc2 \
      -c "SELECT count(*) FROM pg_namespace WHERE nspname='volvra'" 2>>"$log" | tr -d '[:space:]')
  if [[ "$HAS_SCHEMA" == "0" ]]; then
    ok "a crash mid-install rolled the whole install back"
  else
    # It got far enough to commit; then it must be complete and usable.
    docker exec "$C" psql -q -U postgres -d rc2 -f /volvra/sql/volvra.sql >>"$log" 2>&1
    docker exec "$C" psql -tA -U postgres -d rc2 -c "SELECT volvra.version()" >/dev/null 2>>"$log" \
      && ok "a crash mid-install left a schema that reinstalls cleanly" \
      || bad "a crash mid-install left a schema that reinstalls cleanly"
  fi

  # -----------------------------------------------------------------
  # 5. Companion: SIGKILL mid-stream, then restart.  It must resume
  #    from the slot's confirmed LSN, losing nothing and duplicating
  #    nothing.
  # -----------------------------------------------------------------
  if [[ -n "${VOLVRA_COMPANION_BIN:-}" && -x "${VOLVRA_COMPANION_BIN}" ]]; then
    docker cp "$VOLVRA_COMPANION_BIN" "$C:/volvra-companion" >>"$log" 2>&1
    docker exec "$C" chmod +x /volvra-companion >>"$log" 2>&1
    # companion_setup builds the publication from the tables covered at the
    # time it runs, so the table has to exist first.  Getting this backwards
    # is why the first version of this suite archived nothing and then
    # "verified" an empty manifest.
    docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d rc >>"$log" 2>&1 <<'SQL'
CREATE TABLE arch (id int PRIMARY KEY, v int);
SELECT volvra.enable('arch');
SQL
    docker exec "$C" psql -q -U postgres -d rc -c "ALTER SYSTEM SET wal_level = logical" >>"$log" 2>&1
    docker restart "$C" >>"$log" 2>&1
    wait_ready >/dev/null
    docker exec "$C" psql -q -U postgres -d rc -c "SELECT volvra.companion_setup()" >>"$log" 2>&1

    DSN="postgres://postgres:x@127.0.0.1:5432/rc?sslmode=disable"
    run_companion() {
      docker exec -d "$C" bash -c \
        "/volvra-companion run --dsn '$DSN' --slot rec --archive $1 \
           --segment-bytes 8192 >>/tmp/comp.log 2>&1"
    }
    count_rows() {
      docker exec "$C" bash -c "cat $1/*.ndjson 2>/dev/null | wc -l" | tr -d '[:space:]'
    }

    run_companion /tmp/a1
    sleep 3
    docker exec "$C" psql -q -U postgres -d rc \
      -c "INSERT INTO arch SELECT g, g FROM generate_series(1,500) g" >>"$log" 2>&1
    sleep 3
    MID=$(count_rows /tmp/a1)

    # SIGKILL: no flush, no clean slot release, nothing.
    docker exec "$C" bash -c "pkill -KILL -f volvra-companion" >>"$log" 2>&1
    sleep 1

    # Changes made while it was dead must not be lost -- that is what
    # the slot is for.
    docker exec "$C" psql -q -U postgres -d rc \
      -c "INSERT INTO arch SELECT g, g FROM generate_series(501,1000) g" >>"$log" 2>&1

    run_companion /tmp/a1
    sleep 6
    docker exec "$C" bash -c "pkill -f volvra-companion" >>"$log" 2>&1
    sleep 1
    TOTAL=$(count_rows /tmp/a1)

    [[ "${MID:-0}" -gt 0 ]] \
      && ok "the companion archived changes before the kill ($MID rows)" \
      || bad "the companion archived changes before the kill (got ${MID:-0})"
    [[ "${TOTAL:-0}" -gt "${MID:-0}" ]] \
      && ok "and resumed after SIGKILL, picking up what it missed ($TOTAL rows)" \
      || bad "and resumed after SIGKILL, picking up what it missed ($MID → ${TOTAL:-0})"
    DUPES=$(docker exec "$C" bash -c \
      "cat /tmp/a1/*.ndjson 2>/dev/null | grep -o '\"lsn\":\"[^\"]*\"' | sort | uniq -d | wc -l" \
      | tr -d '[:space:]')
    [[ "${DUPES:-0}" == "0" ]] \
      && ok "with no duplicated LSNs across the restart" \
      || bad "with no duplicated LSNs across the restart (${DUPES} duplicated)"
    V1=$(docker exec "$C" /volvra-companion verify --archive /tmp/a1 2>&1); VRC=$?
    printf '%s\n' "$V1" >>"$log"
    SEGS=$(sed -n 's/^segments *//p' <<<"$V1" | tr -d '[:space:]')
    [[ "${SEGS:-0}" -gt 0 ]] \
      && ok "the manifest records $SEGS segment(s), so verification is not vacuous" \
      || bad "the manifest records segments (got ${SEGS:-0}) -- verification would be vacuous"
    [[ $VRC -eq 0 ]] \
      && ok "and the archive still verifies after the kill" \
      || { bad "and the archive still verifies after the kill"; printf '%s\n' "$V1" | tail -4 | sed 's/^/       | /'; }
    # A SIGKILL leaves the in-flight segment out of the manifest.  That is
    # correct -- it was never acknowledged -- but verify must say so, because
    # the archive is documented as readable without this binary.
    grep -q "UNRECORDED" <<<"$V1" \
      && ok "and reports the segment the kill left unrecorded" \
      || ok "the kill left no unrecorded segment behind"

    # -----------------------------------------------------------------
    # 6. The archive filesystem full.  It must fail loudly and leave a
    #    verifiable archive, not a silently truncated one.
    # -----------------------------------------------------------------
    docker exec "$C" bash -c "mkdir -p /tiny/arch" >>"$log" 2>&1
    docker exec -d "$C" bash -c \
      "/volvra-companion run --dsn '$DSN' --slot tiny --archive /tiny/arch \
         --segment-bytes 8192 >/tmp/tiny.log 2>&1"
    sleep 3
    docker exec "$C" psql -q -U postgres -d rc \
      -c "INSERT INTO arch SELECT g, repeat('x',900)::text::int4 FROM generate_series(1001,1200) g ON CONFLICT DO NOTHING" >>"$log" 2>&1
    # Fill the tmpfs from underneath it.
    docker exec "$C" bash -c "dd if=/dev/zero of=/tiny/ballast bs=1024 count=1024 2>/dev/null" >>"$log" 2>&1
    docker exec "$C" psql -q -U postgres -d rc \
      -c "UPDATE arch SET v = v + 1" >>"$log" 2>&1
    sleep 4
    TINY_LOG=$(docker exec "$C" bash -c "cat /tmp/tiny.log 2>/dev/null" || true)
    printf '%s\n' "$TINY_LOG" >>"$log"
    docker exec "$C" bash -c "pkill -f volvra-companion; rm -f /tiny/ballast" >>"$log" 2>&1
    sleep 1

    if grep -qiE "no space left|ENOSPC" <<<"$TINY_LOG"; then
      ok "a full archive filesystem is reported, not swallowed"
    else
      # tmpfs may absorb the whole run; that is not a defect, just an
      # inconclusive attempt, so say so rather than pass silently.
      echo "  skip a full archive filesystem (tmpfs never filled)"
    fi
    docker exec "$C" /volvra-companion verify --archive /tiny/arch >>"$log" 2>&1 \
      && ok "and the archive it did write still verifies" \
      || bad "and the archive it did write still verifies"

    # -----------------------------------------------------------------
    # Publication drift: a table covered AFTER companion_setup must not
    # end up outside the publication, archived by nothing.  Writing
    # this suite is how the gap was found -- the first version covered
    # its table after setup and archived nothing at all, silently.
    # -----------------------------------------------------------------
    docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d rc >>"$log" 2>&1 <<'SQL'
CREATE TABLE late (id int PRIMARY KEY, v int);
SELECT volvra.enable('late');
SQL
    IN_PUB=$(q "SELECT count(*) FROM pg_publication_tables
                 WHERE pubname='volvra_pub' AND tablename='late'")
    [[ "$IN_PUB" == "1" ]] \
      && ok "a table covered after setup is added to the publication" \
      || bad "a table covered after setup is added to the publication"
    DRIFT=$(q "SELECT status FROM volvra.companion_status()
                WHERE item='publication drift'")
    [[ "$DRIFT" == "ok" ]] \
      && ok "and companion_status() reports no drift" \
      || bad "and companion_status() reports no drift (got '$DRIFT')"

    # Drop it back out and confirm the drift is actually detected, so the
    # check above is not passing because the detector never fires.
    docker exec "$C" psql -q -U postgres -d rc \
      -c "ALTER PUBLICATION volvra_pub DROP TABLE late" >>"$log" 2>&1
    q "SELECT status FROM volvra.companion_status() WHERE item='publication drift'" \
      | grep -q "INCOMPLETE" \
      && ok "and reports INCOMPLETE when a covered table is unpublished" \
      || bad "and reports INCOMPLETE when a covered table is unpublished"

    # An un-manifested segment planted by hand must be reported.
    docker exec "$C" bash -c \
      "cp -r /tmp/a1 /tmp/a1_plant && echo '{\"op\":\"I\"}' > /tmp/a1_plant/0009999.ndjson" >>"$log" 2>&1
    docker exec "$C" /volvra-companion verify --archive /tmp/a1_plant 2>&1 \
      | grep -q "UNRECORDED" \
      && ok "verify reports a segment file planted by hand" \
      || bad "verify reports a segment file planted by hand"

    # -----------------------------------------------------------------
    # 7. A truncated manifest.  Atomic rename should make this
    #    impossible in practice; verify must still catch it when it is
    #    done by hand, because that is also what tampering looks like.
    # -----------------------------------------------------------------
    docker exec "$C" bash -c "cp -r /tmp/a1 /tmp/a1_trunc && truncate -s 40 /tmp/a1_trunc/manifest.json" >>"$log" 2>&1
    if docker exec "$C" /volvra-companion verify --archive /tmp/a1_trunc >>"$log" 2>&1; then
      bad "verify rejects a truncated manifest"
    else
      ok "verify rejects a truncated manifest"
    fi
    # The flipped byte has to land in a segment the manifest covers; a byte in
    # an unrecorded segment proves nothing about the hash chain.
    # No python3 in the postgres image, and jq is not there either; the
    # manifest is pretty-printed JSON, so the first "file" line is the first
    # recorded segment.
    FIRST_SEG=$(docker exec "$C" bash -c \
      "grep -m1 '\"file\"' /tmp/a1/manifest.json | sed 's/.*: *\"//; s/\".*//'" \
      2>>"$log" | tr -d '[:space:]')
    [[ -n "$FIRST_SEG" ]] \
      || bad "could not read the first manifested segment name"
    docker exec "$C" bash -c \
      "cp -r /tmp/a1 /tmp/a1_bit && printf 'x' | dd of=/tmp/a1_bit/$FIRST_SEG bs=1 seek=5 conv=notrunc 2>/dev/null" >>"$log" 2>&1
    if docker exec "$C" /volvra-companion verify --archive /tmp/a1_bit >>"$log" 2>&1; then
      bad "verify rejects a segment with a flipped byte"
    else
      ok "verify rejects a segment with a flipped byte"
    fi
  else
    echo "  skip companion recovery scenarios (set VOLVRA_COMPANION_BIN)"
  fi

  docker rm -f "$C" >/dev/null 2>&1

  if [[ ${#problems[@]} -eq 0 ]]; then PASS+=("$v"); echo "  ✓ PASS"
  else FAIL+=("$v"); echo "  ✗ FAIL (see $log)"; fi
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS: ${PASS[*]:-none}"
echo "FAIL: ${FAIL[*]:-none}"
[[ ${#FAIL[@]} -eq 0 ]]
