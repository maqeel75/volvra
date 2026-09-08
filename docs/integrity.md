# Verifying History Integrity

This document explains how Volvra proves that the recorded history has
not been altered, and what that proof does and does not cover.

## Resistance and evidence

Volvra blocks writes to the history. UPDATE, DELETE, and TRUNCATE on
`volvra.change_log` raise `insufficient_privilege` through a guard
trigger, and the guard applies to the table owner as well.

Blocking writes makes the history tamper resistant. Being resistant is
not the same as being able to prove that nothing was altered, which is
what sealing provides.

## Why sealing covers ranges

Chaining every row would mean serializing every writer on the tail of
the log, which would remove the throughput Volvra is careful to
preserve. Sealing therefore covers ranges of the log, off the write
path entirely.

The consequence is honest and unavoidable: changes captured since the
last seal are not yet provable. `volvra.health` reports how many.

## Sealing the history

`volvra.seal` hashes everything captured since the last seal and links
the result to the previous seal:

```sql
SELECT seal_id, from_id, to_id, row_count, chain_hash FROM volvra.seal();
```

The function returns no rows when nothing new has been captured, so
calling the function repeatedly is harmless. `volvra.maintain`
includes a seal, which is the recommended way to schedule one.

The `seal_max_rows` setting bounds how large a span one call will
hash, because sealing walks the span row by row. A longer backlog is
sealed in batches over successive calls rather than refused, so a
database that has gone unsealed for a long time still catches up one
call at a time.

## Verifying the history

`volvra.verify` re-hashes every sealed span and re-walks the chain:

```sql
SELECT seal_id, from_id, to_id, rows_sealed, rows_found,
       verdict, kind, detail
FROM volvra.verify();
```

The following table describes each verdict:

| Verdict | Meaning |
|---|---|
| ok | The span hashes exactly as the span was sealed. |
| changed by recorded erasure or retention | The span changed, and a ledger entry recorded after that seal accounts for the difference. |
| TAMPERED | The span changed and nothing recorded explains the difference. |
| CHAIN BROKEN | A seal was removed, reordered, or inserted. |
| SEAL FORGED | The seal row itself has been altered. |

The `kind` column names what was done to the span. The following table
describes each value:

| Kind | Meaning |
|---|---|
| content altered in place | Every row is still present, so a row's content changed. |
| rows removed | Fewer rows are present than the seal recorded. |
| rows inserted | More rows are present than the seal recorded. |

A seal proves that interference happened. A seal cannot undo the
interference, and the altered or missing history is not recoverable
from the seal.

## Lawful loss is recorded

Retention and erasure both remove history legitimately, and both
record what they removed. `volvra.verify` reads those ledgers and
reports an explained difference separately from tampering.

Volvra only accepts a ledger entry recorded after the seal in
question. An entry from before the seal was already reflected in the
content that was sealed, so the entry cannot account for a later
change.

Re-seal after a retention or erasure run to restore provable coverage.
`volvra.maintain` does so in the correct order.

## Verifying the installed code

Sealing covers the history. `volvra.fingerprint` covers the code:

```sql
SELECT scope, objects, sha256 FROM volvra.fingerprint();
```

The function hashes the installed function bodies, including their
SECURITY DEFINER flags and search_path settings, along with the table
definitions and the triggers. The value is identical across
PostgreSQL 14 through 19, so one published value covers every
supported release.

The check catches what no signature and no package manager can see: a
function altered after install. Replacing any Volvra function changes
the hash, and so does adding a function to the schema. New monthly
partitions deliberately do not change the hash, because a value that
drifted on its own every month would be ignored.

`volvra.preflight` reports the fingerprint, so the check is part of
the routine rather than something to remember.

## What integrity checking does not cover

The guarantees have limits worth stating plainly:

- A superuser can disable the guard trigger, alter the history, and
  re-seal. Install Volvra as a dedicated non-superuser owner.
- A seal over no rows verifies clean, so a seal does not prove that
  capture was running. That is why Volvra grades a registered table
  that is not capturing as critical.
- The published fingerprint is only as trustworthy as the place you
  read it. The check moves trust from the file to the release notes.
- Changes since the last seal are not covered by any seal.

## Next Steps

- The [Managing Retention](retention.md) document explains how
  retention records what it removes.
- The [Erasing Data](erasure.md) document explains how erasure records
  what it removes.
- The [Security](security.md) document describes the privilege model
  the guarantees rest on.
