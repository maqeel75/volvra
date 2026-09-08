# Volvra

Volvra is row-level undo and history for PostgreSQL. Volvra reverts the
exact rows changed by a mistaken UPDATE, DELETE, or migration, rather
than rolling an entire cluster back to a point in time.

PostgreSQL has no equivalent of Oracle Flashback. Recovering from a
mistaken statement normally means restoring a backup or performing
point-in-time recovery, which discards every other change made since.
Volvra reverts only the rows the mistake touched, and leaves unrelated
work in place.

Volvra installs as plain SQL. Volvra requires no compiled extension,
no superuser, and no access to the database server filesystem, so
Volvra installs on managed providers such as Amazon RDS, Amazon
Aurora, Google Cloud SQL, Supabase, and Neon.

Volvra includes the following features:

- reverting an UPDATE, DELETE, or INSERT on specific rows.
- reverting an entire transaction, such as a mistaken migration,
  across every table the transaction touched.
- viewing every version of a row over time, with the actor and
  timestamp for each change.
- refusing to overwrite a change made after the mistake, rather than
  silently destroying it.
- capping the number of rows a single undo may affect.
- proving that the recorded history has not been altered.
- erasing one subject's history in response to a deletion request.
- archiving change data to storage you own, so the history survives
  the loss of the database.

## An important constraint

Volvra records changes from the moment you enable Volvra on a table.
Volvra cannot recover a change made before that point, because no
record of the change exists. Setup is therefore the whole job; see the
[Getting Started](quick_start.md) document.

## Two tiers

Volvra has two capture tiers that solve different problems. The
following table compares the two tiers:

| Property | Trigger tier | Companion |
|---|---|---|
| Mechanism | Row triggers writing to a table in the same database | External process reading a logical replication slot |
| Storage | Inside the database | Files in storage you own |
| Timing | Synchronous, in the writing transaction | Asynchronous |
| Survives loss of the database | No | Yes |
| Requires wal_level = logical | No | Yes |
| Requires REPLICA IDENTITY FULL | No | Yes |
| Recovers a TRUNCATE | Yes, in capture mode | No |
| Installs with no superuser | Yes | Yes |

The trigger tier is the everyday undo. The companion is the durable
copy. Most deployments use the trigger tier alone; add the companion
when the history must outlive the database.

## Requirements

Volvra requires PostgreSQL 14 or later. Volvra requires no PostgreSQL
extensions; the `plpgsql` language that Volvra uses ships enabled in
every PostgreSQL installation.

Volvra is tested against PostgreSQL 14, 15, 16, 17, 18, and 19.

## Next Steps

- The [Getting Started](quick_start.md) document walks through
  installing Volvra and reverting a mistake.
- The [Architecture](architecture.md) document explains how Volvra
  captures and reverts changes.
- The [Installation](installation.md) document describes every
  supported installation method.
- The [Security](security.md) document describes the privilege model
  and the guarantees Volvra does and does not provide.
