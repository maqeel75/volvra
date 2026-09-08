# Release Notes

All notable changes to Volvra are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/), and Volvra
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Row-level undo for INSERT, UPDATE, and DELETE, selectable by table,
  time window, transaction, actor, database role, or SQL predicate.
- Transaction-scoped undo, so a mistaken migration can be reverted
  across every table the migration touched.
- Row history with two recorded identities, an application-declared
  actor and an authenticated database principal.
- A conflict guard that refuses to overwrite a change made after the
  mistake, with an option to skip conflicting rows instead.
- A blast-radius cap on the number of rows a single undo may affect.
- TRUNCATE capture, with block and allow modes as alternatives.
- Schema-wide coverage with `volvra.enable_all`, plus coverage gap
  reporting with `volvra.uncovered`.
- Monthly partitioning of the history, with partition-dropping
  retention and per-table retention policies.
- A single maintenance function that extends partitions, applies
  retention, and seals the history.
- Health, preflight, status, storage, and activity functions.
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
- A command line script that previews, confirms, and then applies.
- Optional `CREATE EXTENSION` packaging for self-hosted users,
  generated from the same SQL file.

### Notes

- Volvra requires PostgreSQL 14 or later and no PostgreSQL extensions.
- Volvra has not yet been validated against a live managed provider
  instance.
- No release signing key is published yet.
