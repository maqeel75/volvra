# Examples

This document walks through six runnable examples that demonstrate what
Volvra does. Each one is a file in the `examples` directory, is
self-contained, and is safe to run repeatedly.

Every example is verified against PostgreSQL 14 through 19 by
`test/examples.sh`, which asserts the end state rather than only that
the script ran. Examples cannot drift from the code.

## Running them

Run an example against any database that has Volvra installed:

```bash
psql "$DATABASE_URL" -f examples/01_simple_undo.sql
```

Against a throwaway container, install Volvra first:

```bash
docker run -d --name volvra-demo -e POSTGRES_PASSWORD=demo \
    -e POSTGRES_DB=shop -v "$PWD:/volvra:ro" postgres:17
sleep 8
docker exec volvra-demo psql -q -U postgres -d shop -f /volvra/sql/volvra.sql
docker exec volvra-demo psql -U postgres -d shop \
    -f /volvra/examples/01_simple_undo.sql
```

Two of the examples print an ERROR deliberately, and each says so where
it happens. Both errors are the expected result: Volvra refusing to
destroy a later change, and the history refusing to be rewritten.

## What each one shows

The following table describes the examples:

| File | Shows |
|---|---|
| 01_simple_undo.sql | A mistaken UPDATE, previewed and then reverted. |
| 02_undo_a_delete.sql | A DELETE reversed by an insert, and the two identities Volvra records. |
| 03_conflict_guard.sql | Volvra refusing to overwrite a change made after the accident. |
| 04_bad_migration.sql | One transaction id undoing a migration across two tables. |
| 05_truncate_and_integrity.sql | A reversible TRUNCATE, then tamper detection. |
| 06_marks.sql | Naming a moment and rewinding to it. |

## Example 1: a mistaken UPDATE

The simplest case. Three salaries are set to zero by an UPDATE with no
WHERE clause, and Volvra puts them back:

```sql
SELECT clock_timestamp() AS before_mistake \gset
UPDATE employees SET salary = 0;

SELECT count(*) AS reverted
FROM volvra.undo('employees', :'before_mistake', now(), confirm => true);
```

The marker is taken after the rows are inserted, so the undo reverts
only the mistake. A window reaching further back would revert the
inserts too, and correctly empty the table. Scoping an undo narrowly is
the habit to form.

The example also shows that `volvra.preview_undo` executes nothing: the
salaries are still zero after the preview runs.

## Example 2: a DELETE, and who did it

Reversing a DELETE is an INSERT of the stored row image, so the row
comes back identical:

```sql
SELECT seq, op, inverse_op, pk, status
FROM volvra.undo('customers', :'mark', now(), confirm => true);
```

Read the history at the end of this example carefully. It shows three
entries for the row, `I`, `D` and `I`, where the last is Volvra's own
undo. An undo is an ordinary change to a covered table, so Volvra
captures it, and an undo can therefore be undone.

The two identity columns differ, deliberately. `actor` reads
`svc:billing`, which the application declared and which is spoofable by
design. `db_user` reads the authenticated principal and is the column
to audit on.

## Example 3: the conflict guard

The behaviour that makes Volvra safe to point at production. A script
zeroes every invoice, and someone then fixes one of them by hand:

```sql
SELECT seq, pk, actor, conflict
FROM volvra.preview_undo('invoices', :'pre_accident', :'post_accident');
```

The preview flags `conflict` on the one row that moved on. Applying the
undo then raises `serialization_failure` and applies nothing, because
reverting that row would destroy the later fix.

Passing `skip_conflicts => true` reverts the other two rows and reports
the third as `skipped`:

```sql
SELECT seq, pk, status
FROM volvra.undo('invoices', :'pre_accident', :'post_accident',
                 confirm => true, skip_conflicts => true);
```

There is no third option. Volvra will refuse or skip, and will never
overwrite a row that has changed.

## Example 4: a bad migration

A migration is one transaction across several tables, which is the unit
people remember:

```sql
SELECT seq, table_name, inverse_op, pk, status
FROM volvra.undo_txid(:bad_txid, confirm => true);
```

Five changes across two tables are reverted by one identifier: two
price updates, two stock updates, and one accidental insert removed.
The example captures the transaction id inside the transaction, and
also shows `volvra.transactions()`, which is how you find the id when
you do not already have it.

## Example 5: TRUNCATE, and proving the history is intact

Row triggers never fire on TRUNCATE, so Volvra attaches a statement
trigger that captures every row first. All fifty rows come back.

The example then demonstrates integrity in two stages. First a plain
attempt to rewrite the history is refused outright:

```
ERROR:  volvra.change_log_y2026m09 is append-only (attempted UPDATE)
```

Then the example forces the change the way only an administrator could,
and verification catches it anyway:

```sql
SELECT seal_id, rows_sealed, rows_found, verdict, kind FROM volvra.verify();
```

The verdict reads `TAMPERED` with a kind of `content altered in place`,
and `volvra.health()` reports it as critical. Tamper resistant first,
tamper evident second.

## Example 6: marks

A mark names a moment worth returning to:

```sql
SELECT volvra.mark('before-deploy', 'release 042');
-- the deployment goes wrong
SELECT * FROM volvra.undo_to('before-deploy', confirm => true);
```

Before committing to the rewind, `volvra.marks()` reports how much it
would touch:

```sql
SELECT name, age, changes_since, tables_since, note FROM volvra.marks();
```

The example also shows that a duplicate mark name is refused rather
than moved, and that removing a mark removes a pointer and never the
history.

## Next Steps

- The [Getting Started](quick_start.md) document is the shortest path
  to a first undo.
- The [Undoing Changes](undoing_changes.md) document describes every
  way to select what to revert.
- The [Performance](performance.md) document gives the measured cost of
  coverage.
