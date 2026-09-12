# Security

This document describes the pgVolvra privilege model, the guarantees
pgVolvra provides, and the guarantees pgVolvra does not provide. pgVolvra
can modify production data, so the design assumes hostile scrutiny.

Reading history is open to anyone who may already read the underlying
table. Changing data is privileged, previewed by default, separated by
role, capped, and audited.

## Roles

pgVolvra creates three roles at install, each inheriting from the one
before. The following table describes each role:

| Role | May |
|---|---|
| volvra_viewer | Read history, run previews, read the monitoring functions. |
| volvra_operator | Apply an undo, subject to holding write privileges on the target table. |
| volvra_admin | Cover and uncover tables, configure settings, run retention, seal, and erase. |

pgVolvra grants `volvra_admin` to the installing role, so a
non-superuser owner is not locked out of the install.

If the installing role lacks CREATEROLE, pgVolvra skips role creation
with a warning and privilege checks degrade to permissive. Set
`strict_roles` to `on` to make a missing role a hard error instead.

## Applying an undo requires your own privileges

`volvra.undo` runs with the caller's privileges rather than the
function owner's. Membership in `volvra_operator` is necessary but not
sufficient; the caller also needs INSERT, UPDATE, or DELETE on the
target table.

A SECURITY DEFINER undo owned by a powerful role would be a privilege
escalation primitive on production data, which is why pgVolvra does not
provide one.

## Containment

pgVolvra limits what a single undo can do. The following list describes
each limit:

- Previewing is the default, so `volvra.undo` without
  `confirm => true` returns the plan and changes nothing.
- An undo affecting more rows than `max_undo_rows` raises
  `program_limit_exceeded`, and any override is recorded.
- An undo refuses when a row has changed since pgVolvra captured the
  row, and offers no option to overwrite that row.
- An undo with no selector at all is refused, so planning across every
  covered table by accident is not possible.
- Undos of the same table are serialized by a transaction-scoped
  advisory lock.

## Integrity of the history

pgVolvra blocks writes to the history. UPDATE, DELETE, and TRUNCATE on
`volvra.change_log` raise `insufficient_privilege` through a guard
trigger, and the guard applies to the table owner as well.

Only `volvra.purge` and `volvra.forget` pass the guard, and both need
a transaction-local setting and membership in `volvra_admin`. Setting
the flag alone achieves nothing.

The erasure path may only remove content. The guard rejects any update
that changes the recorded attribution, operation, key, transaction
identifier, or timestamp, or that substitutes different content
instead of setting the images to null.

sealing, which turns resistance into evidence.

## Unforgeable capture

The `volvra.capture` function is SECURITY DEFINER and is granted to no
role. PostgreSQL checks EXECUTE on a trigger function when the trigger
is created rather than each time the trigger fires, so ordinary
writers are captured without being able to call or attach the
function.

The function also refuses any table `volvra.enable` did not cover, so
a privileged trigger cannot be pointed at a decoy table to forge
history or fill the log.

Install pgVolvra as a dedicated non-superuser owner. Every SECURITY
DEFINER function runs with its owner's rights, and
`volvra.preflight()` grades a superuser-owned install as critical.

## Confidentiality of the history

The history holds complete row images, so reading history must never
be a way around a table's own grants. pgVolvra enforces that twice.

Row-level security on `volvra.change_log` permits a reader to see a
history row only if the reader may SELECT the table the row came from.
The `volvra.history` and `volvra.preview_undo` functions also check
explicitly, so a caller receives a clear error rather than silently
empty results.

A multi-table plan checks read privilege on every table the plan
touches. An unscoped plan checks every covered table, so a plan cannot
reveal the existence of a table the caller may not read.

## Attribution

pgVolvra records two identities, deliberately. The following table
compares them:

| Column | Source | Trust |
|---|---|---|
| actor | The volvra.actor setting, when the application sets one. | Spoofable by design. Only the application knows which service acted. |
| db_user | The SET ROLE target if one is active, otherwise session_user. | Authenticated by the database. This is the audit column. |

Neither `session_user` nor `current_user` alone is correct.
`session_user` misses `SET ROLE`, and `current_user` becomes the
function owner inside the SECURITY DEFINER capture function. pgVolvra
reads the `role` setting, which survives the SECURITY DEFINER boundary
and can only ever name a role the caller genuinely holds.

Behind a transaction-mode connection pooler, use `SET LOCAL` rather
than `SET` for `volvra.actor`. Sessions are shared between clients, so
a session-level setting can outlive the transaction and be attributed
to another client's work. The `db_user` column is unaffected.

## Injection resistance

pgVolvra generates compensating SQL from catalog metadata and row
images. Identifiers come from the catalog and are quoted; row images
are embedded as quoted literals.

The predicate argument is a WHERE fragment rather than a statement.
pgVolvra parenthesizes the fragment, refuses any predicate containing a
semicolon, a double hyphen, or a slash-star comment opener, and runs
the fragment with the caller's own privileges.

## Auditing

pgVolvra records every undo attempt, previewed or applied, in
`volvra.undo_log`. A trigger stamps the identity rather than trusting
the value supplied by the insert, and the table is append-only.

Retention runs are recorded in `volvra.retention_log`, and erasure
requests in `volvra.erasure_log`. Both ledgers exist so that lawful
removal is distinguishable from tampering.

## Verifying the software

pgVolvra installs as a file rather than a signed package, so
establishing provenance is the installer's responsibility. Verify the
checksum before running the file, read the file, and verify the
installed code afterwards with `volvra.fingerprint()`.

No signing key is published yet. Until one is, the checksum protects
against corruption and a careless mirror rather than against an
attacker who can replace both the file and the checksum.

## What pgVolvra does not protect against

The limits are worth stating plainly:

- A superuser, or an owner who disables the trigger, can stop capture
  and orphan the history. Monitor `volvra.health()`.
- pgVolvra records changes from the moment you cover a table, so nothing
  before that point can be recovered.
- The trigger tier shares fate with the database. Deploy the companion
  when the history must survive the database.
- Changes captured since the last seal are not covered by any seal.
- A seal proves that interference happened; a seal cannot undo the
  interference.
- History outgrows the table it protects, so retention must be
  scheduled.

## Next Steps

- The [Verifying History Integrity](integrity.md) document explains
  sealing and the code fingerprint.
- The [Erasing Data](erasure.md) document covers deletion requests.
- The [Monitoring](monitoring.md) document describes the health and
  preflight checks.
