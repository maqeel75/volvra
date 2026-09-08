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

# Once there is a released version to upgrade *from*, this has to emit
# volvra--<old>--<new>.sql as well.  The installer is a version-aware migration
# runner, so such a script can be byte-identical to the install script -- but it
# has to exist, or an extension-installed database has no upgrade path at all
# and ALTER EXTENSION UPDATE will refuse.  Nothing is released yet, so there is
# nothing to upgrade from.
