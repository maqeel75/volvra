# Architecture

This document explains how pgVolvra records changes and how pgVolvra
reverts them. Understanding the capture path helps you predict what
pgVolvra costs and what pgVolvra can recover.

## Capturing changes

The trigger tier attaches two triggers to each covered table. A
row-level AFTER trigger records every INSERT, UPDATE, and DELETE. A
statement-level BEFORE trigger handles TRUNCATE, which row triggers
never see.

Each captured change becomes one row in `volvra.change_log`. The
following table describes what pgVolvra stores for each operation:

| Operation | Stored |
|---|---|
| INSERT | The new row image. |
| UPDATE | The old and new values of the columns that changed. |
| DELETE | The complete old row image. |
| TRUNCATE | One delete image per row, in capture mode. |

pgVolvra stores row images as `jsonb`. An UPDATE stores only the columns
whose values differ, because the primary key travels in its own column
and nothing else is needed to find the row again. An UPDATE that
changed nothing records nothing at all.

Nothing leaves the database. pgVolvra adds one insert into a local
append-only table inside the transaction that made the change. pgVolvra
does not duplicate statements, open additional connections, or write
outside the database.

## Reverting changes

An undo is a plan, and the plan is ordinary SQL. pgVolvra selects the
captured changes you asked for, walks them in reverse chronological
order, and generates a compensating statement for each one.

The following table describes the compensating statement pgVolvra
generates for each captured operation:

| Captured operation | Compensating statement |
|---|---|
| INSERT | DELETE the row by primary key. |
| DELETE | INSERT the stored old row image. |
| UPDATE | UPDATE the captured columns back to their old values. |

pgVolvra applies the plan inside the caller's transaction, so the whole
undo commits or none of it does. An undo makes ordinary changes to
covered tables, so pgVolvra captures the undo as well; an undo can
therefore be undone.

## The conflict guard

Every compensating statement carries a guard that matches only if the
live row still holds the values pgVolvra captured. If someone changed
the row after the mistake, the statement affects no rows and pgVolvra
refuses the entire undo.

The guard tests only the columns the undo is about to write. If a
mistake set `total` to zero and someone later edited `note`, pgVolvra
still reverts `total`, because reverting `total` cannot destroy an
edit to `note`. A later change to `total` itself does conflict.

pgVolvra offers two outcomes for a conflict: refusing the undo, which is
the default, and skipping the conflicting rows while reverting the
rest. pgVolvra deliberately offers no option to overwrite a row that has
moved on.

## Storage layout

pgVolvra creates one schema, named `volvra`, containing the history and
its supporting objects. The following table describes the principal
tables:

| Table | Contents |
|---|---|
| change_log | Captured row images, partitioned by month. |
| enabled_tables | Covered tables, their primary keys, and per-table settings. |
| undo_log | Every undo attempt, previewed or applied. |
| seal | Hash chain proving the history has not been altered. |
| settings | Configuration values. |
| retention | Per-table retention policy. |
| retention_log | Every retention run and the row ranges removed. |
| erasure_log | Every erasure request and what it removed. |
| companion_checkpoint | Progress reported by the companion. |
| companion_gap | History the companion could not archive. |
| schema_version | Migrations applied to this database. |

The `change_log` table is range-partitioned by month, so reclaiming
old history drops a partition rather than deleting rows through the
append-only guard.

## The durable tier

The trigger tier lives inside the database and therefore shares the
fate of the database. The companion is a separate process that reads a
logical replication slot and writes change data to storage you own.

The companion decodes with `pgoutput`, the only logical decoding
plugin built into PostgreSQL. Plugins such as `wal2json` are
server-side extensions, which managed providers do not offer.

The companion writes newline-delimited JSON in numbered segments,
described by a manifest that chains the SHA-256 hash of each segment.
The archive is readable without the companion and without PostgreSQL.

## Next Steps

- The [Getting Started](quick_start.md) document walks through a first
  undo.
- The [Performance](performance.md) document gives measured throughput
  and storage costs.
- The [Security](security.md) document describes the privilege model.
