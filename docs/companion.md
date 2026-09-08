# Companion Overview

This document explains what the Volvra companion does, when to deploy
the companion, and what the companion requires. The companion is the
durable tier; the trigger tier alone is not a backup.

## Why a second tier exists

The trigger tier records history in a table inside the same database,
so the history shares the fate of the database. The trigger tier makes
mistakes recoverable; the trigger tier does not survive the loss of
the database.

The companion is a separate process that reads a logical replication
slot and writes change data to storage you own. The archive survives
the database, and capture moves off the write path.

Deploy the companion when the history must outlive the database. Most
deployments use the trigger tier alone.

## Requirements

The companion has two requirements that the trigger tier does not. The
following table describes each requirement:

| Requirement | Scope | How to satisfy |
|---|---|---|
| wal_level = logical | Server | A configuration change and a restart. On Amazon RDS, set rds.logical_replication to 1 in the parameter group. |
| REPLICA IDENTITY FULL | Each covered table | The volvra.companion_setup function sets this. |

Row triggers see the old row directly and never needed
`REPLICA IDENTITY FULL`. The requirement belongs to the companion
alone, and conflating the two makes the trigger tier sound harder to
adopt than it is.

## Why pgoutput

The companion decodes with `pgoutput`, the only logical decoding
plugin built into PostgreSQL. Plugins such as `wal2json` are
server-side extensions, which managed providers do not offer.

Choosing `pgoutput` keeps the companion usable on the same providers
the core supports. Because `pgoutput` streams a publication, Volvra
maintains one for you.

## Preparing the database

Run `volvra.companion_setup` after covering the tables you want
archived:

```sql
SELECT step, object, detail FROM volvra.companion_setup('public');
```

The function reports the server's `wal_level`, sets
`REPLICA IDENTITY FULL` on each covered table in the schema, and
rebuilds the publication from the set of covered tables.

Volvra rebuilds the publication rather than patching the publication,
because reconciling additions and removals by hand is how a table ends
up silently outside the publication.

Covering a table after this call does not require running the call
again. `volvra.enable` adds the newly covered table to the
publication itself, because a covered table outside the publication is
archived by nothing, and the companion cannot report what the
publication never mentioned. If the caller does not own the
publication, `volvra.enable` still enables capture and raises a
warning naming the table; run `volvra.companion_setup` as the
publication owner to close the gap.

## Running the companion

Start the companion against a directory it may write:

```bash
volvra-companion run --dsn "$DATABASE_URL" --archive /srv/volvra-archive
```

The companion creates the replication slot if the slot is absent,
resumes from the last segment the archive holds, and streams
continuously. Stop the companion with SIGINT or SIGTERM; the companion
flushes and closes the current segment before exiting.

See the [Companion Reference](companion_reference.md) document for
every command and flag.

## The archive format

The archive is newline-delimited JSON in numbered segments, described
by a manifest that chains the SHA-256 hash of each segment. One line
holds one change:

```json
{"lsn":"0/1B2A1F8","xid":748,"commit_ts":"2026-09-07T13:48:55Z",
 "table":"\"public\".\"accounts\"","op":"U","pk":{"id":1},
 "old":{"balance":"100"},"new":{"balance":"0"}}
```

The format is deliberately readable without the companion and without
PostgreSQL. An archive whose integrity or legibility depends on the
system that produced the archive is not a durable copy of anything.

## Verifying an archive

`verify` re-hashes every segment and re-walks the chain, using no
database and no network:

```bash
volvra-companion verify --archive /srv/volvra-archive
```

The following table describes each verdict the command reports:

| Verdict | Meaning |
|---|---|
| TAMPERED | The segment content no longer matches the manifest hash. |
| TRUNCATED | The segment holds fewer lines than the manifest recorded. |
| CHAIN BROKEN | A segment does not follow the previous one, so one was removed, reordered, or inserted. |
| MANIFEST FORGED | The manifest entry itself has been altered. |
| MISSING | The segment file is absent. |
| CORRUPT | Lines in the segment are not valid change records. |

## Restoring from an archive

`restore` loads archived changes back into `volvra.change_log`, so the
ordinary undo path drives them:

```bash
volvra-companion restore --archive /srv/volvra-archive \
    --dsn "$DATABASE_URL"
```

Loading into the ordinary history means an archived change gets the
same preview, conflict guard, and blast-radius cap as any other,
rather than a second and less careful recovery route.

The command refuses to load an archive that does not verify, because a
restore is exactly the moment integrity matters. Add `--dry-run` to
parse and count without connecting to a database.

After restoring, revert the changes as usual:

```sql
SELECT * FROM volvra.preview_undo('accounts', :from_ts, :to_ts);
```

## The replication slot is a liability

A replication slot retains write-ahead log segments until the consumer
catches up. If the companion stops, the database keeps WAL for the
companion until the disk fills and the server stops.

That failure mode is worse than the problem the companion solves.
Losing archived history is recoverable; a database that will not start
is an outage.

The companion therefore enforces a ceiling. Past `--lag-max`, the
companion advances the slot and records the skipped range as a gap, in
the archive and in `volvra.companion_gap`:

```
SAFETY VALVE: slot volvra_companion retains 5368709120 bytes of WAL,
past the ceiling
advancing the slot to 0/2A1F8C0 and recording the skipped range as a
gap; the alternative is letting the disk fill and the database stop
```

A gap you know about is better than an outage. Watch the retained
volume rather than relying on the ceiling:

```sql
SELECT item, value, status FROM volvra.companion_status();
```

## Monitoring the companion

`volvra.companion_status` reports the whole durable tier, starting
with the numbers that predict disk exhaustion:

```sql
SELECT item, value, status FROM volvra.companion_status();
```

The function reports the server `wal_level`, the publication and its
table count, covered tables that the publication does not carry,
covered tables missing `REPLICA IDENTITY FULL`, the slot and whether a
companion is connected, retained WAL against both thresholds, the last
archived position, and any recorded gaps.

The `publication drift` row is the one to watch. A covered table
outside the publication looks like working coverage until the day the
archive is needed, so the row reports `INCOMPLETE` and names how many
covered tables are affected.

Volvra records the companion's progress in
`volvra.companion_checkpoint`, and gaps in `volvra.companion_gap`.

## What the companion does not do

The companion has real limits, which the following list describes:

- A TRUNCATE is not recoverable from the write-ahead log, because
  row-level decoding cannot reconstruct the rows. The companion
  archives a gap. The trigger tier's capture mode is what makes a
  truncate reversible.
- Values arrive as text, because that is how `pgoutput` sends them.
  The restore command converts each value through the target table's
  row type, so a table that has since been dropped or reshaped cannot
  receive those rows.
- A table with no primary key is archived as a gap, because the change
  cannot be addressed later.
- The archive holds row changes rather than a database. Schema,
  extensions, and anything outside covered tables are not in the
  archive, so the archive is not a physical backup.

## Next Steps

- The [Companion Reference](companion_reference.md) document documents
  every command and flag.
- The [Architecture](architecture.md) document explains how the two
  tiers relate.
- The [Troubleshooting](troubleshooting.md) document covers slot and
  replication problems.
