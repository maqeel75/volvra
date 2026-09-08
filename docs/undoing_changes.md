# Undoing Changes

This document describes every way to select what Volvra reverts, and
what Volvra does when a row has changed since the mistake. Previewing
an undo is always safe; applying one requires an explicit
confirmation.

## Previewing before applying

`volvra.preview_undo` returns the plan and executes nothing:

```sql
SELECT seq, table_name, op, inverse_op, pk, conflict, stmt
FROM volvra.preview_undo('orders', now() - interval '10 minutes');
```

The `stmt` column holds the exact statement Volvra would run, so the
preview is auditable. `volvra.undo` without `confirm => true` behaves
the same way.

## Applying an undo

Add `confirm => true` to apply the plan:

```sql
SELECT * FROM volvra.undo('orders', now() - interval '10 minutes',
                          now(), confirm => true);
```

Volvra applies the whole plan inside the caller's transaction, so the
undo commits completely or not at all. Volvra captures the undo, so an
undo can itself be undone.

## Selecting what to revert

`volvra.preview_undo` and `volvra.undo` take the same selector. At
least one criterion is required, because planning an undo across every
covered table by accident should not be possible.

The following table describes each selector argument:

| Argument | Selects |
|---|---|
| target | One table. |
| tables | Several tables, as an array of regclass. |
| from_ts | Changes captured after this timestamp. |
| to_ts | Changes captured up to and including this timestamp. |
| txid | One transaction, across every table the transaction touched. |
| actor | Changes an application declared it made. |
| db_user | Changes one authenticated role made. |
| predicate | A SQL boolean over old_row, new_row, pk, actor, db_user, ts, and txid. |

Combine the arguments freely. The following statement reverts one
service's damage, limited to one customer's rows, within the last
hour:

```sql
SELECT * FROM volvra.undo(
  'orders', now() - interval '1 hour', now(),
  confirm   => true,
  actor     => 'svc:pricing',
  predicate => $$old_row->>'customer' = 'acme'$$);
```

## Reverting a whole transaction

A mistaken migration is one transaction across several tables, which
is the unit people remember. Find the transaction, then revert it:

```sql
SELECT txid, ended, db_users, tables, changes FROM volvra.transactions();
SELECT * FROM volvra.undo_txid(848291, confirm => true);
```

`volvra.undo_txid` and `volvra.preview_undo_txid` are wrappers around
the selector, so the behavior is identical to passing `txid`.

## Marking a moment to come back to

A mark is a named moment. Take one before a deployment, and undoing to
it puts the covered tables back the way they were:

```sql
SELECT volvra.mark('before-deploy', 'release 042');
-- ... the deployment goes wrong ...
SELECT * FROM volvra.undo_to('before-deploy', confirm => true);
```

List the marks with what each would cost, before committing to one:

```sql
SELECT name, age, changes_since, tables_since, note FROM volvra.marks();
```

The `changes_since` column is the point of the function. Undoing to a
mark reverts everything recorded since, so knowing the size of that
first is the difference between a considered decision and a guess.

A duplicate name raises an error rather than moving the existing mark;
pass `p_replace => true` to move one deliberately. Removing a mark
with `volvra.unmark` removes a pointer and never the history.

## A mark is blunter than a transaction

Undoing to a mark reverts every recorded change since that moment, on
every covered table in scope. That includes changes other people made
legitimately, because those changes are inside the window rather than
outside it, so the conflict guard has no reason to object.

The following table compares the two ways of scoping an undo:

| Scope | Answers | Use when |
|---|---|---|
| A mark | Put these tables back the way they were. | You want a point-in-time restore of covered tables. |
| A transaction id | Undo that specific mistake. | Someone else may have done legitimate work since. |

Prefer a transaction id in production. Reach for a mark when the
intent really is to rewind, such as a failed deployment on a database
nobody else is using.

The conflict guard still applies to a mark, but it only fires for a
change Volvra never recorded, such as one made while capture was
disabled. Anything Volvra did record since the mark is part of what
you asked to revert.

## Using a predicate safely

The predicate is a WHERE fragment, not a statement. Volvra
parenthesizes the fragment before splicing the fragment into the
query, and refuses any predicate containing a semicolon, a double
hyphen, or a slash-star comment opener.

The predicate runs with the caller's own privileges, so the predicate
is a filter rather than a privilege escalation.

## When a row has changed since the mistake

Every compensating statement carries a guard that matches only if the
live row still holds the captured values. Volvra refuses the whole
undo when any row has moved on, and raises `serialization_failure`.

Revert everything else and leave the changed rows alone by passing
`skip_conflicts`:

```sql
SELECT seq, pk, status
FROM volvra.undo('orders', :t0, :t1,
                 confirm => true, skip_conflicts => true);
```

The `status` column reports `applied` or `skipped` for each row.
Volvra offers no option to overwrite a row that has changed, because
overwriting is the data loss the guard exists to prevent.

The guard tests only the columns the undo writes. A later change to a
different column is not a conflict, because reverting these columns
cannot destroy that change.

## Limiting the blast radius

Volvra refuses an undo that would affect more rows than
`max_undo_rows`, and raises `program_limit_exceeded`. Override the cap
for a single call:

```sql
SELECT * FROM volvra.undo('orders', :t0, :t1,
                          confirm => true, max_rows => 250000);
```

Volvra records the override in `volvra.undo_log`, so an unusually
large undo is visible afterwards.

## Undoing across related tables

Volvra walks a plan in reverse chronological order across every
selected table. For ordinary foreign keys that order is already
correct, because the application could only have deleted a child
before its parent.

An ON DELETE CASCADE is the exception. A cascade records the parent
first and the children afterwards, so reversing the cascade tries to
resurrect a child before its parent. Make the constraints deferrable
once, as an administrator:

```sql
SELECT constraint_name, table_name, status
FROM volvra.make_fks_deferrable('public');
```

`DEFERRABLE INITIALLY IMMEDIATE` does not change day to day behavior;
constraints are still checked at the end of each statement. The change
only allows an undo to defer the checks to COMMIT inside its own
transaction. The command takes a brief ACCESS EXCLUSIVE lock per
table, so run the command in a maintenance window.

Without deferrable constraints, an undo that trips a foreign key fails
with `foreign_key_violation`, names this function, and applies
nothing.

## When an undo finds nothing

Volvra distinguishes three situations, because "no changes reverted"
and "no record of this table" call for different responses. The
following table describes each case:

| Situation | Behavior |
|---|---|
| The table was never covered | Volvra raises invalid_parameter_value and explains that no record exists. |
| The table was covered in the past | Volvra reverts the recorded history and reports a notice that coverage has stopped. |
| The table is covered but the window is empty | Volvra reports zero changes, which is not an error. |

## Errors an undo can raise

The following table describes each error and its cause:

| Condition | Cause |
|---|---|
| serialization_failure | A row changed after the mistake and skip_conflicts is false. |
| program_limit_exceeded | The plan affects more rows than max_undo_rows allows. |
| foreign_key_violation | The plan spans related tables and a constraint is not deferrable. |
| datatype_mismatch | The table changed shape, or a required column is excluded from capture. |
| data_exception | The selection crosses a TRUNCATE whose rows were not captured, or a captured change carries no restorable column. |
| invalid_parameter_value | The target table has never been covered. |
| null_value_not_allowed | No selector was given. |
| insufficient_privilege | The caller lacks the required role, or write privileges on the target. |

## Next Steps

- The [Viewing History](viewing_history.md) document describes how to
  inspect a row's history before reverting.
- The [Covering Tables](covering_tables.md) document explains
  coverage.
- The [CLI Reference](cli_reference.md) document documents the command
  line equivalent of each operation.
