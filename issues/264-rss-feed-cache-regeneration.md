# Issue #264: US-6.1 RSS — real feed cache + event-driven regeneration

## Summary
Build a real feed-cache store so `RegenerateFeedJob` **writes** generated Atom XML on a placement
change and `FeedController` **reads** it (with on-miss fallback + cache-fill), replacing today's
generate-fresh-on-every-request behaviour. This gives the event-driven regeneration and
ETag-cache-hit-rate that #119 §9/§12 assert but which currently have nothing behind them.

## User Stories
- **US-6.1** — RSS/Atom feed for a platform-visible bookshelf (feed cache + event-driven
  regeneration). Implementation issue spun out of #119's pre-check.

## Goal
- A persisted feed-cache row per bookshelf holds `{atom_xml, etag, updated_at}`.
- `RegenerateFeedJob` upserts that row (keyed by `bookshelf_id`) instead of discarding its result.
- `FeedController` serves the stored XML+etag on a hit; on a miss it generates, fills the cache, and
  serves — preserving the existing ETag/`304`/`Cache-Control: public, max-age=300` behaviour and the
  `404`/`403` paths.
- Invalidation stays event-driven (already wired): `placement.created/moved/removed` re-enqueues the
  job which rewrites the row.
- The cache is user-linked (bookshelf → user) and **fully reachable by erasure**.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- More than 3 controllers? **No** — 1 controller modified (`FeedController`), 0 added.
- More than 2 new endpoints? **No** — 0 new endpoints (existing `GET /api/feeds/:user_id/:bookshelf_name`).
- More than ~300 lines of production code? **No** — hand-written production code is ~120 LOC
  (proto message + `persisted.exs` entry ~40, cache read/write helpers ~40, worker change ~15,
  controller change ~20, deletion Multi step ~10). **Caveat:** the new table is a **persisted proto
  table**, so `mix proto.sync` regenerates an Ecto schema (`lib/stacks/gen/…`), a migration, and
  `ProtoJSON.Gen`. Those generated files inflate the *diff* but are not hand-authored LOC and must
  not be edited by hand. Still within limits.
- Combines unrelated concerns? **No** — one concern (feed cache store + its read/write/erasure).

**Verdict: within limits — no split.** One flag: this is a non-trivial feature with a
cache-invalidation/staleness model, a proto-vs-migration decision, and an indirect-FK erasure path
the existing schema-guard does not cover. Per the orchestrator's design-pass-first rule, **plan step
1 is a short design doc** (see Technical Requirements) before any code.

## Wiring
Includes wiring — the route already exists; this issue changes what backs it (the feed a subscriber
pulls is now the cached artifact). User-facing on completion.

## Feature-Completeness Pre-Check
<!-- US-6.1's happy path: a platform-visible bookshelf serves a valid Atom feed. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-6.1 (feed served) | `core_web/router.ex:120` → `feed_controller.ex:21` → `feeds.ex:26` `generate_atom/2` → Atom XML + etag | ⬜ to verify (re-drive after cache read/write lands) | 🟡 partial | Serving is BUILT (generate-fresh). The **cache** half is not: `regenerate_feed_job.ex:24-30` generates then **discards** — no store, no cache read. Build the cache in-scope (this issue). |

Verdict: ✅ implemented (built + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing.

**Finding (verified 2026-07-20):** the *serving* path is complete and tested; the *cache* is a no-op.
`Stacks.Workers.RegenerateFeedJob.perform/1` (`apps/core/lib/stacks/workers/regenerate_feed_job.ex:24-30`)
calls `Feeds.generate_atom/2`, logs the etag, and returns `:ok` **without persisting anything**.
`FeedController.show` (`feed_controller.ex:22`) regenerates fresh on every request. The event wiring
IS built and registered: `placement.created/moved/removed` → `Stacks.Feeds.Handlers.PlacementHandler`
(`feeds/handlers/placement_handler.ex`, registered `stacks/events/registry.ex:47,51,55`) → enqueues
`RegenerateFeedJob`. So event-driven regeneration and the ETag-cache-hit-rate #119 wanted have
nothing to hit. This issue makes the job write and the controller read a real store — no 🟡/❌ story
is deferred.

## Technical Requirements

### 0. Design pass FIRST (plan step 1 — required before code)
A short design doc (`plans/264-*-design.md`) resolving:
1. **Proto vs migration.** New persisted `op.*`/`cache.*` tables in this repo go through proto
   codegen (CLAUDE.md "Proto Codegen"; `proto/persisted.exs` + `mix proto.sync` generate the Ecto
   schema, dbt staging, and migration). A hand-written migration would drift and fail
   `mix proto.sync --check` in CI. **Recommendation: proto path.** Add a `FeedCacheEntry` message
   (new `proto/stacks/infra/v1/feed_cache.proto`, mirroring `infra/v1/book_cache.proto`) and a
   `persisted.exs` entry with `migration_exists: false` (proto.sync generates the migration; flip to
   `true` after), `skip_dbt: true` + `dbt_grant: false` (derived cache stays out of the warehouse —
   the `isbn_resolver_cache`/`title_search_cache` precedent, `persisted.exs:86-147`).
2. **Schema prefix / user-link.** Unlike the ISBN/title caches (no user data), this cache holds a
   user's shelf content, so it needs a user path: column `bookshelf_id` (FK → `op.bookshelves.id`,
   **`ON DELETE CASCADE`**, unique — one cache row per bookshelf). Decide `op` vs `cache` schema
   prefix; recommend **`op`** (user-operational data subject to erasure), `skip_dbt: true`.
3. **Staleness / invalidation model.** Cache is authoritative once written; a placement change
   re-enqueues the job (already wired) which upserts. Fallback generation on a miss also fills the
   cache. Note: `generate_atom/2`'s etag is a pure MD5 of the XML, so a re-render of unchanged data
   is a stable etag (no false 200s) — document that the stored etag == generated etag so `304`
   still works across a cache-fill.

### 1. Feed cache store
- Fields: `bookshelf_id` (binary_id, FK → `op.bookshelves`, `on_delete: :delete_all`, unique),
  `atom_xml` (text, not null), `etag` (text, not null), plus standard `created_at/updated_at`.
- Defined via proto (see §0), NOT a hand-written migration.

### 2. `RegenerateFeedJob` writes the cache
- On `{:ok, xml, etag}` from `generate_atom/2`, **upsert** the cache row on `bookshelf_id`
  (`on_conflict: :replace` for `atom_xml`, `etag`, `updated_at`). The job already resolves the
  bookshelf; add a `bookshelf_id` lookup (or thread it through). Keep `{:error, :not_public}` →
  `:ok` (skip) and `{:error, :not_found}` → `{:cancel, …}`. Idempotent: two runs of the same data
  leave one row with the same etag.

### 3. `FeedController` reads the cache
- On request: look up the cache row by `(user_id, bookshelf_name)` → `bookshelf_id`.
  - **Hit:** serve stored `atom_xml` + `etag`; keep `If-None-Match` → `304`, `Content-Type:
    application/atom+xml`, `Cache-Control: public, max-age=300`.
  - **Miss:** call `generate_atom/2`, write the cache (or enqueue the job), serve the fresh result.
  - Preserve `404` (not found) and `403` (not platform-visible) exactly.
- Prefer a `Stacks.Feeds` API (`get_cached/2`, `put_cache/3` or `regenerate/2`) so the controller
  and worker share one path and the controller stays thin.

### 4. Invalidation (already wired — verify, don't rebuild)
- `PlacementHandler` → `RegenerateFeedJob` enqueue is built and registered. Confirm the moved-event
  dual-shelf regen still rewrites both cache rows.

### 5. GDPR — REQUIRED (gdpr-review lens embedded below)
The cache stores a user's shelf content (Atom XML derived from placements of a platform-visible
bookshelf). It is **personal data** (user-linked, user-authored titles/notes may appear in summaries)
even though derived from platform-visible shelves. Erasure MUST remove it.

**gdpr-review verdict: CONCERNS → resolved in-scope (must ship with the erasure step + test).**

| Change (file:line) | Data class | Erasure | Export | Leak (event/audit/dbt) | Gate | Verdict |
|--------------------|-----------|---------|--------|------------------------|------|---------|
| new `feed_cache` table (`bookshelf_id`, `atom_xml`, `etag`) | personal (derived, user-linked) | **Explicit Multi step `:delete_feed_cache` in `deletion.ex` scoped to `bookshelf_ids`, ordered BEFORE `:delete_bookshelves`; belt-and-suspenders `ON DELETE CASCADE` on the FK** | n/a — justified (derived/regenerable; the underlying placements+bookshelves are already in `export_user_data/2`, `export.ex:82-84`) | none — `skip_dbt: true` keeps it out of `wh`/staging; not written to `event_log`/`audit` | public feed route, no new gate (unchanged `403` for non-platform shelves) | **P0 if erasure omitted → fixed in-scope** |

**Key erasure finding — the existing schema-guard does NOT cover this table.** The guard
(`deletion_test.exs:388-455`) only scans `op.*` FKs whose target is `op.users`. `feed_cache`'s FK is
`bookshelf_id → op.bookshelves`, so the guard will pass while never inspecting it. Erasure therefore
CANNOT rely on the guard; it needs (a) an explicit `:delete_feed_cache` Multi step and (b) a
dedicated regression test proving a deleted user leaves zero `feed_cache` rows. Optionally extend the
guard to also flag `op.*` tables with a `bookshelf_id` FK lacking cascade (P2 future-proofing —
in-scope if cheap, else spin-out).

### GDPR-erasure plan (concrete)
1. Add `Stacks.Feeds.FeedCacheEntry` alias to `deletion.ex`.
2. Add Multi step `:delete_feed_cache` (before `:delete_bookshelves`):
   `repo.delete_all(from fc in FeedCacheEntry, where: fc.bookshelf_id in ^bookshelf_ids)`.
3. Add the count to `preview_user_data/1` so operator dry-run reports it.
4. FK `ON DELETE CASCADE` as a second line of defence (delete_all fires DB-level cascade).
5. Regression test in `deletion_test.exs`: seed a platform bookshelf + cached feed, erase the user,
   assert `feed_cache` rows for their bookshelves == 0.

## Reviewer Context
<!-- Non-obvious conventions reviewers need. -->
- **Toolchain:** run Elixir tooling via `just run` (never bare `mix` — CLAUDE.md pinned-toolchain).
- **Proto codegen is the source of truth for persisted tables.** The migration + Ecto schema are
  **generated** by `mix proto.sync` from `proto/persisted.exs`; do NOT hand-edit `lib/stacks/gen/…`
  or hand-write the migration. `mix proto.sync --check` runs in CI and fails on drift. After the
  proto/persisted change: `just run mix proto.sync`, then `just run just verify` (regenerates + runs
  test-dbt/lint-dbt; a bare `mix test` green does NOT catch `seeds.exs`/`sources.yml`/dbt gaps —
  MEMORY "verify catches NOT NULL / schema gaps").
- **Migration safety + fresh-DB gate will run.** New table + FK → the fresh-DB rebuild path executes;
  ensure the generated migration is idempotent and the FK/indexes are correct. DB-role LOGIN gotcha
  after fresh-DB (CLAUDE.md) may need `ALTER ROLE stacks_dbt WITH LOGIN`.
- **Cache stays out of the warehouse:** `skip_dbt: true` + `dbt_grant: false` (matches
  `isbn_resolver_cache`/`title_search_cache`, `persisted.exs:86-147`). This is also the GDPR
  warehouse-leak guard — do not add a `stg_feed_cache` model.
- **Schema-guard blind spot:** `deletion_test.exs`'s guard only audits FKs to `op.users`; a
  `bookshelf_id` FK is invisible to it. Erasure coverage here is a dedicated test, not the guard.
- **ETag is a pure MD5 of the XML** (`feeds.ex:48`) — a stored-vs-freshly-generated etag matches for
  identical data, so `304` holds across a cache-fill. Store the etag alongside the XML; do not
  recompute divergently.
- Event handler is already registered (`stacks/events/registry.ex:47,51,55`) — invalidation is
  wired; this issue makes the enqueued job actually persist.

## Test Audit
<!-- FULL format — this spans layers. Legend: ✅ real | ⚠️ shallow | ❌ missing | n/a (reason). -->

**Framework-layer summary.** Backend feature (Elixir): a persisted cache table, one Oban worker,
one public controller, one event handler (existing), and a GDPR erasure step. No Elm/Modal/Rust
surface. Existing tests cover the *generate-fresh* world; none assert a cache read/write because none
exists yet. Baseline is mostly ❌ (the work queue).

**Coverage tally (baseline):** ✅ 3 (pre-existing, still valid) · ⚠️ 1 · ❌ 6 · n/a 6.

| Layer | Applies? | Baseline verdict (cite / gap) |
|-------|----------|-------------------------------|
| 1. API calls (`FeedController` cache-hit + miss-fill; `304`/`404`/`403`) | yes | ⚠️ `feed_controller_test.exs` covers 200/304/404/403 on the **generate-fresh** path only → need: serves **stored** XML on hit; **fills** cache on miss; etag/`304` correct across a cache-fill. |
| 2. Auth & middleware guards | yes | n/a — public route by design (unchanged); non-platform `403` covered by L1. |
| 3. DB interactions (cache read/write, **upsert** on `bookshelf_id`, unique) | yes | ❌ no `feed_cache` table exists → need: upsert replaces on conflict; one row per bookshelf; read-by-bookshelf. |
| 4. Event flow / lifecycle (placement change → regen → cache updated) | yes | ⚠️→❌ `placement_handler_test.exs` asserts **enqueue** only; ❌ end-to-end "placement change ⇒ cache row rewritten" (incl. moved dual-shelf) is missing. |
| 5. Oban jobs (`RegenerateFeedJob` **writes** cache; idempotent; skip/cancel paths) | yes | ⚠️ `regenerate_feed_job_test.exs` asserts `:ok`/`:cancel` but **not** a cache write (nothing to write today) → need: writes/upserts the row; idempotent (2 runs ⇒ 1 row, same etag); non-public ⇒ no row; not-found ⇒ `:cancel`. |
| 6. External service calls | no | n/a — no external calls. |
| 7. Storage | yes | n/a — DB row store, covered under L3 (no blob/object storage). |
| 8. Cache (cache-hit behaviour — the thing #119 §12 wanted) | yes | ❌ need: 2nd request served from store without re-generating (assert generate not re-invoked / row unchanged); hit-rate observable. |
| 9. dbt models | yes | n/a — `skip_dbt: true` (derived cache excluded from warehouse; GDPR). |
| 10. Elm state machine | no | n/a — no frontend surface. |
| 11. Operational metrics | yes | n/a — covered by SLO gate (`scripts/check-slo-gate.sh`); cache-hit-rate metric assertion belongs to #119 §12. |
| 12. Performance & usability | yes | n/a — covered by SLO gate. |
| 13. Cost tracking | no | n/a. |
| **GDPR erasure (cross-cutting)** | yes | ❌ need: erasing a user removes their `feed_cache` rows (`deletion_test.exs`); `preview_user_data/1` counts them. |

### Punch list (baseline — the work queue)
1. **L3/L5** `regenerate_feed_job_test.exs` — job upserts a `feed_cache` row (xml+etag) for a
   platform bookshelf; second identical run ⇒ 1 row, unchanged etag (idempotent); owner-visibility ⇒
   no row; missing bookshelf ⇒ `:cancel`, no row.
2. **L1/L8** `feed_controller_test.exs` — with a pre-seeded cache row the response is the **stored**
   XML (assert body == stored `atom_xml`) and its etag; `If-None-Match` ⇒ `304`; a **miss** (no row)
   generates, **fills** the cache (row now exists), and serves 200.
3. **L4** `feeds/handlers/placement_handler_test.exs` (or a feeds integration test) — a
   `placement.created` on a platform shelf, drained through Oban, leaves the cache row updated;
   `placement.moved` rewrites **both** source and destination cache rows.
4. **GDPR** `gdpr/deletion_test.exs` — seed platform bookshelf + cached feed; `delete_user_data/1`
   ⇒ 0 `feed_cache` rows for the user's bookshelves; `preview_user_data/1` reports the count.
5. **(optional, P2)** extend the schema-guard to flag `op.*` `bookshelf_id` FKs lacking cascade, or
   spin out.

**Verdict: RED (baseline).** 6 ❌ / 1 ⚠️ open; GREEN when every applicable cell is ✅ and the punch
list is cleared. Regenerate this audit as the final step.

## Definition of Done
- [ ] `feed_cache` table exists via proto codegen (proto message + `persisted.exs` entry, generated
      migration + Ecto schema), `skip_dbt`/`dbt_grant: false` — evidence: `just run mix proto.sync`
      clean + `mix proto.sync --check` green; migration applied on fresh DB.
- [ ] `RegenerateFeedJob` upserts the cache; idempotent — evidence: `regenerate_feed_job_test.exs`
      "upserts feed_cache row / idempotent" (punch #1).
- [ ] `FeedController` serves cache hit + fills on miss, ETag/`304`/`404`/`403` preserved — evidence:
      `feed_controller_test.exs` cache-hit + miss-fill tests (punch #2).
- [ ] Event-driven invalidation updates the cache end-to-end (incl. moved dual-shelf) — evidence:
      `placement_handler_test.exs`/feeds integration test (punch #3).
- [ ] **GDPR erasure removes feed-cache rows** — evidence: `gdpr/deletion_test.exs` "erasing a user
      deletes their feed_cache rows" + `preview_user_data/1` counts them (punch #4).
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for US-6.1** — feed served from the cache on a
      live stack (curl the feed, change a placement, re-curl and observe the updated entry); the 🟡
      cache half built in-scope, nothing de-scoped.
- [ ] Every behaviour has a validation path — unit/integration per punch list; live-drive the
      placement-change→cache-update loop locally (no browser E2E needed — backend/feed surface).
- [ ] Tests written and passing (`just run mix test` for `apps/core`).
- [ ] Standards compliance verified (`just run just verify` passes — incl. proto.sync --check,
      test-dbt, migration/fresh-DB gate, credo, sobelow).
- [ ] **Test audit (embedded above) is GREEN** — 0 ❌, 0 ⚠️; regenerated as the final step.
- [ ] **`gdpr-review` skill re-run on the final diff = PASS** — erasure step present, no warehouse
      leak, export exclusion justified.
- [ ] **`completion-audit` skill passed on the integrated branch** — cite the run.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — cache-hit observed
      live (2nd request served from store; hit-rate #119 §12 has something to measure); logs clean;
      tracking regenerated. Each item cited with an evidence token.

## Dependencies
- **#119** (`issues/119-e2e-metrics-rss.md`) — feeds E2E/metrics; this issue provides the cache that
  #119 §9/§12 (event-driven regeneration + ETag-cache-hit-rate) assert against.

## Agent Assignment
- **elixir-agent** — Feeds context (cache read/write), `RegenerateFeedJob`, `FeedController`.
- **database-agent** — proto `persisted.exs` entry + `FeedCacheEntry` message, generated migration,
  FK `ON DELETE CASCADE`, unique index; fresh-DB gate.
- **security-agent (GDPR)** — `:delete_feed_cache` Multi step + `preview_user_data/1` count + erasure
  regression test; gdpr-review lens.
- **contract-reviewer** — proto/schema-contract review (new message, `buf lint`/`buf breaking`,
  additive-only).

## Progress Notes
[Updated by agents during execution.]
</content>
</invoke>
