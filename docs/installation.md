# Installation

This document describes how to install Volvra, who needs to run the
install, and how to remove Volvra. Volvra is a single SQL file, so
installing Volvra means running that file against a database.

## Prerequisites

Volvra requires PostgreSQL 14 or later. PostgreSQL 14 is the floor
because Volvra uses the `date_bin` function, which earlier releases do
not provide.

Volvra requires no PostgreSQL extensions. Volvra uses the `plpgsql`
language, which ships enabled in every PostgreSQL installation, and
built-in functions such as `sha256` and `jsonb_populate_record`.

The durable tier has two additional requirements that the trigger tier
does not; see the [Companion Overview](companion.md) document.

## Choosing an owner

Install Volvra as a dedicated role that is not a superuser. The
`volvra.capture()` function is SECURITY DEFINER, so every captured
write briefly runs with the rights of the role that owns the function.
A superuser owner turns every insert on a covered table into
superuser-owned code.

The installing role needs the CREATE privilege on the database, and
the CREATEROLE privilege to create the three Volvra roles. Create a
suitable owner as follows:

```sql
CREATE ROLE volvra_owner LOGIN CREATEROLE PASSWORD 'use-a-real-password';
GRANT CREATE ON DATABASE app TO volvra_owner;
```

Volvra reports a superuser-owned install as a critical finding in
`volvra.preflight()`.

## Installing with psql

Run the install file against the target database:

```bash
psql "$DATABASE_URL" -f sql/volvra.sql
```

The install prints one summary line and is otherwise quiet, because the
idempotent DDL it runs would otherwise emit dozens of notices that read
as failure. Warnings and errors still appear.

Confirm the install:

```sql
SELECT volvra.version();
```

The number is the internal schema version, not a release number. There
is one schema version today; the release number is 0.1.0.

## Installing from a SQL client or console

The install file contains no `psql` meta-commands, so any client can
run the file. Managed providers that offer a browser SQL console, such
as Supabase and Neon, accept the file pasted into the console.

The file is wrapped in a single transaction. A failure part way
through leaves no objects behind, so a failed install is safe to
retry.

## Installing from a migration tool

Volvra installs cleanly as a migration. Add `sql/volvra.sql` to your
migration directory and let Flyway, Liquibase, Alembic, dbmate, or
Rails run the file in order. The install is idempotent, so a tool that
re-runs the file changes nothing.

## Installing as an extension

Volvra is not a PostgreSQL extension. The `CREATE EXTENSION` command
requires the script to be present on the database server filesystem,
which managed providers do not allow, and which is the reason Volvra
ships as plain SQL.

Self-hosted users who prefer `CREATE EXTENSION` can build optional
packaging from the same SQL file. Build and install the packaging as
follows:

```bash
cd extension
./build.sh
sudo make install
psql -c 'CREATE EXTENSION volvra'
```

The generated script comes from `sql/volvra.sql`, so the two cannot
diverge. Nothing in Volvra depends on this packaging.

## Verifying the download

Volvra installs as a file rather than a signed package, so verifying
where the file came from is the installer's responsibility. Print the
values a release publishes:

```bash
./tools/checksums.sh
```

Compare the SHA-256 of the file you have against the value published
with the release:

```bash
sha256sum -c volvra.sql.sha256
```

After installing, confirm that the code running in the database
matches the released code:

```sql
SELECT sha256 FROM volvra.fingerprint() WHERE scope = 'all';
```

The fingerprint is identical across PostgreSQL 14 through 19, so one
published value covers every supported release. See the
[Security](security.md) document for what this check does and does not
prove.

## Scope of an install

Volvra installs into one database, in a schema named `volvra`. The
three Volvra roles are cluster-wide, so a second database in the same
cluster reuses the existing roles.

## Uninstalling Volvra

Remove the triggers first, then the schema and the history:

```sql
SELECT * FROM volvra.disable_all('public');
DROP SCHEMA volvra CASCADE;
```

Dropping the schema destroys the recorded history. Archive the history
first if you need to keep it; see the
[Companion Overview](companion.md) document.

## Next Steps

- The [Getting Started](quick_start.md) document walks through a first
  undo.
- The [Configuring Volvra](configuration.md) document lists every
  setting and its default.
- The [Upgrading Volvra](upgrading.md) document describes how Volvra
  migrates an existing install.
