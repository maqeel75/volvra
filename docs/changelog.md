# Release Notes

All notable changes to Volvra are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/), and Volvra
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Support for multi-master clusters, through the `capture_replicated`
  setting and `volvra.set_capture_replicated`. PostgreSQL does not fire
  an ordinary row trigger for rows applied by replication, so a node
  would otherwise record only what was written to it. The setting
  defaults to off, which leaves single-node behaviour unchanged, and
  `volvra.preflight` warns when a database receives replicated changes
  without capturing them. Verified on a two-node Spock cluster, where
  a node reverted a change made on its peer.
- A critical preflight finding when a Volvra table is in a publication
  or replication set, which would make two nodes write the same
  history identifiers.

### Added

- Row-level undo for INSERT, UPDATE, and DELETE, selectable by table,
  time window, transaction, actor, database role, or SQL predicate.
- Transaction-scoped undo, so a mistaken migration can be reverted
  across every table the migration touched.
- Forward replay, the mirror of undo, which reapplies changes in their
  original direction oldest first. A database restored from a backup
  that predates changes still held in history can be carried forward
  over them. Replay shares the conflict guard, the blast-radius cap,
  the advisory locks and the single transaction with undo, and refuses
  any row that no longer holds the image captured before its change.
- Row history with two recorded identities, an application-declared
  actor and an authenticated database principal.
- A conflict guard that refuses to overwrite a change made after the
  mistake, with an option to skip conflicting rows instead.
- A blast-radius cap on the number of rows a single undo may affect.
- TRUNCATE capture, with block and allow modes as alternatives.
- Support for partitioned tables, covered through the parent, so one
  undo reverts rows in every partition. `volvra.cover_partitions`
  attaches TRUNCATE capture to partitions, which PostgreSQL does not
  propagate on its own, and `volvra.maintain` reconciles partitions
  added later.
- Coverage that survives ALTER TABLE RENAME and SET SCHEMA, because a
  covered table is identified by its relation identifier rather than
  by name.
- Publications created with `publish_generated_columns = stored` on
  PostgreSQL 18 and later. Without it, a covered table with a
  generated column becomes impossible to update once the companion is
  set up, because `REPLICA IDENTITY FULL` puts generated columns in
  the replica identity and PostgreSQL 18 refuses to update a table
  whose replica identity contains unpublished generated columns.
- Conflict guards that ignore generated columns. A guard compared a
  derived value that logical replication does not send, so history
  restored from an archive conflicted on every row of any table with a
  generated column, for undo as well as replay.
- An extension upgrade path. `extension/build.sh` emits an upgrade
  script for every version in `extension/upgrade-from.txt`, so
  `ALTER EXTENSION UPDATE` works from any released version.
- `tools/snapshot-schema.sh`, which freezes a release's install script
  as the fixture the next release's upgrade test runs against.
- Schema-wide coverage with `volvra.enable_all`, plus coverage gap
  reporting with `volvra.uncovered`.
- Monthly partitioning of the history, with partition-dropping
  retention and per-table retention policies.
- A single maintenance function that extends partitions, applies
  retention, and seals the history.
- Health, preflight, status, storage, and activity functions,
  including a publication drift check that reports covered tables the
  companion publication does not carry.
- Tamper evidence through a SHA-256 seal chain over ranges of the
  history, with verification that distinguishes lawful erasure and
  retention from tampering.
- A code fingerprint that detects a function altered after install.
- Per-subject erasure, with redaction by default and hard deletion for
  when a primary key is itself personal data.
- Column exclusion, so nominated columns never reach the history.
- The `volvra-companion` durable tier, which archives change data to
  customer-owned storage through a logical replication slot, with
  archive verification, restore, and a slot-lag safety valve.
- A command line tool that previews, confirms, and then applies,
  distributed as a single Go binary with no runtime dependencies. The
  tool sends every user-supplied value as a bind parameter, exits 2
  when `preflight` or `verify` finds something wrong, and reads a
  trailing `ago` in a time so that `--since '10 min ago'` works.
- Optional `CREATE EXTENSION` packaging for self-hosted users,
  generated from the same SQL file.

### Notes

- Volvra requires PostgreSQL 14 or later and no PostgreSQL extensions.
- Volvra has not yet been validated against a live managed provider
  instance.
- No release signing key is published yet.
