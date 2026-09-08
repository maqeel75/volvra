# Upgrading Volvra

This document describes how Volvra upgrades an existing install. The
install file is a migration runner, so upgrading Volvra is the same
command as installing Volvra.

## Running an upgrade

Run the install file again against the same database:

```bash
psql "$DATABASE_URL" -f sql/volvra.sql
```

Volvra reads the version the database already has, applies only the
migrations the database is missing, and records each one. Running the
file twice changes nothing the second time.

## The version ledger

Volvra records every applied migration in `volvra.schema_version`:

```sql
SELECT version, applied_at, applied_by, note
FROM volvra.schema_version ORDER BY version;
```

The output shows the schema versions this database has been through:

```
 version |      note
---------+----------------
       1 | initial schema
```

Read the current version with `volvra.version()`. There is one schema
version today, because Volvra has not been released yet; a released
version numbers its migrations from 2 onwards. The ledger has no gaps,
so a missing number always means a migration that did not run rather
than an install that skipped ahead.

The number is internal. Volvra reports it as the internal schema
version deliberately, so nobody reads it as a release number; the
release number is separate and lives in `extension/volvra.control`.

## Migrations are forward only

Volvra provides no down migrations. History is the product, and a
downgrade that reshaped the history table would risk destroying the
history Volvra exists to hold.

A database created during Volvra's development may hold an older
shape. The install repairs those in place, guarded on the shape of the
table rather than on a version number, and reports a warning naming
how much history it carried across. The repair copies every row into
the new table and verifies the row count before dropping the original,
so a count mismatch aborts the transaction and the original survives.

## Version numbers

Volvra maintains two separate counters. The following table describes
each counter:

| Counter | Meaning |
|---|---|
| volvra.schema_version | Internal migration counter. The counter increments whenever the on-disk shape changes. |
| Product version | A release decision, recorded in extension/volvra.control. |

The two counters are deliberately independent. Coupling the counters
would let an internal refactor look like a product release.

## Upgrading an extension install

The optional extension packaging ships only a base install script, so
a database installed with `CREATE EXTENSION` has no
`ALTER EXTENSION UPDATE` path. Upgrade such a database by running
`sql/volvra.sql` directly, which migrates the schema correctly.

## Verifying an upgrade

Confirm the version and the installed code after an upgrade:

```sql
SELECT volvra.version();
SELECT sha256 FROM volvra.fingerprint() WHERE scope = 'all';
```

Compare the fingerprint against the value published with the release.

## Next Steps

- The [Installation](installation.md) document describes every
  supported installation method.
- The [Verifying History Integrity](integrity.md) document explains
  the fingerprint and the seal chain.
