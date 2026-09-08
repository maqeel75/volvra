# CLI Reference

This document documents the `volvra` command line script, its
commands, and its options. The script wraps the SQL functions and
adds a confirmation step before anything changes.

## What the script is for

Every operation the script performs is available directly in SQL, so
the script adds no capability. The script adds one thing SQL cannot:
the script shows the plan, names any conflicts, asks once, and only
then applies.

The script also refuses to apply a change when no terminal is present,
unless you pass `--yes` deliberately. A scheduled job or a pipe
therefore cannot silently rewrite production data.

## Installing the script

The script is `bin/volvra`, written in shell and requiring only
`psql`. Copy the script onto your path:

```bash
sudo install -m 0755 bin/volvra /usr/local/bin/volvra
```

## Connecting

The script uses the standard PostgreSQL environment variables, so
`PGHOST`, `PGDATABASE`, `PGUSER`, and the rest work as usual. Pass a
connection string instead with `--dsn`:

```bash
volvra --dsn "postgres://user@host/db" status
```

## Command summary

The following table describes each command:

| Command | Purpose |
|---|---|
| status | Report what is covered and whether capture is running. |
| uncovered | List tables with no undo. |
| cover | Start covering a table or a schema. |
| uncover | Stop covering a table or a schema, keeping history. |
| mark | Name a moment you may want to return to. |
| marks | List marks, and what undoing to each would cost. |
| unmark | Remove a mark. The history is untouched. |
| log | List recent transactions, newest first. |
| history | Show every version of one row. |
| preview | Show the compensating SQL and change nothing. |
| undo | Show the plan, ask once, then apply. |
| preflight | Report whether the install is shaped for production. |
| maintain | Extend partitions, apply retention, and seal. |
| seal | Make the history captured so far provable. |
| verify | Re-check every seal against the history. |
| forget | Erase one subject's history, after confirming. |
| help | Print usage. |

## Global options

The following table describes the options every command accepts:

| Option | Description |
|---|---|
| --dsn DSN | The libpq connection string. Otherwise the PG environment variables apply. |
| --yes, -y | Skip the confirmation prompt. |
| -h, --help | Print usage. |

Both options may appear before or after the command name.

## Selecting what to undo

The `preview` and `undo` commands take the same selector. At least one
criterion is required. The following table describes each option:

| Option | Description |
|---|---|
| --table TABLE | Limit the selection to one table. |
| --txid N | Select one transaction. |
| --since WHEN | Select changes after this time. |
| --until WHEN | Select changes up to this time. |
| --actor NAME | Select changes an application declared it made. |
| --user NAME | Select changes one database role made. |
| --where SQL | A predicate over old_row, new_row, and pk. |
| --to NAME | Everything recorded since the mark NAME. |

Time values are interpreted by PostgreSQL rather than by the shell, so
relative expressions such as `10 min ago` and `today` work, and the
clock that matters is the server's.

The following table describes the options that change how an undo
applies:

| Option | Description |
|---|---|
| --max-rows N | Raise the blast-radius cap for this call. |
| --skip-conflicts | Revert what still matches and leave changed rows alone. |

## Command-specific options

Several commands take options of their own. The following table
describes each one:

| Command | Option | Description |
|---|---|---|
| cover, uncover | --schema SCHEMA | Act on every eligible table in a schema rather than one table. |
| log | -n N | Return at most N transactions. The default is 20. |
| log | --since WHEN | Return only transactions after this time. |
| forget | --hard | Delete the history rows outright rather than redacting them. Use when the primary key is itself personal data. |
| forget | --reason TEXT | Record why the erasure was performed, in volvra.erasure_log. |
| mark | --note TEXT | Record why the mark was taken. |
| mark | --replace | Move an existing mark to now, rather than failing. |

The `--hard` option is irreversible and removes the change records as
well as their content. Redaction, which is the default, keeps the
record that a change happened.

## Examples

List the five most recent transactions:

```bash
volvra log -n 5
```

Preview reverting one service's work since this morning:

```bash
volvra preview --actor svc:pricing --since today
```

Revert a mistaken migration by transaction, with a confirmation
prompt:

```bash
volvra undo --txid 848291
```

Revert one customer's rows within the last hour:

```bash
volvra undo --table orders --since '1 hour ago' \
    --where "old_row->>'customer' = 'acme'"
```

Start covering every table in a schema:

```bash
volvra cover --schema public
```

Mark a moment before a deployment, then rewind to it:

```bash
volvra mark before-deploy --note 'release 042'
volvra marks
volvra undo --to before-deploy
```

Show the history of one row:

```bash
volvra history orders '{"id":1}'
```

Erase one subject's history, naming the reason:

```bash
volvra forget people '{"id":1}' --reason 'GDPR art.17'
```

Delete the history rows outright, for a subject whose primary key is
itself personal data:

```bash
volvra forget subscribers '{"email":"ada@example.com"}' --hard \
    --reason 'GDPR art.17'
```

List the ten most recent transactions since this morning:

```bash
volvra log -n 10 --since today
```

## Scheduling

The `maintain` command is the only command worth scheduling:

```bash
volvra maintain
```

Run the command hourly or daily. The interval you choose is also the
width of the window in which tampering would go undetected.

## Exit codes

The following table describes the exit codes:

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | The command failed, or the user declined the confirmation. |
| 2 | A check found a critical problem, as with preflight and verify. |

## Piping output

Commands run more than one query, so piping a command into a program
that closes the pipe early, such as `grep -q`, can terminate the
command with a broken pipe. Capture the output first when scripting:

```bash
out=$(volvra status)
```

## Next Steps

- The [Undoing Changes](undoing_changes.md) document explains the
  selector in SQL terms.
- The [Function Reference](function_reference.md) document documents
  the underlying functions.
