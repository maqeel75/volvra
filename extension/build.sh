#!/usr/bin/env bash
# Generate the extension script from the canonical install file.
#
# There is deliberately no second copy of the engine: the extension SQL is
# derived, so the two cannot drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/volvra.control")"
OUT="$ROOT/extension/volvra--${VERSION}.sql"

# The schema version is reported, not enforced: it is an internal migration
# counter and the product version is a release decision.  What matters is that
# the generated script is rebuilt from the current source every time, which is
# why the old ones are removed below.
SCHEMA_V="$(grep -oE "VALUES \(([0-9]+), '" "$ROOT/sql/volvra.sql" \
            | grep -oE '[0-9]+' | sort -n | tail -1)"

# Stale generated scripts are a trap: an old one still installs.
rm -f "$ROOT"/extension/volvra--*.sql

{
  echo "-- Generated from sql/volvra.sql by extension/build.sh -- do not edit."
  echo "-- CREATE EXTENSION already runs in a transaction and forbids"
  echo "-- transaction control, so the BEGIN/COMMIT wrapper is stripped."
  echo
  echo "\\echo Use \"CREATE EXTENSION volvra\" to load this file. \\quit"
  echo
  # Drop the transaction wrapper and any psql meta-command; keep every SQL
  # statement byte for byte.
  grep -v -e '^\\' -e 'volvra:tx' "$ROOT/sql/volvra.sql"
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines, schema v$SCHEMA_V)"

# Upgrade scripts, one per released version listed in upgrade-from.txt.
#
# The installer is a version-aware migration runner -- it reads what a database
# already has and applies only what is missing -- so an upgrade script can be
# byte-identical to the install script. It still has to exist under the right
# name, or ALTER EXTENSION UPDATE refuses with "extension has no update path"
# and an extension-installed database is stranded on the version it has.
FROM_LIST="$ROOT/extension/upgrade-from.txt"
emitted=0
if [[ -f "$FROM_LIST" ]]; then
  while read -r from; do
    from="${from%%#*}"                       # strip comments
    from="$(echo "$from" | tr -d '[:space:]')"
    [[ -z "$from" ]] && continue
    if [[ "$from" == "$VERSION" ]]; then
      echo "note: skipping $from -- a version cannot upgrade to itself" >&2
      continue
    fi
    UP="$ROOT/extension/volvra--${from}--${VERSION}.sql"
    {
      echo "-- Generated from sql/volvra.sql by extension/build.sh -- do not edit."
      echo "-- Upgrade $from -> $VERSION.  Byte-identical to the install script:"
      echo "-- the installer applies only the migrations a database is missing."
      echo
      echo "\\echo Use \"ALTER EXTENSION volvra UPDATE\" to load this file. \\quit"
      echo
      grep -v -e '^\\' -e 'volvra:tx' "$ROOT/sql/volvra.sql"
    } > "$UP"
    echo "wrote $UP"
    emitted=$(( emitted + 1 ))
  done < "$FROM_LIST"
fi

if [[ $emitted -eq 0 ]]; then
  echo "no upgrade scripts: extension/upgrade-from.txt lists no released version"
fi
