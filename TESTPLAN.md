# Test plan

Planned 2026-09-07, to run next session. The goal is coverage that is
comprehensive across three axes at once: every supported PostgreSQL
version, every privilege context, and every scenario the design makes
claims about.

## Where we are

The following table describes the current baseline:

| Measure | Value |
|---|---|
| SQL assertions | 374 across 10 suites, in two privilege contexts |
| Privilege pairs | 301, asserted in both directions |
| Shell checks | 79 across CLI, concurrency, and recovery |
| PostgreSQL versions | 14, 15, 16, 17, 18, 19beta1 |
| Public functions | 44 |

Priorities 1 through 4 and 6 are complete. The following table
describes what each one delivered:

| Priority | State | Where |
|---|---|---|
| 1. Both privilege contexts | Done | `test/run.sh`, `CONTEXTS=(owner super)` |
| 2. Privilege matrix | Done | `test/privileges.sql`, 301 pairs |
| 3. Concurrency | Done | `test/concurrency.sh`, 21 checks |
| 4. Crash and recovery | Done | `test/recovery.sh`, 22 checks |
| 5. Upgrade paths | Largely moot | See the priority 5 section |
| 6. Scenario coverage | Done | `test/scenarios.sql`, 72 assertions |
| 7. Scale | Open | - |

## The central gap

Everything substantial runs as a superuser. The non-superuser path
runs `nosuperuser.sql` only, which is 9 assertions, so 263 of 272
assertions have never executed as anything but a superuser.

That is not a hypothetical weakness. It is exactly what hid two
`GRANT` statements that had silently failed to apply, leaving
`volvra_viewer` unable to read six documented tables and the companion
unable to report progress unless it owned the schema. A documentation
audit found those, not the tests.

Closing this gap was the first priority. It is closed: `test/run.sh`
now runs the whole battery in both contexts, and the privilege matrix
in priority 2 is what catches a grant that fails to apply. It has
since caught a third such case, on `volvra.restore_point`.

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

Done on 2026-09-08. `test/concurrency.sh` drives real parallel `psql`
sessions and passes 21 checks on all six versions.

Writing it corrected one assumption rather than finding a defect. The
first version of the lost-update scenario had the racing writer write
inside the undo window, and reverting that write is correct behavior,
not a lost update. The scenario only tests the conflict guard when the
racing write lands after the window closes, which is what the suite
now does; it also asserts that `skip_conflicts` then reverts the
uncontended rows and still refuses the contended one.

The following scenarios are covered:

- two undos of the same table at once, which must serialize on the
  advisory lock rather than interleave.
- two undos of overlapping multi-table selections, which must queue
  rather than deadlock.
- an undo running while another session writes the same rows, which
  must produce a conflict rather than a lost update.
- two `volvra.seal()` calls at once, which must not produce
  overlapping spans.
- two companions on one slot, where the second must be refused. The
  second reports PostgreSQL's own `55006`, "replication slot is active
  for PID", and exits without writing change data.
- `volvra.maintain()` running while an undo is in progress.
- every write from four concurrent writers captured and attributed
  separately, which the single-session suites cannot show.

The companion scenario needs a Linux binary in
`VOLVRA_COMPANION_BIN`; without one it is skipped rather than passing
quietly.

## Priority 4: crash and recovery

Done on 2026-09-08. `test/recovery.sh` passes 22 checks on all six
versions, killing the server with `pg_ctl -m immediate` and the
companion with `SIGKILL`.

This one found a real defect. After a `SIGKILL` the companion
re-archived 500 changes it already held, because the LSN passed to
`START_REPLICATION` is a request rather than a guarantee: PostgreSQL
may begin streaming from an earlier point, and after a hard kill it
does, since the slot's confirmed position lags what the archive holds
durably. The companion resumed from the right place and then wrote
whatever the server sent it. It now drops changes at or below the
archive's resume point, and `verify()` no longer reports the result as
out of order.

Writing the suite also found that `verify` walked only the segments
the manifest covered, so a segment file the manifest did not
cover - the normal residue of a kill mid-segment, or a file planted by
hand - was silently ignored. Since the archive is documented as
readable without the binary, `verify` now reports those as
`UNRECORDED`. They are notices rather than integrity failures, so a
crash does not make verification fail, and `restore` still refuses
only on real failures.

A third finding was in the test rather than the product: the first
version asserted that an archive verified while its manifest recorded
zero segments, which is the same vacuous shape as the earlier
`>= 0` size assertion. The suite now asserts the manifest is
non-empty before it trusts any tamper check, and forces rotation with
`--segment-bytes 8192` so segments actually reach the manifest.

The following scenarios are covered:

- the companion killed with SIGKILL mid-segment, then restarted, which
  must resume without losing or duplicating a change.
- the database restarted mid-undo, which must leave no partial undo.
- the database restarted mid-`purge`, mid-`seal`, and mid-migration.
- the archive filesystem full during a write, using a 1 MB tmpfs. If
  the tmpfs never fills the check reports itself as inconclusive
  rather than passing.
- a manifest truncated mid-write, which the atomic rename should make
  impossible, plus a flipped byte in a manifested segment and a
  segment file planted by hand.
- a crash mid-install, which must leave the schema either absent or
  complete, because the install is one transaction.

## Priority 5: upgrade paths

This priority is largely moot as written. It assumed schema versions 1
through 6 existed; collapsing the pre-release migrations into a single
`1 | initial schema` means there is one released schema and therefore
no multi-version upgrade path to fix. The `volvra-v1.sql` fixture and
`upgrade-verify.sql` still run on every version, which covers
installing the current schema over an existing one carrying real
history.

What is still owed here, after the first release rather than before
it:

- a fixture captured per released schema version, added as each
  release happens rather than reconstructed later.
- deletion of the pre-release repair block in `sql/volvra.sql`, which
  exists only to fix databases created during development.

## Priority 6: scenario coverage

Done on 2026-09-08. `test/scenarios.sql` covers eleven areas and runs
in a database of its own as the unprivileged owner, because it asserts
that `verify()` is clean and phase 4 deliberately plants tampering.

This priority found the two worst defects of the whole effort, both in
the same blind spot: volvra assumed a covered table keeps the name and
the shape it had when it was covered.

**A partitioned table was left unusable.** `enable()` on a partitioned
parent reported success, and then every INSERT failed with
"sc.part_a is not registered via volvra.enable()". PostgreSQL
propagates a row trigger from a parent to its partitions and fires it
with `TG_RELID` set to the partition, which was not what had been
registered. `capture()` now walks up to the covered ancestor through
`volvra._covered_ancestor()` and records the change under that name,
so a partitioned table behaves as the one table the caller covered,
including partitions attached later. Two consequences fell out of
fixing it: statement-level TRUNCATE triggers are *not* propagated, so
`volvra.cover_partitions()` attaches them and `maintain()` reconciles
partitions added since; and a truncate of a parent fires the trigger on
the parent and on every partition, so the parent must capture nothing
and each partition only its own rows, or three rows are captured nine
times.

**Renaming a covered table left it unwritable.** `ALTER TABLE ...
RENAME` moves the triggers with the table but left `enabled_tables`
naming a table that no longer existed, so every subsequent write
failed. `enabled_tables` gained `rel_oid`, which survives both RENAME
and SET SCHEMA, and `capture()` finds the row by OID and corrects the
name, raising a notice. History stays under the old name, because that
is what was true when the change happened.

Neither defect could have been found by the other suites: every one of
them covers a table and then leaves its name and shape alone.

Five test bugs were also found and fixed while writing it, and they are
worth recording because four are the same mistake:

- `on_truncate` values are `block`, `capture`, and `allow`. There is
  no `refuse`.
- `capture` mode records truncated rows as `D`, not `T`, because
  re-inserting a deleted row is what undoing a truncate does. `T` is
  the marker written by `allow` mode.
- `change_log` columns are `ts`, `old_row`, and `new_row`.
- `now()` inside a `DO` block is the transaction's start time, which is
  earlier than a `clock_timestamp()` taken inside the same block.
- multi-table selection is the named `tables` parameter; the first
  positional argument is a single `regclass`.

The following table describes the areas the suite covers:

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

Three rows in that table remain deliberately out of scope, with
reasons rather than assertions:

- a temporary table cannot be covered usefully, because its triggers
  and its rows die with the session that created it, and the history
  would outlive the table it describes.
- a non-UTF8 database encoding and a non-C collation need a database
  created with those settings, so they belong to a separate driver
  rather than a suite that runs inside an existing database. The
  identifier and type assertions cover the cases most likely to break,
  including non-ASCII identifiers and values.
- transaction-mode pooling is asserted through the mechanism rather
  than through a pooler: the suite proves `SET LOCAL` does not leak
  across transactions and a plain `SET` does, which is the whole of
  the documented failure mode.

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
./test/examples.sh             # the six documented examples, 6 versions
# scenarios run inside ./test/run.sh, in a database of their own
./test/concurrency.sh 17       # parallel sessions
./test/recovery.sh 17          # crash and restart
./test/scale.sh 17             # large volumes, on demand
./test/bench.sh 17 20 3        # cost, on demand
```

The concurrency and recovery suites exercise the companion when a
Linux binary is available. Build one first:

```bash
GOOS=linux GOARCH=amd64 go build -C companion -o /tmp/volvra-companion .
export VOLVRA_COMPANION_BIN=/tmp/volvra-companion
```

## What done looks like

The plan is complete when the following are all true:

- every suite passes in both privilege contexts on all six versions.
- the privilege matrix asserts both directions for every role and
  function pair.
- every scenario in the priority 6 table has a named assertion or a
  written reason for being out of scope. Satisfied: eleven areas are
  asserted, and three are out of scope with reasons.
- every released schema version has an upgrade fixture and a tested
  path to the current version. There is one released schema, so this
  is satisfied for now and becomes real work at the second release.
- concurrency and recovery suites exist and pass.

## Before starting

Done. The repository is under version control at
`github.com/maqeel75/volvra`, so the restructuring of `test/run.sh`
and everything after it is reviewable and revertable.
