# Covering Tables

This document explains what coverage means, how to keep coverage
complete, and what coverage costs. A table is covered when Volvra
records its changes, so a mistake on that table can be undone.

## What coverage means

Coverage is per table. A covered table has two Volvra triggers
attached, and every change to the table becomes a row in
`volvra.change_log`. An uncovered table has no triggers, no recorded
history, and no undo.

An uncovered table costs nothing at all, because Volvra installs
nothing on the table. Coverage is therefore a deliberate choice about
which tables matter, rather than something to apply everywhere by
default.

Coverage starts when you cover the table. Volvra cannot recover a
change made before that moment, because no record of the change
exists.

## Covering a table

Cover a single table with `volvra.enable`:

```sql
SELECT volvra.enable('orders');
```

Cover every eligible table in a schema with `volvra.enable_all`:

```sql
SELECT table_name, status, detail FROM volvra.enable_all('public');
```

The function reports one row per table, including the tables the
function skipped and why. A table with no primary key is skipped
rather than failed, because Volvra identifies rows by primary key.

## Keeping coverage complete

A table created after your initial setup starts with no coverage.
`volvra.enable_all` is idempotent, so calling the function from your
migration tooling keeps new tables covered.

List the tables in a schema that have no undo:

```sql
SELECT table_name, reason FROM volvra.uncovered('public');
```

The `reason` column distinguishes a table that was never covered from
a table that cannot be covered because the table has no primary key.

Volvra deliberately does not use an event trigger to cover new tables
automatically. Creating an event trigger requires a superuser, and
installing without a superuser is central to Volvra's design.

## Checking that coverage is real

Registration and capture are different things. An owner can disable a
Volvra trigger, which leaves a table registered but silent. Read the
live state with `volvra.status`:

```sql
SELECT table_name, covered, truncate_covered, changes, newest_change
FROM volvra.status();
```

The `covered` column checks that the trigger is attached and enabled,
rather than merely that the table is registered. Volvra reports a
registered table that is not capturing as a critical finding in
`volvra.health()`, because a table that appears protected and is not
is the worst state to be in.

## Choosing which tables to cover

Coverage costs throughput and disk in proportion to the number of rows
changed, not to the size of the table. A large table with few writes
costs almost nothing to cover.

Cover the tables where a wrong statement is expensive, such as orders,
accounts, entitlements, and pricing. Leave high-volume append-only
tables, such as event and telemetry tables, uncovered; those tables
are where the cost is highest and the value of an undo is lowest.

See the [Performance](performance.md) document for measured figures.

## Excluding columns from capture

Some columns must not be copied into a second table, whatever the
recovery cost. Exclude such a column from capture:

```sql
SELECT table_name, excluded, warning
FROM volvra.exclude_columns('cards', ARRAY['pan']);
```

An excluded column never reaches the history, and an update confined
to excluded columns records nothing at all.

The cost is unavoidable. Volvra cannot restore a column Volvra never
captured, and if the column is NOT NULL with no default then undoing a
DELETE on that table becomes impossible. The function warns at that
moment, and a later undo refuses rather than inserting a row with a
wrong value.

Volvra refuses to exclude a primary key column, because the primary
key is how Volvra identifies a row.

## Stopping coverage

Stop covering a table with `volvra.disable`:

```sql
SELECT volvra.disable('orders');
```

Stop covering every table in a schema with `volvra.disable_all`:

```sql
SELECT table_name, status FROM volvra.disable_all('public');
```

Both functions keep the recorded history, so an undo of a change
captured before you stopped still works. Volvra reports a notice in
that case, because history for the table ends at the moment coverage
stopped.

## Next Steps

- The [Undoing Changes](undoing_changes.md) document describes how to
  select what to revert.
- The [Performance](performance.md) document measures what coverage
  costs.
- The [Monitoring](monitoring.md) document describes the health and
  status functions.
