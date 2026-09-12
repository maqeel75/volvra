# Managing Retention

This document explains how pgVolvra reclaims history and how to bound
history growth. History outgrows the table it protects, so retention
is not optional.

## Why retention matters

pgVolvra stores a row image for every captured change. Measured on a
narrow table, the history reaches roughly 1.8 times the size of the
table it protects after 50,000 updates. Growth continues for as long
as the table is written.

pgVolvra deletes nothing until you run a purge. pgVolvra will not quietly
discard the history pgVolvra exists to hold, which means bounding the
growth is your decision to make and schedule.

## Setting a policy

Set a per-table retention policy with `volvra.set_retention`:

```sql
SELECT volvra.set_retention('orders', '30 days');
SELECT volvra.set_retention('audit_trail', '7 years');
```

Set the default for every table with no policy of its own:

```sql
SELECT volvra.set_setting('retention_default', '90 days');
```

Read the current policies:

```sql
SELECT table_name, keep_for, set_at, set_by FROM volvra.retention;
```

## Applying the policy

`volvra.purge` with no arguments applies the per-table policies and
the default:

```sql
SELECT table_name, keep_for, rows_removed FROM volvra.purge();
```

The function reports one row per covered table, so you can see what
each policy removed.

## Purging to a horizon

`volvra.purge` with an interval removes everything older than that
interval, whatever the per-table policies say:

```sql
SELECT action, object, rows_removed FROM volvra.purge('7 days');
```

The following table describes the actions the function reports:

| Action | Meaning |
|---|---|
| dropped partition | pgVolvra dropped a whole monthly partition that lay entirely behind the cutoff. |
| deleted rows | pgVolvra deleted individual rows from the partition straddling the cutoff, or from the default partition. |

Dropping a partition is metadata only, with no row scan and no bloat.
pgVolvra falls back to row deletion only where a partition spans the
cutoff.

## Partitions

The `change_log` table is range-partitioned by month, which is what
makes retention cheap. pgVolvra creates the current month and the next
twelve at install.

Extend the partitions on a schedule:

```sql
SELECT partition_name, status FROM volvra.ensure_partitions(12);
```

A default partition exists as a safety net. If a month is ever
missing, a capture must never fail, because a failed capture fails the
application's own write. Rows that land in the default partition
cannot be reclaimed by dropping a month, so pgVolvra reports them:

```sql
SELECT partition_name, rows_moved FROM volvra.relocate_default();
```

The function detaches the default partition, creates the months the
rows belong to, moves the rows, and recreates the default partition.

## Scheduling maintenance

Three separate jobs is three chances to forget one, and the job people
forget is sealing, which is the one that silently widens the window in
which tampering would go undetected. `volvra.maintain` does all of it
in one idempotent call:

```sql
SELECT step, detail, affected FROM volvra.maintain();
```

The function extends partitions, rescues rows from the default
partition, applies retention, seals the history, and reports any
critical findings.

Run the function hourly or daily. The interval you choose is also the
width of the window in which tampering would go undetected.

Skip parts of the job when you need to:

```sql
SELECT * FROM volvra.maintain(p_months_ahead => 24, p_seal => false);
```

## Scheduling without pg_cron

pgVolvra cannot schedule itself. If the `pg_cron` extension is
available, schedule the maintenance function with pg_cron. Otherwise
run the function from outside the database:

```bash
psql "$DATABASE_URL" -c 'SELECT * FROM volvra.maintain()'
```

`volvra.preflight` reports whether pg_cron is present, so you know
which situation applies.

## Retention and integrity

Retention removes history, and a sealed span whose rows are gone no
longer matches its seal. pgVolvra records every retention run in
`volvra.retention_log`, including the range of change identifiers
removed:

```sql
SELECT at, by_user, cutoff, scope, object, rows_removed
FROM volvra.retention_log ORDER BY id DESC;
```

`volvra.verify` reads that ledger, so a span emptied by a recorded
retention run reports as lawful rather than as tampering. See the

## Next Steps

- The [Verifying History Integrity](integrity.md) document explains
  how retention interacts with the seal chain.
- The [Monitoring](monitoring.md) document describes how to watch
  history growth.
- The [Erasing Data](erasure.md) document covers deletion requests,
  which retention cannot answer.
