#!/usr/bin/env bash
# Emit the integrity values that belong in a release, and the command a user
# runs to check them.
#
# pgVolvra installs as a SQL file, so provenance is the user's to verify -- there
# is no package manager doing it for them.  Publishing these makes that
# possible; publishing nothing makes "just run this SQL" a request for trust.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/sql/volvra.sql"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
        else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

echo "sql/volvra.sql"
echo "  bytes   : $(wc -c < "$FILE" | tr -d ' ')"
echo "  lines   : $(wc -l < "$FILE" | tr -d ' ')"
echo "  sha256  : $(sha "$FILE")"
echo
echo "Verify before installing:"
echo "  sha256sum -c volvra.sql.sha256          # or shasum -a 256 -c"
echo "  gpg --verify volvra.sql.asc volvra.sql  # once a signing key is published"
echo
echo "After installing, confirm the running code matches the release:"
echo "  SELECT sha256 FROM volvra.fingerprint() WHERE scope = 'all';"
echo
echo "The in-database fingerprint is identical across PostgreSQL 14-19, so one"
echo "published value covers every supported version."
