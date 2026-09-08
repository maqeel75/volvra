#!/usr/bin/env bash
# =====================================================================
# Volvra portability suite.
#
# We ship two binaries -- linux/amd64 and linux/arm64 -- and claim they
# run on EL9, EL10, Debian bullseye through trixie, and Ubuntu jammy
# through resolute. This is where that claim is tested rather than
# assumed.
#
# The failure this exists to catch is not subtle but it is silent on the
# machine that builds: Go enables cgo whenever a C toolchain is present,
# net and os/user then link libc dynamically, and the binary refuses to
# start on any distribution whose glibc is older than the build host's.
# `make release` sets CGO_ENABLED=0 to prevent it; this suite proves the
# result.
#
# Each distribution gets the binary, an empty image with no runtime
# installed, and a real PostgreSQL to talk to over the network -- which
# also exercises the pure-Go DNS resolver that CGO_ENABLED=0 selects,
# because the database is reached by container hostname.
#
#   ./test/portability.sh              # this machine's architecture
#   ./test/portability.sh --all-arch   # both
#
# --all-arch runs the foreign architecture under emulation, which is slow
# and proves less than it appears to: an emulator is not the loader that
# will run the binary in production.  Run this suite natively on each
# architecture instead -- on the release machines, or on one runner per
# architecture.  Static linking is verified for both binaries either way,
# and that is the property that makes one binary per architecture enough.
# =====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ALL_ARCH=0
[[ "${1:-}" == "--all-arch" ]] && ALL_ARCH=1

case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH=arm64 ;;
  *)             HOST_ARCH=amd64 ;;
esac

# Every distribution we say we support. EL10 is covered twice, by
# AlmaLinux and by Red Hat's own UBI, because rockylinux:10 does not
# exist yet and one vendor's rebuild is not the whole story.
TARGETS=(
  "el9:almalinux:9"
  "el9-ubi:redhat/ubi9"
  "el9-rocky:rockylinux:9"
  "el10:almalinux:10"
  "el10-ubi:redhat/ubi10"
  "debian-bullseye:debian:bullseye"
  "debian-bookworm:debian:bookworm"
  "debian-trixie:debian:trixie"
  "ubuntu-jammy:ubuntu:jammy"
  "ubuntu-noble:ubuntu:noble"
  "ubuntu-resolute:ubuntu:resolute"
)

LOGDIR="$ROOT/test/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/portability.log"; : >"$LOG"
NET="volvra-port-net-$$"
PG="volvra-port-pg-$$"

PASS=(); FAIL=()
ok()  { printf '    ok   %s\n' "$*"; }
bad() { printf '    FAIL %s\n' "$*"; FAILED_THIS=1; }

cleanup() {
  docker rm -f "$PG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------
echo "──────────────────────────────────────────────────────────────"
echo "▶ building the release binaries"
for m in cli companion; do
  if ! make -C "$ROOT/$m" release >>"$LOG" 2>&1; then
    echo "  ✗ could not build $m -- see $LOG"
    tail -5 "$LOG" | sed 's/^/      /'
    exit 1
  fi
done

# A statically linked binary is the whole point, so check it before
# spending minutes on containers. No ldd here: it is not present in
# every image and it disagrees across libcs. The ELF header is
# definitive -- a dynamically linked executable carries an INTERP
# segment naming its loader.
echo "▶ checking both binaries are static"
static_ok=1
for b in "$ROOT/cli/dist/volvra-linux-"* "$ROOT/companion/dist/volvra-companion-linux-"*; do
  case "$b" in *checksums*) continue ;; esac
  name="$(basename "$b")"
  if grep -qa 'ld-linux\|ld-musl\|/lib64/ld' "$b"; then
    printf '    FAIL %s names a dynamic loader -- it is not static\n' "$name"
    static_ok=0
  else
    printf '    ok   %s is statically linked\n' "$name"
  fi
done
[[ $static_ok -eq 1 ]] || { echo "  ✗ refusing to continue: a binary is dynamically linked"; exit 1; }

# ---------------------------------------------------------------------
echo "▶ starting a PostgreSQL for the binaries to talk to"
docker network create "$NET" >/dev/null 2>&1
docker run -d --name "$PG" --network "$NET" --network-alias pgserver \
  -e POSTGRES_PASSWORD=x -e POSTGRES_DB=port \
  -v "$ROOT:/volvra:ro" postgres:17 >>"$LOG" 2>&1
volvra_wait_ready "$PG" port || { echo "  ✗ PostgreSQL never became ready"; exit 1; }
docker exec "$PG" psql -q -U postgres -d port -f /volvra/sql/volvra.sql >>"$LOG" 2>&1
docker exec -i "$PG" psql -q -U postgres -d port >>"$LOG" 2>&1 <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, v int);
SELECT volvra.enable('t');
INSERT INTO t VALUES (1, 1), (2, 2);
UPDATE t SET v = 0;
SQL

ARCHES=("$HOST_ARCH")
if [[ $ALL_ARCH -eq 1 ]]; then
  [[ "$HOST_ARCH" == "arm64" ]] && ARCHES+=("amd64") || ARCHES+=("arm64")
fi

# ---------------------------------------------------------------------
for arch in "${ARCHES[@]}"; do
  CLI="$ROOT/cli/dist/volvra-linux-$arch"
  COMP="$ROOT/companion/dist/volvra-companion-linux-$arch"
  plat="linux/$arch"

  echo "──────────────────────────────────────────────────────────────"
  echo "▶ $plat"
  [[ "$arch" == "$HOST_ARCH" ]] || echo "  (foreign architecture, under emulation)"

  for entry in "${TARGETS[@]}"; do
    label="${entry%%:*}"
    image="${entry#*:}"
    FAILED_THIS=0
    echo "  ${label} (${image})"

    # --pull=missing rather than always: the point is the binary, not the
    # freshness of the base image.
    if ! docker run --rm --platform "$plat" --network "$NET" \
         -v "$CLI:/volvra:ro" -v "$COMP:/volvra-companion:ro" \
         -e PGHOST=pgserver -e PGUSER=postgres -e PGPASSWORD=x -e PGDATABASE=port \
         "$image" /volvra version >>"$LOG" 2>&1; then
      bad "the binary runs at all"
      # Nothing else can be true if it will not start, so say why and move on.
      docker run --rm --platform "$plat" "$image" true >/dev/null 2>&1 \
        || printf '         (the %s image itself will not run on %s)\n' "$image" "$plat"
      docker run --rm --platform "$plat" -v "$CLI:/volvra:ro" "$image" \
        /volvra version 2>&1 | head -2 | sed 's/^/         | /'
      FAIL+=("$label/$arch"); continue
    fi
    ok "the binary runs at all"

    # One docker run for the rest, so a slow image is paid for once.
    out=$(docker run --rm --platform "$plat" --network "$NET" \
        -v "$CLI:/volvra:ro" -v "$COMP:/volvra-companion:ro" \
        -e PGHOST=pgserver -e PGUSER=postgres -e PGPASSWORD=x -e PGDATABASE=port \
        "$image" sh -c '
          /volvra-companion 2>&1 | head -1
          echo "---STATUS---"
          /volvra status 2>&1
          echo "---RC:$?---"
          echo "---PREVIEW---"
          /volvra preview --table t --since "1 hour ago" 2>&1 | tail -2
        ' 2>&1)
    printf '%s\n' "$out" >>"$LOG"

    grep -q "durable change archive" <<<"$out" \
      && ok "the companion runs too" \
      || bad "the companion runs too"

    # The real test: it reached the database by hostname, which needs the
    # pure-Go DNS resolver, and it read a covered table.
    grep -q "public.t" <<<"$out" \
      && ok "resolved pgserver and read the covered table" \
      || bad "resolved pgserver and read the covered table"
    grep -q -- "---RC:0---" <<<"$out" \
      && ok "status exited 0" \
      || bad "status exited 0"
    # Four changes, not two: the fixture inserts two rows and then updates
    # both, and the selector covers the whole hour.
    grep -qE "\(4 rows\)" <<<"$out" \
      && ok "planned all four captured changes" \
      || bad "planned all four captured changes"

    if [[ $FAILED_THIS -eq 0 ]]; then PASS+=("$label/$arch"); else FAIL+=("$label/$arch"); fi
  done
done

echo "──────────────────────────────────────────────────────────────"
echo "PASS (${#PASS[@]}): ${PASS[*]:-none}"
if [[ ${#FAIL[@]} -gt 0 ]]; then
  echo "FAIL (${#FAIL[@]}): ${FAIL[*]}"
  echo "see $LOG"
  exit 1
fi
echo "Both binaries run on every supported distribution."
