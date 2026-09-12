# Getting Started

This document walks through installing pgVolvra, covering a table, and
reverting a mistake. The whole sequence takes a few minutes against
any PostgreSQL 14 or later database.

## Installing pgVolvra

pgVolvra is a single SQL file. Run the file against your database with
`psql`:

```bash
psql "$DATABASE_URL" -f sql/volvra.sql
```

The file is pure SQL wrapped in one transaction, so any client works
and a failed install leaves nothing behind. See the

## Covering a table

pgVolvra records changes only for the tables you cover. Cover every
table in a schema that has a primary key:

```sql
SELECT * FROM volvra.enable_all('public');
```

Confirm which tables now have an undo, and which do not:

```sql
SELECT table_name, covered FROM volvra.status();
SELECT table_name, reason FROM volvra.uncovered('public');
```

pgVolvra records changes from this moment on. pgVolvra cannot recover a
change made before you covered the table.

## Making a mistake

The following statement is the mistake this document recovers from;
the missing WHERE clause zeroes every row:

```sql
UPDATE orders SET total = 0;
```

## Finding the mistake

pgVolvra lists recent transactions, newest first, so you can identify
the one that caused the damage:

```sql
SELECT txid, tables, inserts, updates, deletes FROM volvra.transactions();
```

The output identifies each transaction, the tables the transaction
touched, and how many rows the transaction changed:

```
  txid  |            tables            | inserts | updates | deletes
--------+------------------------------+---------+---------+---------
 848291 | {public.orders}              |       0 |       3 |       0
```

## Previewing the undo

pgVolvra shows the compensating SQL and executes nothing:

```sql
SELECT seq, table_name, op, inverse_op, pk, conflict
FROM volvra.preview_undo_txid(848291);
```

The `conflict` column marks any row that changed after the mistake.
pgVolvra refuses to revert those rows unless you ask pgVolvra to skip
them.

## Applying the undo

Add `confirm => true` to apply the plan inside a single transaction:

```sql
SELECT * FROM volvra.undo_txid(848291, confirm => true);
```

pgVolvra captures the undo as well, so you can undo the undo by finding
its transaction in `volvra.transactions()` and reverting that.

## Viewing the history of a row

pgVolvra returns every version of a row, with the actor and timestamp
for each change:

```sql
SELECT change_id, ts, actor, db_user, op, old_row, new_row
FROM volvra.history('orders', '{"id":1}');
```

## Using the command line

The `volvra` command line tool wraps the same functions and asks for
confirmation before it changes anything:

```bash
volvra log -n 5
volvra undo --txid 848291
```

The command line refuses to apply an undo when no terminal is present
unless you pass `--yes` deliberately, so a scheduled job cannot
silently rewrite data.

## Scheduling maintenance

pgVolvra needs one recurring job, which extends partitions, applies
retention, and seals the history:

```sql
SELECT * FROM volvra.maintain();
```

Run the job hourly or daily. See the

## Checking the install before production

pgVolvra reports the configuration problems that matter before a
production deployment:

```sql
SELECT severity, finding, detail FROM volvra.preflight();
```

A superuser-owned install produces a critical finding, because the
capture function runs with its owner's rights. See the

## Next Steps

- The [Undoing Changes](undoing_changes.md) document describes every
  way to select what to revert.
- The [Covering Tables](covering_tables.md) document explains coverage
  and how to keep coverage complete.
- The [Configuring pgVolvra](configuration.md) document lists every
  setting.
- The [Performance](performance.md) document gives the measured cost
  of coverage.
