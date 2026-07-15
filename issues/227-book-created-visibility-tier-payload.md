# Issue #227: Include `visibility_tier` in the `book.created` event payload

## Summary
The moderation pipeline computes a book's `visibility_tier` (`"public"` / `"age_gated"`) and
persists it on the `op.books` row, but the `book.created` domain event fans out with a payload of
`%{isbn, title}` only — omitting `visibility_tier`. Downstream consumers of `book.created` therefore
cannot see the age-gate decision on the event. Add `visibility_tier` to the payload.

## User Stories
US-4.1 (Three-Step Content Moderation Pipeline). Child of epic **#118**.

## Goal
`book.created` carries the moderation pipeline's age-gate decision, so every subscriber (and the
event_log record) can act on `visibility_tier` without a follow-up DB read. Proven by a test that
asserts the field is present for both a `public` and an `age_gated` book.

## Scope Check
- More than 3 controllers? **No** — zero controllers (context-layer event emit).
- More than 2 new endpoints? **No** — none.
- Exceeds ~300 LOC production? **No** — one payload map + any consumer that now reads the field (< 30 LOC).
- Combines unrelated concerns? **No** — single event-payload correctness fix.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only — a domain-event payload change consumed by existing
      handlers (`BookCreatedHandler`, `AuthorDiscoveryHandler`, `CacheInvalidationHandler`) and the
      `event_log`. No new route/UI.

## Feature-Completeness Pre-Check
US-4.1's happy path is **built** (verified against current code, feat/118-e2e). This issue closes a
*correctness gap within* that built story — the event payload — not a missing story. It is therefore
correctly scoped as a build-in-scope feature, not a validation punch.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-4.1 — Moderation pipeline | `upload_controller.ex:125` → `identify_book_job.ex:26` → `moderation.ex:55` → `call_vision("analyze")` `moderation.ex:83` → `determine_visibility_tier/1` `moderation.ex:402` → `store_book/3` `moderation.ex:386` → `Books.create/1` `books.ex:154` → **event emit `books.ex:182`** | ✅ pipeline logic covered by `moderation_test.exs` (30) + `identify_book_job_test.exs` (17); the emit is the specific gap | ✅ built (payload gap this issue closes) | build in-scope (this issue) |

Verdict: ✅ implemented · 🟡 partial · ❌ missing.

## Technical Requirements

### 1. Payload change
- In `Books.create/1` (`apps/core/lib/stacks/books.ex:182`), extend the `book.created` event payload
  from `%{isbn: edition.isbn, title: book.title}` to also include
  `visibility_tier: book.visibility_tier`.
- The value is already on the `book` struct at emit time (`Books.create/1` inserts the book with the
  tier set by `moderation.ex:461`), so no extra query is required.
- Mirror precedent: the upload-audit's Fix #5 added `visibility_tier` to the `placement.created`
  payload — follow the same shape/naming.

### 2. Consumers (verify no breakage; opportunistically use the field)
- `book.created` subscribers are `BookCreatedHandler`, `AuthorDiscoveryHandler` (no-op),
  `CacheInvalidationHandler` (`registry.ex:19-23`). Adding a field is additive — confirm each
  tolerates the larger payload (they pattern-match specific keys, so additive is safe).
- No consumer is *required* to change; this issue only guarantees the field is present.

### 3. Contract / warehouse surface
- `book.created` is written to `op.event_log`. `visibility_tier` is a **content classification, not
  personal data** (4-tier GDPR model → public) — safe for `event_log`, audit, and warehouse. Confirm
  the event-payload flow to any dbt staging of `event_log` does not choke on the new key (JSON
  payload column — additive keys are transparent).
- If an explicit event-payload schema/contract exists for `book.created`, update it in lockstep.

## Reviewer Context
- Event payloads are a cross-boundary **contract** — route to `contract-reviewer` in addition to
  `elixir-reviewer`.
- `visibility_tier` values are exactly `"public"` / `"age_gated"` (`books.ex:999`
  `validate_inclusion`).
- Precedent: `placement.created` already carries `visibility_tier` (upload-audit Fix #5,
  `shelving.ex` `lookup_book_visibility_tier/1` → placement event) — match that pattern.
- The moderation pipeline calls `/analyze` (not `/classify`+`/extract`); the tier is decided by
  `determine_visibility_tier/1` from BISAC codes `FIC005000 / FIC027000 / FIC069000`.

## Test Audit

_Compact-but-rigorous — Issue #227 is a **single-behaviour, backend event-payload correctness fix**
under a built story (US-4.1). Layer 4 (event flow) is the sole load-bearing layer; every other layer
is `✅ (existing, unchanged)` or `n/a`. Verified against `feat/118-e2e` 2026-07-15; every ✅ cites a
test read by grep/Read._

Legend: ✅ real · ⚠️ shallow · ❌ missing · n/a (reason)

### Feature status
`Stacks.Books.create/1` (`books.ex:154`) inserts the book (`visibility_tier` already on the struct),
inserts the edition, then emits in the `:emit_event` Multi step. Gap (source `books.ex:177-183`):
`payload: %{isbn: edition.isbn, title: book.title}` (`books.ex:182`) — no `visibility_tier`, though the
value is in scope. Fan-out `registry.ex:19-23`: `book.created => [BookCreatedHandler,
AuthorDiscoveryHandler, CacheInvalidationHandler]`, each keying on specific fields → additive-safe.
Lands in `op.event_log`; `stg_event_log.sql:11` selects `payload` as opaque JSON (no dbt change).
`visibility_tier` is content classification, not PII. Precedent: `placement.created` carries it (upload Fix #5).

### Framework-layer summary
| Layer | US-4.1 |
|-------|--------|
| Elixir | ✅ creation + tier persistence (`moderation_test.exs` 25, `identify_book_job_test.exs` 17); fan-out (`book_created_handler_test.exs` 5, `cache_invalidation_handler_test.exs` 6, `author_discovery_handler_test.exs` 4). **Gap:** payload omits `visibility_tier`. |
| Elm / Python / E2E | n/a — server-only event key; no frontend consumer, vision upstream, not Playwright-observable. |
| dbt | ✅ (unchanged) `stg_event_log.sql:11` opaque JSON. |

**Existing-test inventory (grep/read-verified):**
- `upload_pipeline_test.exs:1164` `test "book.created event emitted on book creation"` — asserts `payload["isbn"]`, `["title"]`, `aggregate_type == "book"`. **Extension target — no `visibility_tier`.**
- `upload_pipeline_test.exs:1242` `"no book.created event emitted on rejection"`; `:1304` `"…enqueues SubscriberWorker"`.
- `moderation_test.exs:41` `"stores book with public tier…"` (asserts `"public"`); `:51` `"…age_gated visibility_tier…"`.
- `book_created_handler_test.exs:9/:27/:39/:53/:65`; `cache_invalidation_handler_test.exs:20/:28`; `author_discovery_handler_test.exs:22` (no-op confirmed)/`:63`.
- `registry_test.exs` — 4 structural tests; does NOT pin the `book.created` handler tuple.

### Full audit table (13 layers × US-4.1, happy/sad)
| Layer | Happy | V | Sad | V |
|-------|-------|---|-----|---|
| 1 API | ✅ (unchanged) upload→create drives emit | ✅ | n/a | n/a |
| 2 auth | n/a context-layer emit | n/a | n/a | n/a |
| 3 DB write | ✅ `moderation_test.exs:41/:51` | ✅ | ✅ `upload_pipeline_test.exs:1242` | ✅ |
| **4 event** | ❌ **CODE GAP** `%{isbn,title}` only (`books.ex:182`); `:1164` asserts isbn+title. Add field + assert public AND age_gated. | ❌ | ✅ `:1242` rejection emits no `book.created` | ✅ |
| 5 Oban | ✅ `book_created_handler_test.exs:9`, `:1304` | ✅ | ✅ `book_created_handler_test.exs:27` | ✅ |
| 6 external | n/a vision upstream | n/a | n/a | n/a |
| 7 storage | n/a | n/a | n/a | n/a |
| 8 cache | ✅ `cache_invalidation_handler_test.exs:20/:28` | ✅ | n/a | n/a |
| 9 dbt | ✅ `stg_event_log.sql:11` opaque | ✅ | n/a | n/a |
| 10 Elm | n/a no consumer | n/a | n/a | n/a |
| 11 metrics | n/a no counter on key | n/a | n/a | n/a |
| 12 perf | n/a one map key | n/a | n/a | n/a |
| 13 cost | n/a local emit | n/a | n/a | n/a |

### Coverage tally
| ✅ (existing) | ⚠️ | ❌ | n/a |
|---|---|---|---|
| 9 | 0 | 1 | 16 |

26 cells (13 × happy/sad). Sole load-bearing cell: **L4 happy = ❌**.

### Punch list (baseline — 0 resolved)
| # | Cell | What's needed | Where |
|--:|------|---------------|-------|
| 1 | L4 US-4.1 happy | **CODE + TEST.** Add `visibility_tier: book.visibility_tier` to the payload (`books.ex:182`). Extend `upload_pipeline_test.exs:1164` to assert `payload["visibility_tier"] == "public"` + a companion age_gated assertion (via `Books.create/1` with `"visibility_tier" => "age_gated"`) so the test fails if the field is removed OR hard-coded. Mirror upload Fix #5. | `books.ex:182` + `upload_pipeline_test.exs:1164` |

_Optional hardening (not required for GREEN):_ `registry_test.exs` doesn't pin the exact `book.created` tuple; the three handler tests already confirm additive-safety.

### Verdict
**Baseline — 1 punch item (code gap + two-value assertion). Done when L4 happy is ✅.** Headline:
(1) `book.created` omits `visibility_tier` though the pipeline computes + persists it
(`moderation_test.exs:41/:51`) — same class as upload Fix #5; (2) additive-safe on every other axis
(handlers key on ISBN/`aggregate_id`; `stg_event_log.sql:11` opaque JSON); (3) one production line +
one/two assertions, value already in scope. Totals (grep): `upload_pipeline_test.exs` book.created
payload assertion blocks = **1** (line 1164, isbn+title only); `moderation_test.exs` **25**,
`identify_book_job_test.exs` **17**, handler suites 5/6/4.

## Definition of Done
- [ ] `book.created` payload includes `visibility_tier` (`books.ex:182`).
- [ ] `upload_pipeline_test.exs` asserts `payload["visibility_tier"]` for a **public** and an
      **age_gated** book (a test that fails if the field is removed or hard-coded).
- [ ] Feature-Completeness Pre-Check (above) remains ✅ for US-4.1.
- [ ] `just verify` passes (elixir + any dbt staging of `event_log` unaffected).
- [ ] Test audit (above) GREEN — L4 ✅, 0 ❌/⚠️.
- [ ] Meets the Completion Bar — event asserted (not assumed); no dangling reviewer findings.

## Dependencies
None. Foundational — merges first in the #118 epic (other children/tests depend on the enriched
payload being present). Integration branch: `feat/118-e2e`.

## Agent Assignment
elixir-agent (reviewers: elixir-reviewer + contract-reviewer).
