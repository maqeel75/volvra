# Examples

Six runnable examples, each self-contained and safe to re-run. Every one
recreates its own tables, so they do not interfere with each other.

Run one against any database with Volvra installed:

```bash
psql "$DATABASE_URL" -f examples/01_simple_undo.sql
```

Or against a throwaway container:

```bash
docker run -d --name volvra-demo -e POSTGRES_PASSWORD=demo -e POSTGRES_DB=shop \
    -v "$PWD:/volvra:ro" postgres:17
sleep 8
docker exec volvra-demo psql -q -U postgres -d shop -f /volvra/sql/volvra.sql
docker exec volvra-demo psql -U postgres -d shop -f /volvra/examples/01_simple_undo.sql
```

The following table describes each example:

| File | Shows |
|---|---|
| 01_simple_undo.sql | A mistaken UPDATE, previewed and then reverted. |
| 02_undo_a_delete.sql | A DELETE reversed by an insert, and the two identities Volvra records. |
| 03_conflict_guard.sql | Volvra refusing to overwrite a change made after the accident. |
| 04_bad_migration.sql | One transaction id undoing a migration across two tables. |
| 05_truncate_and_integrity.sql | A reversible TRUNCATE, then tamper detection. |
| 06_marks.sql | Naming a moment and rewinding to it. |

Examples 03 and 05 print an ERROR on purpose. Both are the expected
result: Volvra refusing to destroy a later change, and the history
refusing to be rewritten. Each is labelled where it happens.

Examples are verified against PostgreSQL 14 through 19 by
`test/examples.sh`, so they cannot drift from the code.
