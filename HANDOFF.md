# Project Handoff — "Undo for Postgres" (working name: Volvra)

*Paste this into Cowork to continue. It captures every decision and a build-ready spec for v0 so you can start coding immediately.*

---

## What the product is

A **row-level "oops button" and time machine for PostgreSQL**: undo a specific bad `UPDATE` / `DELETE` / migration by reverting *exactly the rows that changed* — not a whole-cluster PITR rollback — plus view any row's full history and who changed it.

It is the simple, shippable distillation of a longer exploration (which started at "improve pgBackRest" and passed through an AI backup platform and cross-tier PITR). We deliberately narrowed to this one sharp thing.

## Why this one

- Fills a genuine ~20-year-old gap — Postgres still has no Oracle-style Flashback.
- Simple enough to explain in one sentence.
- Works for **all users including managed cloud** (RDS, Aurora, Cloud SQL, Supabase, Neon) — which physical-WAL backup tools cannot.

## Decisions (locked)

1. **Not a C extension.** Core ships as **plain in-database SQL** (schema + functions + triggers), installs with no superuser on any managed provider. Optional `CREATE EXTENSION` packaging for self-hosted users only.
2. **Two capture mechanisms:**
   - *Trigger-based* (synchronous, in-DB, simple) — the everyday oops button. Shares fate with the DB (not a disaster backup).
   - *Logical-decoding companion* (async, writes to isolated customer-owned storage) — durable tier; survives the DB dying. Later phase.
3. **Security is the design center** (the tool can modify prod data):
   - Reading history is open; **changing data is privileged, preview-by-default, permission-separated, blast-radius-capped, and audited.**
   - Tamper-evident history (optional hash-chaining), retention + right-to-erasure controls.
   - AI is an optional accelerant that only *proposes* an undo; execution is deterministic SQL a human confirms.
4. **Honest constraint we lead with, not hide:** protects *going forward*, not retroactively — must be enabled before the accident. So one-command setup is the whole job.
5. **Commercial tiers deferred.** Architecture split (in-DB first, companion later) is decided; the actual free/paid wall is to be discovered from real usage. Open source is a live option.

## Naming (open — your action)

- Best real word: **Torna** ("it returns," Italian) — needs GitHub/PyPI check.
- Best ownable invented word: **Volvra** ("roll back") — cleanest of everything tested; used as working name here.
- **Next step (yours):** run Volvra + Torna through domain + USPTO trademark (class 9/42) + GitHub/npm/PyPI checks, then pair the survivor with a tagline like *"undo for Postgres."*

## Prior artifacts (carry over if useful)

- `amber-proposal.md` — full feature list + security options (product name pending).
- `FEATURES.md` — production feature spec with table-stakes/differentiated/unique tags.
- `pgvault.tar.gz` — earlier Go engine skeleton + cross-tier PITR resolver (different, heavier direction — reference only).

---

## BUILD NEXT: v0 SQL proof (this is the task for Cowork)

Goal: a runnable `volvra` schema that demonstrates enable → capture → preview → undo on a local Postgres, with the safety rails in place. Pure SQL / PL/pgSQL, no superuser, no C.

### Objects to build

**Schema:** `volvra`

**History table** `volvra.change_log`:
`id bigserial pk, table_name text, op char(1)  -- I/U/D, pk jsonb, old_row jsonb, new_row jsonb, actor text, txid bigint, ts timestamptz default clock_timestamp()`
- Append-only: revoke UPDATE/DELETE from normal roles; guard trigger to block edits (tamper-resistance).

**`volvra.enable(target regclass)`**
- Attaches an `AFTER INSERT OR UPDATE OR DELETE` row-level trigger that writes before/after images to `change_log`.
- Actor = `current_user`, overridable by app context via `current_setting('volvra.actor', true)`.
- Note: triggers see the full `OLD` row directly, so `REPLICA IDENTITY FULL` is NOT needed for the trigger tier (it *is* needed later for the logical-decoding companion — document that distinction).

**`volvra.disable(target regclass)`** — drop trigger; keep history by default.

**`volvra.history(target regclass, pk jsonb)`** — return every version of a row over time (ordered), with actor + ts.

**`volvra.preview_undo(target regclass, from_ts timestamptz, to_ts timestamptz)`**
- Returns the affected change set + the generated compensating SQL + row count. **Does not execute.**

**`volvra.undo(target regclass, from_ts timestamptz, to_ts timestamptz, confirm boolean default false)`**
- `confirm=false` → behaves like preview.
- `confirm=true` → applies compensating DML in a **single transaction**.
- Compensating logic, applied in **reverse chronological order** over the window:
  - inverse of `INSERT` → `DELETE` by pk
  - inverse of `DELETE` → `INSERT` old_row
  - inverse of `UPDATE` → `UPDATE` back to old_row
- The undo's own writes are themselves captured (so an undo can be undone).
- **Blast-radius guard:** raise an exception if affected rows exceed a configurable cap (e.g. `volvra.max_undo_rows`, default 10000) unless explicitly overridden.

**Roles:** `volvra_viewer` (read history), `volvra_operator` (may undo), `volvra_admin` (configure). Consider `SECURITY DEFINER` functions owned by a locked-down role so operators need no direct table grants.

### Acceptance test (prove it works)

1. `CREATE TABLE orders(...)`; insert rows; `SELECT volvra.enable('orders');`
2. Run a "bad" `UPDATE orders SET total = 0;` (no WHERE).
3. `SELECT volvra.preview_undo('orders', <t0>, now());` → shows the compensating UPDATEs.
4. `SELECT volvra.undo('orders', <t0>, now(), confirm => true);` → totals restored.
5. `SELECT * FROM volvra.history('orders', '{"id":1}');` → shows both versions + actor.
6. Undo the undo → confirm reversibility.

### Stretch (after v0 works)

- Predicate/row/txid-scoped undo (not just time window).
- Optional hash-chaining on `change_log` for tamper-evidence.
- Retention/purge function with configurable TTL.
- Then: the logical-decoding companion (external, durable, `REPLICA IDENTITY FULL`, slot-lag safety valve).
