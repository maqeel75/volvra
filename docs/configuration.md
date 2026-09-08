# Configuring Volvra

This document lists every Volvra setting, its default, and what the
setting controls. Settings live in the `volvra.settings` table and
apply to the whole install.

## Reading and changing settings

Read a single setting with `volvra.get_setting`:

```sql
SELECT volvra.get_setting('max_undo_rows');
```

Change a setting with `volvra.set_setting`, which requires membership
in `volvra_admin`:

```sql
SELECT volvra.set_setting('max_undo_rows', '50000');
```

List every setting and its current value:

```sql
SELECT key, value FROM volvra.settings ORDER BY key;
```

## Undo settings

The following table describes the settings that control what an undo
may do:

| Setting | Default | Description |
|---|---|---|
| max_undo_rows | 10000 | Maximum rows a single undo may affect. Volvra raises program_limit_exceeded above this value. |

Override the cap for one call by passing `max_rows` to `volvra.undo`.
Volvra records the override in `volvra.undo_log.cap_override`.

## Capture settings

The following table describes the settings that control what Volvra
records:

| Setting | Default | Description |
|---|---|---|
| capture_updates | changed | Whether an UPDATE stores only the changed columns, or complete before and after images. Accepts changed or full. |
| capture_no_op_updates | off | Whether Volvra records an UPDATE that changed nothing. Accepts on or off. |
| on_truncate | capture | What Volvra does when a covered table is truncated. Accepts capture, block, or allow. |
| truncate_capture_max_rows | 100000 | Above this row count, capture mode refuses the truncate rather than copying the whole table into the history. |

The `capture_updates` setting can be overridden per table, because the
trade-off between throughput and storage changes with row width:

```sql
SELECT volvra.set_capture_mode('sessions', 'full');
SELECT volvra.set_capture_mode('documents', 'changed');
SELECT volvra.set_capture_mode('sessions', NULL);
```

Passing NULL removes the override, so the table follows the
`capture_updates` setting again. See the
[Performance](performance.md) document for the measured difference.

## Truncate behavior

Row triggers never fire on TRUNCATE, so Volvra attaches a
statement-level trigger. The following table describes each
`on_truncate` mode:

| Mode | Behavior |
|---|---|
| capture | Volvra writes one delete image per row, then allows the truncate. The truncate is fully reversible. |
| block | Volvra refuses the truncate. DELETE remains captured and reversible. |
| allow | Volvra allows the truncate and records a marker. An undo refuses to cross that marker, because the rows are unrecoverable. |

Capture mode refuses tables larger than
`truncate_capture_max_rows` rather than silently copying a whole table
into the history.

## Retention settings

The following table describes the settings that control how long
Volvra keeps history:

| Setting | Default | Description |
|---|---|---|
| retention_default | 90 days | How long Volvra keeps history for a table with no per-table policy. |

Set a per-table policy with `volvra.set_retention`:

```sql
SELECT volvra.set_retention('orders', '30 days');
```

Volvra deletes nothing until `volvra.purge` runs. See the
[Managing Retention](retention.md) document.

## Integrity settings

The following table describes the settings that control tamper
evidence:

| Setting | Default | Description |
|---|---|---|
| seal_max_rows | 1000000 | The largest span volvra.seal will hash in one call. A longer backlog is sealed in batches over successive calls, never refused. |

## Role settings

The following table describes the setting that controls how Volvra
behaves when its roles are missing:

| Setting | Default | Description |
|---|---|---|
| strict_roles | off | When on, a missing volvra role raises insufficient_privilege instead of degrading to permissive checks. |

Turn `strict_roles` on for any deployment that matters. Volvra reports
the setting as a warning in `volvra.preflight()` while the setting is
off.

## Companion settings

The following table describes the settings that the durable tier uses:

| Setting | Default | Description |
|---|---|---|
| companion_slot | volvra_companion | Name of the logical replication slot the companion reads. |
| companion_publication | volvra_pub | Publication the companion subscribes to. |
| companion_lag_warn_bytes | 536870912 | Retained WAL at which volvra.companion_status reports a warning. |
| companion_lag_max_bytes | 5368709120 | Retained WAL at which the slot becomes a threat to the database. |

The companion reads its own thresholds from command line flags rather
than from these settings, so the two must agree. See the
[Companion Reference](companion_reference.md) document.

## Recording the acting application

Volvra records two identities for every change. The `db_user` column
holds the authenticated principal and is the audit column. The `actor`
column holds whatever the application declares, so a service can name
itself:

```sql
SET LOCAL volvra.actor = 'svc:checkout';
```

Use `SET LOCAL` rather than `SET`. Behind a transaction-mode
connection pooler, such as the default pooler on Supabase or Neon,
sessions are shared between clients, so a session-level setting can
outlive the transaction and be attributed to another client's work.

## Next Steps

- The [Managing Retention](retention.md) document explains how Volvra
  reclaims history.
- The [Performance](performance.md) document measures the cost of each
  capture mode.
- The [Function Reference](function_reference.md) document documents
  every function and argument.
