# pgVolvra and Backups

This document explains what pgVolvra recovers, what a backup recovers,
and why you need both. Confusing the two is the most consequential
misunderstanding anyone can have about this software, because the
moment it matters is the moment you have already lost something.

## pgVolvra does not replace backups

pgVolvra and a backup answer different questions. A backup answers what
the data looked like at a point in time. pgVolvra answers what changed,
when, by whom, and can that single change be reversed.

!!! important "The rule in one sentence"

    A backup restores your **data**. pgVolvra restores your **ability to
    reverse a specific change**. The companion makes sure pgVolvra's
    history is still there when you reach for it.

Restoring a backup is the blunt instrument. If someone runs a mistaken
`UPDATE` on Thursday afternoon and the most recent backup is from
Tuesday, restoring it reverses the mistake and discards two days of
legitimate work with it. pgVolvra reverts only the rows the mistake
touched.

## What each one recovers

The following table describes which tool recovers what:

| What was lost | What recovers it |
|---|---|
| Rows changed or deleted after the last backup | pgVolvra history, through volvra.undo |
| A single bad transaction among thousands of good ones | pgVolvra history, through volvra.undo_txid |
| The history itself, purged or aged out by retention | The companion archive |
| A dropped table, a dropped schema, a lost instance | Your backup |
| Schema changes, extensions, roles, anything outside covered tables | Your backup |

The first two rows are the cases pgVolvra exists for. The last two are
the cases it cannot help with, and never claims to.

## An example: a delete after the last backup

Consider an application that deletes the wrong customer's orders on
Thursday, where the most recent backup is Tuesday's. The rows are
gone, and two days of unrelated work has happened since.

Look at what the history holds for one of those rows:

```sql
SELECT change_id, ts, op, actor, old_row
FROM volvra.history('orders', '{"id": 42}');
```

The `old_row` of a `D` change is the complete row as it was, so the
data is in the history rather than merely a note that something
happened. Find the transaction that did it:

```sql
SELECT txid, ended, db_users, tables, deletes
FROM volvra.transactions()
WHERE deletes > 0
ORDER BY ended DESC
LIMIT 5;
```

See exactly what reversing it would do, changing nothing:

```sql
SELECT seq, table_name, op, inverse_op, pk, conflict
FROM volvra.preview_undo_txid(848291);
```

Then reverse it:

```sql
SELECT count(*) FROM volvra.undo_txid(848291, confirm => true);
```

The deleted rows come back. Everything else that happened on Wednesday
and Thursday stays exactly as it is, which is what restoring Tuesday's
backup could not have done.

## The two limits that decide whether pgVolvra can help

pgVolvra can only reverse what it recorded, and two settings decide
that.

The first limit is when coverage started. pgVolvra records changes from
the moment you cover a table and cannot recover a change made before
that point. A table that was not covered when the data was lost has no
history to recover from, whatever the backup situation. This is why
covering tables is the whole job rather than a detail of it.

The second limit is retention. History older than the retention policy
is dropped when `volvra.maintain` runs, by whole partition, and the
default is 90 days. Check both before an incident rather than during
one:

```sql
SELECT table_name, covered, changes, newest_change FROM volvra.status();
SELECT * FROM volvra.retention;
```

## What the companion adds

The trigger tier writes history into a table inside the same database
it protects, so that history shares the database's fate. The companion
reads a logical replication slot and writes change data to storage you
own, which breaks that shared fate.

!!! warning "The archive is not a backup either"

    The companion archives row changes to covered tables. It holds no
    schema, no extensions, and nothing outside those tables, so it
    cannot rebuild a database. What it survives is destruction of the
    **history**, not destruction of the **data**.

That distinction decides what the companion is for. It matters when
the history is destroyed while the data is fine: retention aged it
out, someone with privileges purged it, or the `volvra` schema was
dropped. In each case the archive still holds the changes, and
restoring it gives back the ability to undo.

## Recovering after losing the database

`volvra.replay` carries a restored database forward. Where
`volvra.undo` applies the inverse of each change, newest first,
`volvra.replay` applies each change again in its original direction,
oldest first. Restore an older backup, load the archived history over
it, and replay the window to reapply the work done since:

```sql
SELECT count(*)
FROM volvra.replay('orders', :backup_taken_at, now(), confirm => true);
```

!!! warning "Replay covers covered tables, and nothing else"

    A replay reapplies row changes to tables that were covered at the
    time. It is not point-in-time recovery. Schema changes, tables
    that were not covered, and anything outside the history are not
    reapplied, and a replay cannot invent a change that was never
    captured. Where the archive has a gap, the rows in that gap stay
    missing.

The guard is what makes this safe rather than merely useful. Every
statement a replay issues asserts that the row still holds the image
captured *before* that change, and a statement matching no row is a
conflict rather than a silent no-op. A replay therefore cannot
overwrite a row that has moved on, cannot apply the same change twice,
and cannot apply half a selection, because the whole plan runs in one
transaction. Preview it first, exactly as with an undo:

```sql
SELECT seq, table_name, op, pk, conflict
FROM volvra.preview_replay('orders', :backup_taken_at, now());
```

### pgVolvra and point-in-time recovery compose

The two tools are at their best together, and the order is what makes
it work. Recover the data as far forward as possible first, then use
pgVolvra to remove the one change you did not want:

1. Recover the database to the latest point you can, using
    point-in-time recovery or the most recent backup. Recover past the
    mistake rather than before it: the aim is to get every good change
    back, mistake included.
2. Install pgVolvra, if the recovered database does not already have it.
3. Load the archived history, which matters when the recovered
    database's own history is older than the changes you need to
    reverse, or was purged, or was never there:

    ```bash
    volvra-companion restore --archive /srv/archive --dsn "$DATABASE_URL"
    ```

4. Undo the mistake alone, with the conflict guard and the
    blast-radius cap applying as usual.

Recovering *past* the mistake in step 1 is the part that looks wrong
and is not. Point-in-time recovery would otherwise force a choice
between the mistake and everything that happened after it. Recovering
everything and then reversing one transaction keeps both.

### What the restored archive is good for

When the data cannot be recovered past a point, the archive is still
worth loading. It answers what the rows held before they were lost,
which is often what an incident actually needs:

```sql
SELECT change_id, ts, op, actor, old_row, new_row
FROM volvra.history('orders', '{"id": 42}');
```

That is a record to read, reconcile, and report from, not something
pgVolvra can apply for you.

## Next Steps

- The [Companion Overview](companion.md) document explains the durable
  tier, its two requirements, and how to deploy it.
- The [Managing Retention](retention.md) document describes how long
  history is kept and how to change that.
- The [Covering Tables](covering_tables.md) document explains what
  coverage means and how to keep it complete.
