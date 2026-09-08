# Test plan

Planned 2026-09-07, to run next session. The goal is coverage that is
comprehensive across three axes at once: every supported PostgreSQL
version, every privilege context, and every scenario the design makes
claims about.

## Where we are

The following table describes the current baseline:

| Measure | Value |
|---|---|
| SQL assertions | 272 across 9 suites |
| Shell checks | 58 across the CLI and companion suites |
| PostgreSQL versions | 14, 15, 16, 17, 18, 19beta1 |
| Public functions | 38 |

## The central gap

Everything substantial runs as a superuser. The non-superuser path
runs `nosuperuser.sql` only, which is 9 assertions, so 263 of 272
assertions have never executed as anything but a superuser.

That is not a hypothetical weakness. It is exactly what hid two
`GRANT` statements that had silently failed to apply, leaving
`volvra_viewer` unable to read six documented tables and the companion
unable to report progress unless it owned the schema. A documentation
audit found those, not the tests.

Closing this gap is the first priority, and it is mostly mechanical.

## Priority 1: run everything twice per version

Restructure `test/run.sh` so each version runs the whole battery in
two privilege contexts:

- installed and operated by a superuser, which is today's behavior.
- installed and operated by a non-superuser owner holding CREATE on
  the database and CREATEROLE, which is what a managed provider gives
  you.

This turns 6 runs into 12 and needs no new assertions. Every existing
suite must pass unchanged in both contexts; any that cannot is either
a bug or a documented superuser-only behavior, and both outcomes are
worth having in writing.

Expect real failures on the first attempt. Candidates include the
partition grants, `SECURITY DEFINER` ownership, `ALTER TABLE` on
tables the owner does not own, and `pg_replication_slots` visibility.

## Priority 2: a privilege matrix

Add `test/privileges.sql`, driven by a table rather than by prose. For
each role and each public function, assert allowed or denied.

The following table describes the roles to cover:

| Role | Represents |
|---|---|
| superuser | The install that preflight grades as critical. |
| schema owner, not superuser | The recommended production install. |
| volvra_admin, not owner | An administrator who does not own the schema. |
| volvra_operator with table rights | An operator who can legitimately undo. |
| volvra_operator without table rights | An operator who must be refused. |
| volvra_viewer with SELECT | A reader of history. |
| volvra_viewer without SELECT | A reader who must see nothing. |
| application role, no volvra grants | The role whose writes are captured. |
| role with no grants at all | The role that must reach nothing. |

Assert both directions for every cell: that a permitted call succeeds,
and that a forbidden call raises `insufficient_privilege` rather than
returning empty. An empty result and a refusal are different answers,
and only one of them is safe.

This is the suite that would have caught the grant bugs on the day
they were introduced.

## Priority 3: concurrency

No test currently runs two sessions at once, and the properties most
likely to be wrong are the ones written for concurrent access. Add
`test/concurrency.sh`, driving real parallel `psql` sessions.

The following scenarios need covering:

- two undos of the same table at once, which must serialize on the
  advisory lock rather than interleave.
- two undos of overlapping multi-table selections, which must queue
  rather than deadlock.
- an undo running while another session writes the same rows, which
  must produce a conflict rather than a lost update.
- two `volvra.seal()` calls at once, which must not produce
  overlapping spans.
- two companions on one slot, where the second must be refused.
- `volvra.maintain()` running while an undo is in progress.

## Priority 4: crash and recovery

Every one of these should be safe by design, and none is demonstrated.
Add `test/recovery.sh`:

- the companion killed with SIGKILL mid-segment, then restarted, which
  must resume without losing or duplicating a change.
- the database restarted mid-undo, which must leave no partial undo.
- the database restarted mid-`purge`, mid-`seal`, and mid-migration.
- the archive filesystem full during a write.
- a manifest truncated mid-write, which the atomic rename should make
  impossible.

## Priority 5: upgrade paths

`test/fixtures/` holds only `volvra-v1.sql`, so v1 to v6 is the only
tested upgrade. Someone on v2, v3, v4, or v5 upgrades through a path
nothing exercises.

Capture a fixture per released schema version and test every path to
the current version, plus each single-step path. Seed real history in
each fixture, and assert row counts, preserved identifiers, sequence
continuity, and an undo driven entirely by pre-upgrade history.

## Priority 6: scenario coverage

The following table describes the scenarios not currently covered,
grouped by area:

| Area | Scenario |
|---|---|
| Table shapes | Composite primary key, natural text key, identity key, generated columns, a partitioned user table, an unlogged table, a temporary table. |
| Type fidelity | The full 37-column matrix under `capture_updates = full`, which is currently proven on three columns. |
| Schema change | Add, drop, and rename a column; change a type; add NOT NULL; rename the table; move it between schemas; drop and recreate it. |
| Identifiers | Quoted, mixed case, 63-character maximum length, non-ASCII, and names containing quotes and dots. |
| Foreign keys | Self-referencing, multi-level cascade, `SET NULL`, `SET DEFAULT`, deferrable and non-deferrable, circular. |
| Truncate | All three modes against an empty table, a table at the row cap, and a partitioned table. |
| Partitions | A transaction spanning a month boundary, a missing month, a full default partition, and retention that empties every partition. |
| Integrity | A `TimeZone` change between sealing and verifying, a clock moved backwards, and sealing across a retention run. |
| Erasure | A subject whose key appears in several tables, a composite key, and a redaction followed by an undo of the redacted range. |
| Row-level security | A covered table that has its own RLS policies, and a `FORCE ROW LEVEL SECURITY` table. |
| Pooling | `volvra.actor` under transaction-mode pooling, which is the documented failure mode. |
| Companion | Publication drift after covering a new table, `wal_level` turned off while a slot exists, `REPLICA IDENTITY` removed after setup, a slot conflict, and an archive from a different slot. |
| Locale | A non-UTF8 database encoding and a non-C collation. |

## Priority 7: scale

Everything runs on thousands of rows. Add a scale suite, run on demand
rather than in the matrix:

- an undo of one million rows against the blast-radius cap.
- `volvra.seal()` against `seal_max_rows`, and past it.
- history growth across enough partitions that retention drops
  several.
- `volvra.storage()` and `volvra.activity()` against a large history.

## How to run it

The matrix must stay one command. Extend `test/run.sh` to take the
privilege context as a dimension, and keep the on-demand suites
separate because they need special setup or a long run:

```bash
./test/run.sh                  # 6 versions, both privilege contexts
./test/run-companion.sh        # durable tier, 6 versions
./test/concurrency.sh 17       # parallel sessions
./test/recovery.sh 17          # crash and restart
./test/scale.sh 17             # large volumes, on demand
./test/bench.sh 17 20 3        # cost, on demand
```

## What done looks like

The plan is complete when the following are all true:

- every suite passes in both privilege contexts on all six versions.
- the privilege matrix asserts both directions for every role and
  function pair.
- every scenario in the priority 6 table has a named assertion or a
  written reason for being out of scope.
- every released schema version has an upgrade fixture and a tested
  path to the current version.
- concurrency and recovery suites exist and pass.

## Before starting

Put the repository under version control first. There is no git
history, so a restructuring of `test/run.sh` cannot be reviewed or
reverted, and ~9,000 lines exist with no way to see what changed.
