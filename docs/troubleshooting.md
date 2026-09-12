# Troubleshooting

This document covers the problems pgVolvra users encounter, grouped by
area. Start with `volvra.health()` and `volvra.preflight()`, which
name most problems directly.

## Coverage problems

This section covers tables that are not recording changes.

### A table is not being recorded

Confirm whether the table is covered, and whether the trigger is
actually enabled:

```sql
SELECT table_name, covered, truncate_covered FROM volvra.status();
```

A `covered` value of false on a registered table means the trigger
exists but is disabled. Re-enable capture by covering the table again:

```sql
SELECT volvra.enable('orders');
```

A table absent from `volvra.status()` was never covered. List what has
no coverage:

```sql
SELECT table_name, reason FROM volvra.uncovered('public');
```

### pgVolvra refuses to cover a table

pgVolvra requires a primary key, because pgVolvra identifies rows by
primary key. A table with no primary key reports
`no primary key` from `volvra.uncovered`.

Add a primary key, or accept that the table cannot be covered.

### An undo says the table was never covered

pgVolvra raises `invalid_parameter_value` with the message that the
table has never been covered. No history exists for the table, which
is different from finding no changes in a window.

Coverage starts when you cover the table. Nothing before that moment
can be recovered.

## Undo problems

This section covers undos that refuse or fail.

### The undo raises serialization_failure

A row changed after the mistake, so reverting the row would destroy
that later change. List the conflicting rows:

```sql
SELECT seq, pk, conflict FROM volvra.preview_undo('orders', :t0, :t1);
```

Revert everything else and leave the changed rows alone:

```sql
SELECT * FROM volvra.undo('orders', :t0, :t1,
                          confirm => true, skip_conflicts => true);
```

pgVolvra provides no option to overwrite a changed row.

### The undo raises program_limit_exceeded

The plan affects more rows than `max_undo_rows` allows. Narrow the
selection, or raise the cap deliberately for one call:

```sql
SELECT * FROM volvra.undo('orders', :t0, :t1,
                          confirm => true, max_rows => 250000);
```

pgVolvra records the override in `volvra.undo_log`.

### The undo raises foreign_key_violation

The plan spans related tables and a constraint is not deferrable. This
happens most often after an ON DELETE CASCADE, which records the
parent before the children.

Make the constraints deferrable once, in a maintenance window:

```sql
SELECT * FROM volvra.make_fks_deferrable('public');
```

Alternatively, undo one table at a time in dependency order.

### The undo raises datatype_mismatch

The table changed shape since pgVolvra captured the rows, or a required
column is excluded from capture. The message names the columns that no
longer exist and the required columns the captured row cannot supply.

Restore the rows by hand, or narrow the window to changes captured
under the current schema.

### The undo raises a data exception about TRUNCATE

The selection contains a TRUNCATE whose rows were not captured, which
happens when `on_truncate` is set to `allow`. The rows are
unrecoverable from history.

Select either side of the truncate, or restore that data from a
backup. Set `on_truncate` to `capture` to keep future truncates
reversible.

### The undo raises insufficient_privilege

Applying an undo requires membership in `volvra_operator` and the
caller's own write privileges on the target table. pgVolvra deliberately
does not grant table privileges through the operator role.

## Privilege problems

This section covers role and permission errors.

### pgVolvra says a role is required

The message names the role, such as `volvra_admin`. Grant the role to
the user:

```sql
GRANT volvra_admin TO alice;
```

### The pgVolvra roles do not exist

The installing role lacked CREATEROLE, so pgVolvra skipped role creation
with a warning. Privilege checks are permissive in that state.

Create the roles as a role with CREATEROLE, re-run the install file,
and set `strict_roles` to `on`.

### Reading history returns permission denied

Reading a table's history requires SELECT on that table. pgVolvra
enforces the rule with row-level security and with explicit checks, so
history is never a way around a table's own grants.

### Preflight reports a superuser-owned install

The `volvra.capture` function is SECURITY DEFINER, so every captured
write briefly runs with its owner's rights. A superuser owner is a
standing privilege escalation.

Reinstall as a dedicated non-superuser owner. See the
[Installation](installation.md) document.

## Storage and partition problems

This section covers disk growth and partitioning.

### History is growing without bound

pgVolvra deletes nothing until a purge runs. Set a policy and schedule
the maintenance job:

```sql
SELECT volvra.set_retention('orders', '30 days');
SELECT * FROM volvra.maintain();
```

### Health reports rows in the default partition

A change was captured when no monthly partition covered its
timestamp. Those rows cannot be reclaimed by dropping a month.

Move the rows into real partitions, then schedule partition creation:

```sql
SELECT * FROM volvra.relocate_default();
SELECT * FROM volvra.ensure_partitions(12);
```

### Health reports no partition for next month

Partition creation has not run recently. Run the maintenance job, and
schedule the job to run at least monthly:

```sql
SELECT * FROM volvra.maintain();
```

## Integrity problems

This section covers sealing and verification.

### Verify reports TAMPERED

A sealed span no longer matches its seal, and no recorded retention or
erasure explains the difference. Treat the result as an integrity
incident.

The `kind` column distinguishes content altered in place from rows
removed or inserted. A seal proves that interference happened; a seal
cannot recover the altered history.

### Verify reports a change from erasure or retention

A recorded erasure or retention run explains the difference, so the
result is not tampering. Re-seal to restore provable coverage:

```sql
SELECT * FROM volvra.seal();
```

### Health reports that the history has never been sealed

Sealing has not run. Run the maintenance job, which includes a seal,
and schedule the job.

### The fingerprint does not match the release

The installed code differs from the published release. The difference
may be a legitimate upgrade, or a function altered after install.

Compare the per-scope hashes to narrow the difference:

```sql
SELECT scope, objects, sha256 FROM volvra.fingerprint();
```

## Companion problems

This section covers the durable tier.

### The companion cannot connect

The companion needs `wal_level` set to `logical`. Confirm the setting:

```sql
SELECT item, value, status FROM volvra.companion_status();
```

Changing `wal_level` requires a server restart. On Amazon RDS, set
`rds.logical_replication` to 1 in the parameter group and reboot.

### The companion reports no publication

Run the setup function, which builds the publication from the covered
tables:

```sql
SELECT * FROM volvra.companion_setup('public');
```

### Retained WAL is growing

A slot retains write-ahead log until the consumer catches up. Confirm
whether a companion is connected:

```sql
SELECT item, value, status FROM volvra.companion_status();
```

An inactive slot means no companion is running. Start the companion,
or drop the slot if the durable tier is no longer wanted:

```sql
SELECT pg_drop_replication_slot('volvra_companion');
```

A slot with no consumer will fill the disk and stop the server.

### The safety valve advanced the slot

Retained log passed the `--lag-max` ceiling, so the companion advanced
the slot and recorded a gap rather than letting the disk fill. Read
the gaps:

```sql
SELECT at, from_lsn, to_lsn, reason, detail FROM volvra.companion_gap;
```

The skipped range is not in the archive. Investigate why the companion
fell behind before raising the ceiling.

### Archived updates have no before image

The table lacks `REPLICA IDENTITY FULL`, so the write-ahead log
carries no before image. Confirm and correct:

```sql
SELECT * FROM volvra.companion_setup('public');
```

### Restore refuses the archive

The archive does not verify, and a restore is exactly the moment
integrity matters. Identify the problem segments:

```bash
volvra-companion verify --archive /srv/volvra-archive
```

## Still Have Questions?

For more information, visit
[docs.pgedge.com](https://docs.pgedge.com).

To report an issue with the software, visit
[the issues page](https://github.com/pgEdge/pgVolvra/issues).
