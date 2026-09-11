# FAQ

This document answers the questions Volvra users ask most often.

## Is Volvra a PostgreSQL extension?

No. Volvra is plain SQL, installed by running one file against a
database. The `CREATE EXTENSION` command requires the script to be
present on the database server filesystem, which managed providers do
not allow.

Optional extension packaging exists for self-hosted users, generated
from the same SQL file. Nothing in Volvra depends on the packaging.

## Does Volvra need pg_cron or any other extension?

No. Volvra requires no PostgreSQL extensions. Volvra uses the
`plpgsql` language, which ships enabled in every PostgreSQL
installation, and built-in functions such as `sha256`.

Volvra cannot schedule itself, so `pg_cron` is convenient where
available. Without pg_cron, run `volvra.maintain()` from outside the
database. The `volvra.preflight()` function reports which situation
applies.

## Does Volvra need a superuser?

No. Volvra installs as any role with the CREATE privilege on the
database, plus CREATEROLE to create the three Volvra roles.

Install Volvra as a dedicated non-superuser role deliberately. The
capture function is SECURITY DEFINER, so a superuser owner turns every
write on a covered table into superuser-owned code.

## Can Volvra recover a mistake made before installation?

No. Volvra records changes from the moment you cover a table. No
record exists for anything earlier, so nothing earlier can be
recovered.

This is the constraint Volvra leads with rather than hides. Setup is
the whole job.

## Does Volvra replace backups?

No. A backup restores your data; Volvra restores your ability to
reverse a specific change. You need both.

The trigger tier records row changes in a table inside the same
database, so the trigger tier shares the fate of the database. The
companion writes change data to storage you own, so the history
survives the database. Even so, the archive holds row changes rather
than a database, so schema and everything outside covered tables are
not in the archive.

The [Volvra and Backups](backups.md) document works through what each
one recovers, with an example.

## What does coverage cost?

Between 11 and 41 percent of write throughput, depending on the
operation and the row shape, and roughly 1.8 times the table size in
history for a narrow table. Write-ahead log volume roughly doubles to
trebles.

An UPDATE that changes nothing costs almost nothing, because Volvra
records nothing for it. Reads cost nothing at all. See the
[Performance](performance.md) document for measured figures.

## Should I cover every table?

No. Cost is proportional to rows changed, so cover the tables where a
wrong statement is expensive, and leave high-volume event and
telemetry tables uncovered.

A large table with few writes costs almost nothing to cover. A
high-volume append-only table is where the cost hurts most, and is
also the table you would least want to undo.

## Can an undo be undone?

Yes. An undo makes ordinary changes to covered tables, so Volvra
captures the undo as well. Find the undo in `volvra.transactions()`
and revert that transaction.

## What happens if someone changed a row after the mistake?

Volvra refuses the whole undo and raises `serialization_failure`,
rather than destroying the later change. Pass
`skip_conflicts => true` to revert everything else and leave those
rows alone.

Volvra provides no option to overwrite a row that has changed.

## Can Volvra undo a TRUNCATE?

Yes, in the default `capture` mode, which writes a delete image for
every row before allowing the truncate. Capture mode refuses tables
larger than `truncate_capture_max_rows`.

The companion cannot recover a truncate, because row-level decoding
cannot reconstruct the rows from the write-ahead log.

## Can Volvra undo a schema change?

No. Volvra records row changes, not DDL. A dropped column is not
recoverable, and a captured row that no longer fits the table produces
a `datatype_mismatch` rather than a partial restore.

## Does Volvra work with connection pooling?

Yes, with one caveat. Behind a transaction-mode pooler, such as the
default pooler on Supabase or Neon, sessions are shared between
clients.

Use `SET LOCAL volvra.actor` rather than `SET volvra.actor`, or the
value can outlive the transaction and be attributed to another
client's work. The `db_user` audit column is unaffected.

## Which PostgreSQL versions does Volvra support?

PostgreSQL 14 and later. Version 14 is the floor because Volvra uses
the `date_bin` function.

Volvra is tested against PostgreSQL 14, 15, 16, 17, 18, and 19 on
every change.

## Does Volvra work on Amazon RDS, Supabase, and Neon?

Volvra is designed for exactly those platforms, and requires nothing
they withhold.

Supabase, Neon, and pgEdge Cloud are verified, covering PostgreSQL 16,
17, and 18. The trigger tier passes on all three: Supabase on
PostgreSQL 17.6, Neon on 18.6, and pgEdge Cloud on 16.15.

The durable tier is verified end to end on both Supabase and Neon. On
each, the companion archived changes, the in-database history was
purged entirely, the archive was restored over it, and an undo driven
only by restored history put the data back. pgEdge Cloud needs the
REPLICATION attribute granted before the durable tier can run.

The other platforms have not yet been validated against a live
instance, so treat those as the design target rather than as a tested
claim. The
[Managed Providers](managed_providers.md) document records what has
been verified and how to verify the rest.

The durable tier additionally needs `wal_level` set to `logical`,
which is a parameter change on a managed provider.

## Can someone read data through the history that they cannot read directly?

No. The history holds complete row images, so Volvra enforces the
underlying table's grants twice: with row-level security on the
history table, and with an explicit check in the reading functions.

## How do I answer a deletion request?

Use `volvra.forget`, which finds every recorded change for one subject
and removes the content. Redaction is the default and keeps the change
record; hard mode deletes the rows outright, for when the primary key
is itself personal data.

Retention cannot answer a deletion request, because retention works by
time rather than by subject.

## Can I keep certain columns out of the history entirely?

Yes, with `volvra.exclude_columns`. An excluded column never reaches
the history, and an update confined to excluded columns records
nothing.

Volvra cannot restore a column Volvra never captured, so excluding a
NOT NULL column makes a DELETE on that table unrecoverable. Volvra
warns when you make the change.

## How do I know the history has not been altered?

Volvra blocks writes to the history, which makes the history tamper
resistant. Run `volvra.seal()` to make the history tamper evident, and
`volvra.verify()` to check it.

Changes captured since the last seal are not covered by any seal, so
seal on a schedule. See the
[Verifying History Integrity](integrity.md) document.

## Still Have Questions?

For more information, visit
[docs.pgedge.com](https://docs.pgedge.com).

To report an issue with the software, visit
[the issues page](https://github.com/pgEdge/volvra/issues).
