# Monitoring

This document describes the functions that report whether Volvra is
working, what Volvra costs, and how fast the history is growing.
Every function in this document requires only membership in
`volvra_viewer`.

## Checking health

`volvra.health` returns one row per problem, and an empty result when
nothing is wrong:

```sql
SELECT severity, problem, detail FROM volvra.health();
```

The following table describes the conditions `volvra.health` reports:

| Severity | Condition |
|---|---|
| critical | A registered table is not capturing, because its trigger is disabled or missing. |
| critical | A sealed span no longer matches the history and no lawful erasure or retention explains the difference. |
| warning | A covered table captures rows but not TRUNCATE. |
| warning | History rows are sitting in the default partition. |
| warning | No partition exists for next month. |
| warning | The history has never been sealed, or changes since the last seal are not covered by one. |
| warning | Tables in the public schema have no undo coverage. |

Volvra grades a registered table that is not capturing as critical
rather than as a warning, because a table that appears protected and
is not is the worst state to be in.

## Checking the install before production

`volvra.preflight` answers a different question from `volvra.health`.
Where health reports whether Volvra is working now, preflight reports
whether the install is shaped for production:

```sql
SELECT severity, finding, detail FROM volvra.preflight();
```

The following table describes the findings preflight reports:

| Severity | Finding |
|---|---|
| critical | The volvra.capture function is owned by a superuser. |
| critical | Several SECURITY DEFINER functions in the volvra schema are owned by a superuser. |
| critical | The volvra roles do not exist, so privilege checks are permissive. |
| critical | A companion slot exists while wal_level is not logical. |
| warning | The strict_roles setting is off. |
| warning | The pg_cron extension is not installed, so maintenance must be scheduled externally. |
| warning | No tables are covered. |
| warning | Foreign keys on covered tables are not deferrable. |
| warning | Retention has never run. |
| info | The fingerprint of the installed code. |

## Reading per-table status

`volvra.status` reports the live state of every registered table:

```sql
SELECT table_name, covered, truncate_covered, changes,
       oldest_change, newest_change
FROM volvra.status();
```

The `covered` and `truncate_covered` columns read `pg_trigger`, so the
columns report whether the triggers are actually attached and enabled.

## Measuring disk usage

`volvra.storage` reports the size of each covered table against the
history Volvra holds for it:

```sql
SELECT table_name, pg_size_pretty(table_bytes) AS table,
       history_rows, pg_size_pretty(history_bytes) AS history, ratio
FROM volvra.storage();
```

The `change_log` table is shared, so `history_bytes` apportions the
total by each table's share of the rows. The figure is an estimate
rather than an exact per-table measurement.

## Measuring growth

`volvra.activity` reports captured changes over time, bucketed:

```sql
SELECT bucket, inserts, updates, deletes, changes
FROM volvra.activity('24 hours', '1 hour');
```

The first argument is the window to report, and the second is the
bucket width. Use the function to see whether history growth matches
expectations before retention becomes urgent.

## Auditing undo attempts

Every undo attempt, previewed or applied, lands in `volvra.undo_log`:

```sql
SELECT ts, db_user, actor, table_name, row_count,
       confirmed, cap, cap_override
FROM volvra.undo_log
ORDER BY id DESC
LIMIT 20;
```

The table is append-only, and a trigger stamps `db_user` rather than
trusting the value supplied by the insert. The `cap_override` column
marks an undo that raised the blast-radius cap.

## Integrating with a monitoring system

The health and preflight functions return rows rather than raising, so
an exporter can poll the functions and alert on severity. Count
critical findings as follows:

```sql
SELECT count(*) FROM volvra.health() WHERE severity = 'critical';
```

## Next Steps

- The [Managing Retention](retention.md) document explains how to
  bound history growth.
- The [Verifying History Integrity](integrity.md) document explains
  the seal chain that health checks.
- The [Performance](performance.md) document gives measured costs.
