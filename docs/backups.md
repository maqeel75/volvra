# Volvra and Backups

This document explains what Volvra recovers, what a backup recovers,
and why you need both. Confusing the two is the most consequential
misunderstanding anyone can have about this software, because the
moment it matters is the moment you have already lost something.

## Volvra does not replace backups

Volvra and a backup answer different questions. A backup answers what
the data looked like at a point in time. Volvra answers what changed,
when, by whom, and can that single change be reversed.

!!! important "The rule in one sentence"

    A backup restores your **data**. Volvra restores your **ability to
    reverse a specific change**. The companion makes sure Volvra's
    history is still there when you reach for it.

Restoring a backup is the blunt instrument. If someone runs a mistaken
`UPDATE` on Thursday afternoon and the most recent backup is from
Tuesday, restoring it reverses the mistake and discards two days of
legitimate work with it. Volvra reverts only the rows the mistake
touched.

## What each one recovers

The following table describes which tool recovers what:

| What was lost | What recovers it |
|---|---|
| Rows changed or deleted after the last backup | Volvra history, through volvra.undo |
| A single bad transaction among thousands of good ones | Volvra history, through volvra.undo_txid |
| The history itself, purged or aged out by retention | The companion archive |
| A dropped table, a dropped schema, a lost instance | Your backup |
| Schema changes, extensions, roles, anything outside covered tables | Your backup |

The first two rows are the cases Volvra exists for. The last two are
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

## The two limits that decide whether Volvra can help

Volvra can only reverse what it recorded, and two settings decide
that.

The first limit is when coverage started. Volvra records changes from
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

When the database itself is gone, the order of operations matters. Do
the following, in this sequence:

1. Restore the database from your backup, by whatever means you
    normally use, such as a snapshot or point-in-time recovery.
2. Install Volvra into the restored database, if it is not already
    present.
3. Load the archived history over it:

    ```bash
    volvra-companion restore --archive /srv/archive --dsn "$DATABASE_URL"
    ```

4. Undo whatever needs undoing, in the ordinary way, with the conflict
    guard and the blast-radius cap both applying as usual.

Step 3 is what the companion buys. Without it, the restored database
knows only the history that existed when the backup was taken, and
every change after that point is invisible to an undo.

Volvra has no forward replay. The archive cannot roll a Tuesday backup
forward to Thursday's state, because that is point-in-time recovery's
job and PostgreSQL already does it through write-ahead log archiving.
What the archive restores is the record of what happened, so that
individual changes can be reversed.

## Next Steps

- The [Companion Overview](companion.md) document explains the durable
  tier, its two requirements, and how to deploy it.
- The [Managing Retention](retention.md) document describes how long
  history is kept and how to change that.
- The [Covering Tables](covering_tables.md) document explains what
  coverage means and how to keep it complete.
