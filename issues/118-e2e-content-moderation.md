# Issue #118: E2E Test Suite — Content Moderation

## Summary
Comprehensive E2E test coverage for the three-step content moderation pipeline (US-4.1) and age verification gate (US-4.2).

## Epic decomposition (2026-07-15)
The Feature-Completeness Pre-Check found this validation issue's audit blocked on **feature/production
work**, so #118 is run as an **epic** on integration branch `feat/118-e2e`. The feature punches are
spun out as child issues; #118 itself retains only the test-only remainder + the final audit
regeneration.

| Child | Owns | Punch(es) |
|-------|------|-----------|
| **#227** | `book.created` payload += `visibility_tier` | #1 (L4 code gap) |
| **#228** | moderation-funnel + age-gate operational telemetry | #3, #5 (L11) |
| **#229** | hide age-gated from the catalogue for authed-unverified users + reconcile US-4.2 to the hide-from-listings/block-on-detail model | supersedes §1 spine wording (#8) |
| **#118 core** (this issue, Level 1 — after the three merge) | registry-subscription assertion + US-4.1 §6 doc fix (#2); age-verify neg-emission test (#4); E2E unauth `/settings/age-verification` guard (#7); **regenerate the Test Audit → GREEN + Pre-Check → ✅** | #2, #4, #7 |

Punches #6 (post-verification access E2E) and #8's non-determinism were already resolved by #226's
`age-gate.spec.ts` rewrite. Design note: age-gated books are **hidden from listings** for unverified
users and **blocked-with-explanation on direct URL** (owner decision, #229) — this supersedes §1's
"frosted overlay + lock icon on spines" (which is why that wording is struck below).

## User Stories
US-4.1 (Three-Step Content Moderation Pipeline), US-4.2 (Age Verification for Gated Content)

## Goal
Validate the full moderation lifecycle: image classification, ISBN extraction, BISAC-based age gating, and the age verification flow that unlocks gated content.

## Scope Check
- Does this issue touch more than 3 controllers? No (UploadController, UserSettingsController, BookController).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (moderation + age gate are tightly coupled).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-4.1 — Three-Step Content Moderation Pipeline | upload → IdentifyBookJob → Moderation.run_pipeline → analyze → determine_visibility_tier → Books.create (books.ex:154) | ✅ pipeline + funnel telemetry driven; E2E via upload-pipeline.spec.ts | ✅ | built in-scope (epic #227/#228 + #118-core) |
| US-4.2 — Age Verification for Gated Content | PUT /api/settings/age_verification → AgeGate.enforce/2 403 → hide-from-listings (catalogue/search/shelf) + block-on-detail | ✅ deterministic age-gate.spec.ts + catalogue hiding + unauth guard | ✅ | built in-scope (epic #229 + #118-core; §1 spine superseded by #229) |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### 1. Playwright UI Tests
- **Upload happy path**: Upload image -> see "Identifying books..." spinner -> book appears on shelf
- **Not-a-book rejection**: Upload non-book image -> see "This doesn't appear to be a book" rejection message
- **ISBN not found**: Upload book image where ISBN extraction fails -> see "Could not identify a book ISBN"
- ~~**Age-gated book display**: Verify frosted overlay and lock icon on age-gated book spines~~ **SUPERSEDED by #229** — age-gated books are *hidden from listings* for unverified users (no spine overlay); a direct URL shows the `.age-gate` block. E2E for the hide-from-listings model lives in #229.
- **Age verification settings page**: Navigate to `/settings/age-verification` -> check "I confirm I am 18+" -> submit -> verify success message
- **Age-gated content access after verification**: After age verification, age-gated books display normally without overlay

### 2. Playwright Navigation & Visual Tests
- **Upload page auth guard**: Unauthenticated user at `/upload` sees login page
- **Age verification page auth guard**: Unauthenticated user at `/settings/age-verification` sees login page
- **Upload processing states**: Verify Loading/Success/Failure RemoteData transitions in the UI

### 3. API Endpoint Tests
- `POST /api/upload` — 202 Accepted with `image_id` and `status: "pending"`
- `POST /api/upload` — 401 without auth token
- `POST /api/upload` — 422 on validation failure
- `GET /api/upload/:image_id/status` — returns `pending`, `complete`, or `failed` with appropriate fields
- `GET /api/upload/:image_id/status` — 401 without auth
- `PUT /api/settings/age_verification` — 200 with `{ age_verified: true }`
- `PUT /api/settings/age_verification` — 401 without auth, 422 on invalid input
- `GET /api/books/:id` — 403 with `age_verification_required` for age-gated book when user not verified
- `GET /api/books/:id` — 200 for age-gated book when user is verified
- `GET /api/books/:id` — 200 passthrough for non-age-gated books

### 4. Database Assertion Tests
- Verify `op.books` record created with correct `visibility_tier` ("public" or "age_gated")
- Verify `op.book_editions` record created with resolved ISBN
- Verify `op.uploaded_images` record created with `expires_at` set to 30 days from upload
- Verify `op.users.age_verified` set to `true` after age verification
- Verify `op.books.visibility_tier` correctly maps adult BISAC codes (FIC005000, FIC027000, FIC069000) to "age_gated"
- Verify existing book lookup via `Books.find_existing/1` returns existing record instead of duplicate

### 5. Event Flow Tests
- `book.created` event emitted with correct payload (`isbn`, `title`, `visibility_tier`)
- `book.created` triggers `BookCreatedHandler` (price scraping enqueue)
- `book.created` triggers `AuthorDiscoveryHandler`
- `book.created` triggers `CacheInvalidationHandler`
- `book.created` triggers `DbtRefreshHandler`
- US-4.2: No events emitted for age verification (confirm no side effects)

### 6. Background Job Tests
- `IdentifyBookJob` enqueued on upload with correct args (`image_id`, `user_id`)
- Pipeline step 1: `call_vision("is_book", ...)` invoked with correct image URL
- Pipeline step 2: `call_vision("extract_isbn", ...)` invoked when step 1 returns "book"
- Pipeline step 3: BISAC code mapping via `subjects_to_bisac/1`
- Compound title expansion: " OR "-joined titles split and resolved independently
- Job success sets upload status to "complete", failure sets to "failed" with reason

### 7. External Service Tests
- Vision sidecar mock: `POST /classify` returns `"book"` / `"not_book"` / `"ambiguous"`
- Vision sidecar mock: `POST /extract` returns book candidates with ISBNs and titles
- HMAC auth header (`X-Internal-Token`) present on sidecar calls
- Circuit breaker (Fuse) on vision client: pipeline fails when fuse is blown
- Open Library / Google Books mock: ISBN resolution with fallback from one to the other
- Configurable mock via Application env (`TEST_TARGET`)

### 8. Storage Tests
- Image uploaded to `uploads/{image_id}` key pattern via `Stacks.Storage`
- Presigned URL generated for vision sidecar with 900s TTL
- Storage backend switches correctly: `Storage.Mock` in test env

### 9. Cache Tests
- `BookDetailCache` invalidated on `book.created` event via `CacheInvalidationHandler`

### 10. dbt Model Tests
- `int_book_detail_view` refreshed after placement creation
- `mart_enrichment_gaps` and `mart_platform_searchable` consume `int_book_detail_view`

### 11. Elm State Machine Tests
- `Page.Upload` init: empty form, no image selected
- `ImageSelected` -> stores file reference
- `SubmitUpload` -> sends `POST /api/upload`, transitions to Loading
- `GotUploadStatus` with `complete` -> Success with book list
- `GotUploadStatus` with `failed` -> Failure with rejection reason
- `Page.Settings.AgeVerification` init: checkbox reflects current `age_verified`
- `ToggleAgeVerification` -> toggles checkbox
- `SubmitAgeVerification` -> sends `PUT /api/settings/age_verification`
- `AgeVerificationUpdated (Ok _)` -> Success state, "Age verified" message

### 12. Metrics & Telemetry Tests
- Oban telemetry for `IdentifyBookJob`: enqueued, completed, failed counts
- Vision sidecar call latency tracked per endpoint
- Pipeline step pass/fail rates: step 1 rejection, step 2 failure, step 3 age-gate rates
- AgeGate enforcement counts: 403 blocked vs pass-through
- Age verification request counts: success vs failure

## Reviewer Context
- Vision sidecar endpoint mapping: `"is_book"` -> `/classify`, `"extract_isbn"` -> `/extract` (defined in `Stacks.AI.Client.endpoint_path/1`). Python sidecar paths must NOT change.
- BISAC codes for age gating: FIC005000, FIC027000, FIC069000.
- `AgeGate.enforce/2` is an inline plug call, not a router-level plug.

## Test Audit

_13-layer test-coverage map for this issue (13 layers × user story, happy/sad columns). Regenerated to reflect the **shipped** state after the epic's child issues (#227, #228, #229, #118-core) merged onto `feat/118-e2e`. This audit is GREEN: 0 ❌ / 0 ⚠️._

Last regenerated: 2026-07-15 (post-implementation, SHIPPED — Issue #118 epic)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

**Scope note:** Issue #118 covers two tightly-coupled user stories — US-4.1 (Three-Step Content Moderation Pipeline) and US-4.2 (Age Verification for Gated Content) — so the matrix is 13 layers × 2 US, happy/sad per cell (52 cells).

**Feature status:** both features are fully implemented and, as of the epic merge, fully instrumented. The moderation pipeline now (a) carries `visibility_tier` on the `book.created` event, (b) emits per-step funnel telemetry (`[:stacks, :moderation, :classification | :isbn_resolution | :tiering | :compound_expansion]`), and the age-gate path (c) emits `[:stacks, :age_gate, :enforce]` (`:passed`/`:blocked`) and age-verification request telemetry (`:success`/`:invalid`). Age-gated books are **hidden from listings** for unverified viewers (authenticated-but-unverified and anonymous alike) and **blocked-with-explanation on direct URL** (#229) — this supersedes the original §1 "frosted overlay + lock icon on spines" model, which is n/a-by-design.

### Framework-layer summary

| Layer | US-4.1 | US-4.2 |
|-------|--------|--------|
| Elixir | ✅ moderation_test 30, identify_book_job_test 17, upload_pipeline_test (incl. `book.created` payload+`visibility_tier`), moderation_telemetry_test (funnel counters), upload_dbt_test, registry_test (subscription-order) | ✅ age_gate_test 8, user_settings_controller_test age-verification 6 (incl. neg-emission), age_gate_telemetry_test (enforce/request counters), book_controller_test age-gate ~6, catalogue_controller_test (authed-unverified hiding), upload_cache_test age-gate 2 |
| Elm unit | ✅ UploadTest.elm (60+) | ✅ SettingsTest.elm AgeVerification (6) |
| Elm program | ✅ Page/UploadProgramTest.elm (upload_age_gated / _not_a_book / _isbn_rejection) | ✅ AgeVerification unit + E2E drive (settings.spec.ts + age-gate.spec.ts) |
| Python | ✅ test_analyze 10, test_classification 7, test_extraction 24, test_auth 10 | n/a — vision not involved in age verification |
| E2E | ✅ upload-pipeline.spec.ts (happy / not-a-book / isbn-not-found / auth guard); **age-gate.spec.ts:31** deterministically drives both sides — unverified→hidden-from-catalogue + `.age-gate` on direct URL, verified→content | ✅ settings.spec.ts verify flow + post-verification via age-gate.spec.ts; **settings.spec.ts:499** unauth `/settings/age-verification` → login guard. Spine frosted-overlay **superseded by #229** (hide-from-listings; catalogue hiding asserted catalogue_controller_test.exs:167/178) |
| dbt | ✅ stg_books `visibility_tier` accepted_values + int_book_detail_view (upload_dbt_test / schema.yml) | n/a — age verification triggers no dbt refresh |

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **33** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **19** |

52 cells (13 × 2 × happy/sad). The four baseline gaps (1 ❌ + 3 ⚠️) all flipped to ✅ on the child merge: L4 US-4.1 happy (`book.created` += `visibility_tier`, #227), L4 US-4.2 sad (neg-emission, #118-core), L11 US-4.1 (moderation telemetry, #228), L11 US-4.2 (age-gate/verification telemetry, #228). **0 ❌ / 0 ⚠️ — GREEN.**

### Changed audit cells

**Layer 4 — Event Flow & Lifecycle**
- US-4.1 happy: ✅ **RESOLVED (#227)** — `Books.create/1` emits `payload: %{isbn:, title:, visibility_tier:}` (books.ex:182-185); asserted upload_pipeline_test.exs:1164 (public → :1179) + :1184 (age_gated → :1200). Handler subscription pinned (#118-core): registry_test.exs:21 asserts `[BookCreatedHandler, AuthorDiscoveryHandler, CacheInvalidationHandler]`; US-4.1 §6 doc corrected.
- US-4.2 sad: ✅ **RESOLVED (#118-core)** — user_settings_controller_test.exs:77 "emits no domain event and enqueues no job" (event_log count unchanged + `all_enqueued() == []`).

**Layer 11 — Operational Metrics**
- US-4.1: ✅ **RESOLVED (#228)** — moderation_telemetry_test.exs: classification (:62/:72/:83), isbn_resolution (:98/:108), tiering (:123/:134), compound_expansion (:157). Dashboard *visualization* tracked in #231.
- US-4.2: ✅ **RESOLVED (#228)** — age_gate_telemetry_test.exs: enforce `:passed`/`:blocked` (:50/:64, no-emit :75/:84) + verification `:success`/`:invalid` (:97/:112/:127).

**E2E framework rows**
- Post-verification access: ✅ **RESOLVED (#226)** — age-gate.spec.ts:31 (unverified→hidden+gate, verified→content, state-owning/deterministic).
- Unauth settings guard: ✅ **RESOLVED (#118-core)** — settings.spec.ts:499.
- Spine frosted-overlay: **SUPERSEDED (#229)** — hide-from-listings model; catalogue hiding asserted catalogue_controller_test.exs:167 (verified sees) + :178 (unverified hidden, total accurate :193).

### Punch list (SHIPPED — 8 of 8 resolved)

| # | Cell | Child | Closed by (file:line) |
|--:|------|-------|-----------------------|
| 1 | L4 US-4.1 happy | #227 | books.ex:182-185 + upload_pipeline_test.exs:1164/:1184 |
| 2 | L4 US-4.1 doc/impl | #118-core | registry_test.exs:21 + US-4.1 §6 doc |
| 3 | L11 US-4.1 | #228 | moderation_telemetry_test.exs (:62–:157) |
| 4 | L4 US-4.2 sad | #118-core | user_settings_controller_test.exs:77 |
| 5 | L11 US-4.2 | #228 | age_gate_telemetry_test.exs (:50–:127) |
| 6 | E2E post-verification | #226 | age-gate.spec.ts:31 |
| 7 | E2E unauth guard | #118-core | settings.spec.ts:499 |
| 8 | E2E non-determinism + spine | #226 / #229 | age-gate.spec.ts:31 (determinism); spine SUPERSEDED → catalogue_controller_test.exs:167/:178 |

### Verdict

**GREEN — audit resolved; #118 implementation shipped.** 13-layer × 2-US matrix: **33 ✅ · 0 ⚠️ · 0 ❌ · 19 n/a** (each n/a rationale'd). Both named stories built end-to-end + validated. Epic decomposition delivered: #227 (event payload), #228 (operational telemetry), #229 (hide-from-listings, superseding spine-overlay), #118-core (registry assertion + US-4.1 §6 doc + neg-emission + unauth E2E guard + this regen). The L11 counters are **emitted, exposed, and firing-tested here**; their **dashboard visualization** is tracked in the **#231 observability epic** and merges into the same PR.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local` (mock services)
- [ ] No flaky tests — vision mock responses are deterministic
- [ ] `just verify` passes
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires moderation pipeline implementation, age gate plug, vision sidecar mock.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
