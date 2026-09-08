#!/usr/bin/env bash
# Verify the generated extension script actually loads via CREATE EXTENSION,
# and that the engine works afterwards.  Runs in a container so no local
# PostgreSQL install is needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:-17}"
IMG="postgres:$VER"; [[ "$VER" == "19" ]] && IMG="postgres:19beta1"
C="volvra-ext-$$"

cleanup() { docker rm -f "$C" >/dev/null 2>&1; }
trap cleanup EXIT

VERSION="$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/volvra.control")"
[[ -f "$ROOT/extension/volvra--${VERSION}.sql" ]] \
  || { echo "run extension/build.sh first"; exit 1; }

echo "▶ CREATE EXTENSION volvra on $IMG"
docker run -d --name "$C" -e POSTGRES_PASSWORD=e -e POSTGRES_DB=ext \
  -v "$ROOT:/volvra:ro" "$IMG" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$C" pg_isready -U postgres -d ext >/dev/null 2>&1 && break; sleep 1
done

SHAREDIR="$(docker exec "$C" pg_config --sharedir)"
docker exec "$C" bash -c "cp /volvra/extension/volvra.control '$SHAREDIR/extension/' && \
                          cp /volvra/extension/volvra--${VERSION}.sql '$SHAREDIR/extension/'"

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d ext <<'SQL'
CREATE EXTENSION volvra;

CREATE TABLE ext_orders (id int PRIMARY KEY, total numeric);
SELECT volvra.enable('ext_orders');
INSERT INTO ext_orders VALUES (1, 100);
SQL
rc=$?
[[ $rc -eq 0 ]] || { echo "!!! CREATE EXTENSION FAILED"; exit 1; }

docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U postgres -d ext <<'SQL'
SELECT pg_sleep(0.05);
UPDATE ext_orders SET total = 0;
DO $$
DECLARE v_n bigint;
BEGIN
  -- Scope by op rather than by time: a window wide enough to catch the update
  -- also catches the insert, and would correctly delete the row.
  SELECT count(*) INTO v_n
  FROM volvra.undo('ext_orders', predicate => $p$op = 'U'$p$, confirm => true);
  ASSERT v_n = 1, format('expected to revert 1 update, reverted %s', v_n);
  ASSERT (SELECT total FROM ext_orders WHERE id = 1) = 100,
    'undo works when installed as an extension';
  ASSERT (SELECT extversion FROM pg_extension WHERE extname = 'volvra') IS NOT NULL,
    'registered as an extension';
END $$;
SELECT 'extension ok' AS result;
SQL
rc=$?

if [[ $rc -eq 0 ]]; then
  echo "*** VOLVRA EXTENSION PACKAGING PASSED ***"
else
  echo "!!! VOLVRA EXTENSION PACKAGING FAILED"
  exit 1
fi
