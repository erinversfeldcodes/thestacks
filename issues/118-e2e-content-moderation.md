# Issue #118: E2E Test Suite — Content Moderation

## Summary
Comprehensive E2E test coverage for the three-step content moderation pipeline (US-4.1) and age verification gate (US-4.2).

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

## Technical Requirements

### 1. Playwright UI Tests
- **Upload happy path**: Upload image -> see "Identifying books..." spinner -> book appears on shelf
- **Not-a-book rejection**: Upload non-book image -> see "This doesn't appear to be a book" rejection message
- **ISBN not found**: Upload book image where ISBN extraction fails -> see "Could not identify a book ISBN"
- **Age-gated book display**: Verify frosted overlay and lock icon on age-gated book spines
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

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #118)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #118 covers two tightly-coupled user stories —
US-4.1 (Three-Step Content Moderation Pipeline,
`docs/user_stories/US-4.1-moderation-pipeline.md`) and US-4.2 (Age
Verification for Gated Content, `docs/user_stories/US-4.2-age-verification.md`)
— so the matrix is 13 layers × 2 US, with happy/sad columns per cell
(52 cells).

**Overlap with the upload-pipeline audit:** US-4.1's happy-path server
mechanics (upload → `IdentifyBookJob` → `Books.create` → book on shelf)
are the same code path already audited in `plans/test-audit-plan.md`
(US-1.1.1–1.1.4). Where a US-4.1 cell is *fully* covered by an existing
upload-pipeline test, it is marked ✅ with the file cited and **not**
re-listed as a new obligation; this audit focuses on the moderation- and
age-gate-specific assertions (BISAC → visibility_tier mapping,
`/analyze` classification branches, `AgeGate.enforce/2`, the age
verification settings flow).

**Feature status:** both features are fully implemented.
- `Stacks.Moderation.run_pipeline/1`
  (`apps/core/lib/stacks/moderation.ex`) runs a single fused
  `call_vision("analyze", …)` → `POST /analyze` (classify + extract in
  one Modal invocation; `CLASSIFICATION_RESULT_BOOK` /
  `_NOT_BOOK` / `_AMBIGUOUS`), then compound-title expansion,
  ISBN resolution, `subjects_to_bisac/1`, and
  `determine_visibility_tier/1` (adult BISAC codes FIC005000 / FIC027000 /
  FIC069000 → `"age_gated"`, all else `"public"`).
- `Stacks.Workers.IdentifyBookJob` (queue `:vision`, max_attempts 3)
  orchestrates the job and emits `image.resolved` / `image.rejected`.
- `StacksWeb.Plugs.AgeGate.enforce/2` is an inline controller call
  (`BookController.show/2`, `show_by_isbn/2`) — 403
  `age_verification_required` for age-gated books when the Guardian user
  is nil or `age_verified != true`.
- `StacksWeb.UserSettingsController.update_age_verification/2` backs
  `PUT /api/settings/age_verification`.

The `Stacks.AI.Client.endpoint_path/1` map still exposes
`"is_book" → /classify` and `"extract_isbn" → /extract` for
direct/legacy use (Issue #118 §7 and project MEMORY reference these), but
the pipeline itself calls `/analyze` only. The Python sidecar has tests
for all three endpoints.

---

### Framework-layer summary

| Layer       | US-4.1 | US-4.2 |
|-------------|--------|--------|
| Elixir      | ✅ (moderation_test 30 tests, identify_book_job_test 17, upload_pipeline_test, upload_dbt_test; one code gap: `book.created` payload omits `visibility_tier`) | ✅ (age_gate_test 8, user_settings_controller_test age-verification 5, book_controller_test age-gate ~6, upload_cache_test age-gate segregation 2) |
| Elm unit    | ✅ (UploadTest.elm — full `Page.Upload` update cycle, 60+ tests) | ✅ (SettingsTest.elm — `AgeVerification` toggle/confirm/save, 6 tests) |
| Elm program | ✅ (Page/UploadProgramTest.elm — incl. `upload_age_gated`, `upload_not_a_book`, `upload_isbn_rejection`) | ⚠️ (no `Page.Settings.AgeVerification` program test; unit-level only) |
| Python      | ✅ (test_analyze 10, test_classification 7, test_extraction 24, test_auth 10 — `/analyze`, `/classify`, `/extract`, HMAC) | n/a — vision service not involved in age verification |
| E2E         | ⚠️ (upload-pipeline.spec.ts covers happy / not-a-book / isbn-not-found / auth guard; age-gate.spec.ts is shallow — no frosted-overlay/lock-icon assertion) | ⚠️ (settings.spec.ts covers the verify flow; missing: post-verification access, `/settings/age-verification` UI auth guard) |
| dbt         | ✅ (stg_books `visibility_tier` accepted_values + int_book_detail_view via upload_dbt_test / schema.yml) | n/a — age verification triggers no dbt refresh |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/moderation_test.exs` — 30 tests (happy, not_a_book, isbn_not_found, extraction error, compound-title expansion, confidence threshold, excluded_books/isbns, null-ish author, local-OCR fast path)
- `apps/core/test/stacks/workers/identify_book_job_test.exs` — 17 tests (happy, multi-book, partial-resolve + per-ISBN `image.rejected`, age_gated, not_a_book, isbn_not_found, generic failure, excluded args)
- `apps/core/test/stacks_web/plugs/age_gate_test.exs` — 8 tests (call/2 + enforce/2, verified / unverified / nil-user / public / nil-book)
- `apps/core/test/stacks_web/user_settings_controller_test.exs` — `PUT /api/settings/age_verification`: 5 tests (200 true, 200 false, 422 missing, 422 non-boolean, 401)
- `apps/core/test/stacks_web/book_controller_test.exs` — age-gate: 403 unverified / 200 verified / 403 unauthenticated / 200 public (both `GET /api/books/:id` and `/isbn/:isbn`)
- `apps/core/test/stacks_web/upload_controller_test.exs` — `POST /api/upload` (202 / 422 / 401), `/init`, `/commit`, `/identify`, `/stream`, `/reject-identification`
- `apps/core/test/stacks/upload_pipeline_test.exs`, `upload_dbt_test.exs`, `upload_telemetry_test.exs`, `upload_cache_test.exs` — shared upload-pipeline suites (events, dbt, telemetry, cache)
- `apps/core/test/stacks/enrichment/handlers/book_created_handler_test.exs`, `enrichment/author_discovery_handler_test.exs`, `books/handlers/cache_invalidation_handler_test.exs` — `book.created` handlers
- `apps/core/test/stacks/ai/client_test.exs`, `ai/budget_tracker_test.exs`, `storage_test.exs`, `books/isbn_resolver_test.exs`, `observability_telemetry_test.exs`
- `frontend/tests/UploadTest.elm`, `frontend/tests/Page/UploadProgramTest.elm`, `frontend/tests/SettingsTest.elm`
- `e2e/tests/upload-pipeline.spec.ts`, `e2e/tests/upload.spec.ts`, `e2e/tests/age-gate.spec.ts`, `e2e/tests/settings.spec.ts`
- `apps/vision/tests/test_analyze.py`, `test_classification.py`, `test_extraction.py`, `test_auth.py`

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **29** |
| ⚠️ shallow | **3** |
| ❌ missing | **1** |
| n/a (covered higher up / not applicable / by-design) | **19** |

52 cells total (13 layers × 2 US × happy/sad). This is the
pre-implementation baseline; Issue #118's DoD requires regenerating this
audit to 0 ❌ / 0 ⚠️ after the punch list lands. (E2E gaps are not
counted in the 52-cell matrix — E2E is not one of the 13 layers — but
they appear as punch-list items #6–#8 and drive the ⚠️ on the framework
E2E row.)

---

### Full audit tables

#### Layer 1: API Calls

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 4.1 | ✅ upload_controller_test.exs — "accepts image upload and enqueues IdentifyBookJob" (202 + `image_id`); `/stream` returns pending/resolved SSE. | STRONG | ✅ upload_controller_test.exs — "returns 422 when no image provided"; "returns 404 for unknown image_id"; "returns 400 for an invalid (non-UUID) image_id". | STRONG |
| 4.2 | ✅ user_settings_controller_test.exs — "returns 200 and sets age_verified to true" / "…to false"; book_controller_test.exs — "returns 200 for age_gated book when user is age_verified", "returns 200 with null placement when not authenticated" (public passthrough). | STRONG | ✅ user_settings_controller_test.exs — "returns 422 when age_verified parameter is missing", "returns 422 when age_verified is not a boolean"; book_controller_test.exs — "returns 403 for age_gated book when user is not age_verified". | STRONG |

#### Layer 2: Auth & Middleware Guards

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 4.1 | ✅ upload_controller_test.exs — authenticated 202 path via `auth_conn`; `POST /api/upload` runs `:authenticated` + `:rate_limit_upload`. | STRONG | ✅ upload_controller_test.exs — "returns 401 without auth token" (for `/upload`, `/upload/init`, `/upload/identify`, `/stream`, `/reject-identification`). | STRONG |
| 4.2 | ✅ age_gate_test.exs — "passes through when authenticated user is age-verified", "passes conn through for public book", "passes conn through for nil book". | STRONG | ✅ age_gate_test.exs — "halts with 403 when no user is authenticated (nil user)", "halts with 403 when authenticated user is not age-verified"; user_settings_controller_test.exs — "returns 401 when not authenticated". (E2E UI guard for `/settings/age-verification` is a gap — punch #7.) | STRONG |

#### Layer 3: Database Interactions

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ moderation_test.exs — "stores book with public tier when no adult BISAC codes are present", "stores book with age_gated visibility_tier when adult BISAC code present", "returns existing book when ISBN already in database" (`Books.find_existing/1`); upload_dbt_test.exs — "books and book_editions records exist after book creation", "uploaded_images record has correct status and storage_path after upload". (Issue §4's exact "`expires_at` = 30 days" value is covered as "correct fields" in the upload audit; not re-asserted here.) | ✅ upload_dbt_test.exs — "no books or editions created on ISBN rejection", "no books, editions, or placements created on non-book rejection", "uploaded_images marked rejected with isbn_not_found reason" / "…not_a_book reason". |
| 4.2 | ✅ user_settings_controller_test.exs — "returns 200 and sets age_verified to true" persists `op.users.age_verified`; book_controller_test.exs reads `visibility_tier` via `AgeGate`. | ✅ user_settings_controller_test.exs — "returns 422 when age_verified is not a boolean" (guard rejects non-boolean; no write). |

#### Layer 4: Event Flow & Lifecycle

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ⚠️ `book.created` IS emitted and its payload is asserted — upload_pipeline_test.exs:1164 "book.created event emitted on book creation" checks `payload["isbn"]` + `payload["title"]` + `aggregate_type == "book"`. BUT US-4.1 §6 requires `visibility_tier` in the payload and **the code omits it** — `Books.create/1` (`books.ex:182`) emits `payload: %{isbn:, title:}` only. **CODE GAP** (mirror of upload-audit Fix #5, which added `visibility_tier` to `placement.created`). Handler triggering is covered: book_created_handler_test.exs — "enqueues TriggerPriceScrapeJob for book.created with ISBN"; cache_invalidation_handler_test.exs — "invalidates cache on book.created". Two doc/impl mismatches (punch #2): (a) `AuthorDiscoveryHandler` is registered for `book.created` but is now a no-op — author_discovery_handler_test.exs "does not enqueue discovery for any book.created event"; (b) US-4.1 §6 lists `DbtRefreshHandler` on `book.created`, but the registry does **not** subscribe it there — upload_dbt_test.exs "book.created … does not enqueue a dbt refresh job" (only `placement.created` does). | ✅ upload_pipeline_test.exs — "no book.created event emitted on rejection" (not_a_book / isbn_not_found paths emit `image.rejected`, never `book.created`); identify_book_job_test.exs — "emits image.rejected event". |
| 4.2 | n/a — by design no domain event is emitted for age verification (US-4.2 §6 "N/A"); it is a single `op.users` UPDATE. | ❌ No test confirms the *absence* of side-effect events after `PUT /api/settings/age_verification` (Issue §5 "confirm no side effects"). Feature is correct (no `Events.emit` in `update_age_verification/2`); the negative-emission assertion is missing (punch #4). |

#### Layer 5: Background Jobs (Oban)

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ identify_book_job_test.exs — "returns :ok and marks image resolved when pipeline identifies a book", "marks image resolved with all book_ids when pipeline returns multiple books", "book has age_gated visibility_tier when adult BISAC subject is returned"; pipeline steps: moderation_test.exs — "splits 'Title A OR Title B' into two candidates and resolves both" (compound expansion), BISAC mapping via the age_gated/public tier tests. | ✅ identify_book_job_test.exs — "returns {:cancel, reason} when vision model says image is not a book", "returns {:cancel, reason} when vision model cannot extract an ISBN", "returns {:error, reason} when pipeline fails with an unexpected error", "returns {:cancel, isbn_not_found} when multi-book pipeline resolves zero books", "returns :ok and logs warning when resolved image_id does not exist in DB". |
| 4.2 | n/a — age verification is a synchronous settings update; no Oban job (US-4.2 §7). | n/a — same. |

#### Layer 6: External Service Calls

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ moderation_test.exs drives the vision path via `MockClient`; Python sidecar — test_analyze.py "test_analyze_returns_books_for_book_classification", "test_analyze_local_ocr_short_circuit_skips_vlm"; test_classification.py "test_classify_returns_book_classification"; test_extraction.py "test_extract_returns_books_list" / "…multiple_books". HMAC on sidecar calls — ai/client_test.exs "X-Internal-Token header is present…", "token satisfies the Python verify_hmac algorithm" + test_auth.py "test_classify_without_token_returns_401" (and 9 more). ISBN resolution + OL→GB fallback — books/isbn_resolver_test.exs. | ✅ moderation_test.exs — "returns error when vision extraction endpoint itself fails"; test_analyze.py — "test_analyze_short_circuits_on_not_book" / "…on_ambiguous", "test_analyze_missing_input_returns_422", "test_analyze_rejects_missing_hmac"; circuit breaker — upload_telemetry_test.exs "AI.Client returns {:error, :circuit_open} when fuse is blown". |
| 4.2 | n/a — single-user phase is self-declaration; no KYC/external call (US-4.2 §8). | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ storage_test.exs — "stores data and returns {:ok, key}" (`upload_image/3`), "returns {:ok, url} with a mock presigned URL" (`get_image_url/2` — the presigned URL the job hands to `/analyze`). `Storage.Mock` wired in test env. (The exact 900s presigned TTL is not asserted — storage is a generic mechanism; retention/cleanup covered by `gdpr/image_retention_test.exs`.) | n/a — storage failure surfaces via the cache-poisoning tests (upload_cache_test.exs "storage backend failure does not insert any entry"); mechanism otherwise generic. |
| 4.2 | n/a — only a boolean is stored on the user record; no object storage (US-4.2 §9). | n/a — same. |

#### Layer 8: Cache Interactions

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ upload_cache_test.exs — "book.created event invalidates a cached entry", "book.created for each book in multi-book resolution invalidates each cache entry" (`CacheInvalidationHandler` on `book.created`). | n/a — invalidation is the only cache concern in the moderation write path; failure modes covered by the poisoning-prevention tests. |
| 4.2 | ✅ upload_cache_test.exs — "age-gated book cached after age-verified fetch is still gated for non-verified viewer" (BookDetailCache does not leak the age-gate decision). | ✅ upload_cache_test.exs — "AgeGate.enforce halts a non-verified viewer regardless of cache state" (gate enforced post-cache-read, not baked into the cached value). |

#### Layer 9: dbt Model Dependencies

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ upload_dbt_test.exs — "stg_books view exposes book with correct visibility_tier", "placement.created event triggers dbt refresh after real placement" (feeds `int_book_detail_view` → `mart_enrichment_gaps` / `mart_platform_searchable`). | ✅ `dbt/models/staging/schema.yml` — `accepted_values` on `stg_books.visibility_tier`; upload_dbt_test.exs — "book.created … does not enqueue a dbt refresh job" (only placement triggers refresh). |
| 4.2 | n/a — age verification does not trigger dbt refreshes (US-4.2 §11). | n/a — same. |

#### Layer 10: Elm Frontend State Machine

| US  | Happy Path | Verdict | Sad Path | Verdict |
|-----|------------|---------|----------|---------|
| 4.1 | ✅ UploadTest.elm — "UploadAccepted Ok imageId sets uploadState to Success", "StreamEvent resolved payload transitions model to awaiting book fetch", "GotIdentifiedBook Ok collects book and enters Verifying step"; Page/UploadProgramTest.elm — "upload_happy_path", "upload_multi_book", "upload_age_gated: resolved age-gated book renders age-gate notice with verify-age CTA linking to settings". | STRONG | ✅ UploadTest.elm — "StreamEvent rejected payload sets result to IdentificationFailed", "resolved without bookId sets result to NotABook", "StreamError sets result to IdentificationFailed"; Page/UploadProgramTest.elm — "upload_not_a_book", "upload_isbn_rejection", "upload_poll_timeout". | STRONG |
| 4.2 | ✅ SettingsTest.elm — "AgeVerification ToggleRequested opens the confirmation modal", "ConfirmToggle with token sets saving to Loading without flipping ageVerified", "SaveCompleted Ok flips ageVerified and sets Success". (Init "checkbox reflects current `age_verified`" and a full program test are absent — unit-level only; see framework program/E2E rows, punch #6.) | STRONG | ✅ SettingsTest.elm — "CancelToggle closes the modal", "ConfirmToggle without token closes modal without setting Loading", "SaveCompleted Err leaves ageVerified unchanged and sets Failure". | STRONG |

#### Layer 11: Operational Metrics

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | n/a — vision request/latency + Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics`) plus vision + Oban telemetry (observability_telemetry_test.exs "emits start and stop events on successful request"; upload_telemetry_test.exs "[:oban, :job, :stop] fires for IdentifyBookJob"). Per convention, per-US repetition adds no guarantee. | ⚠️ Issue §12 / US-4.1 §13 call for **pipeline step pass/fail rates** (step 1 rejection, step 2 ISBN-extraction failure, step 3 age-gate rate) and compound-title-expansion rate — no such counters are instrumented in `moderation.ex` and no firing test exists. Decide: instrument + firing tests (pattern: upload_telemetry_test.exs), or descope §12 and reclassify n/a (punch #3). Partially blocked on instrumentation. |
| 4.2 | n/a — endpoint latency covered by SLO gate + automatic Phoenix telemetry. | ⚠️ US-4.2 §13 calls for **AgeGate enforcement counts** (403 blocked vs pass-through) and **age-verification request counts** (200 vs 422) — no telemetry is emitted from `AgeGate.enforce/2` or `update_age_verification/2`, and no firing test exists. Decide: instrument + firing tests, or descope n/a (punch #5). Partially blocked on instrumentation. |

#### Layer 12: Performance & Usability Metrics

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | n/a — upload-to-result latency, classification accuracy, ISBN-resolution success are covered by the SLO gate / dashboards; in-test SLA bounds are an anti-pattern under variable CI timing. | n/a — same. |
| 4.2 | n/a — verification completion rate / time-to-verify / gate latency are dashboard concerns; `AgeGate.enforce/2` is an in-memory boolean check. | n/a — same. |

#### Layer 13: Cost Tracking

| US  | Happy Path | Sad Path |
|-----|------------|----------|
| 4.1 | ✅ ai/budget_tracker_test.exs — "accumulates costs across multiple calls", "tracks costs per provider"; observability_telemetry_test.exs — "emits cost_recorded event on record_cost" (the `:modal` per-call charge every `/analyze` round-trip books via `record_vision_call_cost/0`). | ✅ ai/client_test.exs — "records modal cost in BudgetTracker even when the request errors" (rejection ≠ free: Modal bills for GPU time regardless of HTTP outcome). |
| 4.2 | n/a — age verification is a single DB write, no external API cost (US-4.2 §15). | n/a — same. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell plus the three E2E gaps converted to a numbered item. No
tests were written or modified during this audit (pre-implementation
baseline).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L4 US-4.1 happy | **CODE GAP:** add `visibility_tier` to the `book.created` event payload in `Books.create/1` (`books.ex:182`, currently `%{isbn:, title:}`), then extend upload_pipeline_test.exs:1164 to assert `payload["visibility_tier"]` for both a public and an age_gated book. Mirrors upload-audit Fix #5 (`placement.created`). | `apps/core/lib/stacks/books.ex` + `apps/core/test/stacks/upload_pipeline_test.exs` |
| 2 | L4 US-4.1 (doc/impl) | Reconcile US-4.1 §6's handler list with the registry: `AuthorDiscoveryHandler` is a no-op on `book.created`, and `DbtRefreshHandler` is **not** subscribed to `book.created` (only `placement.created`). Either correct the US doc or, if the behaviour is wrong, wire + test. Add an explicit "book.created triggers exactly [BookCreatedHandler, AuthorDiscoveryHandler, CacheInvalidationHandler]" registry assertion. | `docs/user_stories/US-4.1-moderation-pipeline.md` + `apps/core/test/stacks/events/registry_test.exs` |
| 3 | L11 US-4.1 sad | Decide + implement: instrument pipeline step pass/fail-rate telemetry (step 1 not_a_book, step 2 isbn_not_found, step 3 age-gate) and compound-title-expansion rate in `moderation.ex`, with firing tests (pattern: upload_telemetry_test.exs); or formally descope Issue §12 and reclassify n/a. **Partially blocked on instrumentation** (counters do not exist yet). | `apps/core/lib/stacks/moderation.ex` + new telemetry test |
| 4 | L4 US-4.2 sad | Negative-emission test: `PUT /api/settings/age_verification` writes `age_verified` and emits **no** domain event / enqueues no job (Issue §5 "confirm no side effects"). Feature is already correct — assertion only. | `apps/core/test/stacks_web/user_settings_controller_test.exs` |
| 5 | L11 US-4.2 sad | Decide + implement: instrument AgeGate enforcement counts (403 blocked vs pass-through) and age-verification request counts (200 vs 422), with firing tests; or descope §13 and reclassify n/a. **Partially blocked on instrumentation.** | `apps/core/lib/stacks_web/plugs/age_gate.ex` + `user_settings_controller.ex` + new telemetry test |
| 6 | E2E (US-4.2, framework row) | Playwright: age-gated content access **after** verification — a verified user opens an age-gated book detail and sees it render normally (no 403, no overlay). Issue §1 "Age-gated content access after verification". age-gate.spec.ts currently stops at the pre-verification gate. | `e2e/tests/age-gate.spec.ts` (or `settings.spec.ts`) |
| 7 | E2E (US-4.2 L2, framework row) | Playwright: unauthenticated user navigating to `/settings/age-verification` sees the login page (Issue §2 "Age verification page auth guard"). Only the API 401 and the `/upload` UI guard exist today. | `e2e/tests/settings.spec.ts` |
| 8 | E2E (US-4.1 L10, framework row) | Strengthen age-gate.spec.ts: it currently asserts `.age-gate` **or** `.page--book-detail` (passes even when the fixture user is already verified) and never asserts the frosted overlay + lock icon on age-gated **spines** (Issue §1 "Age-gated book display"). Split into a deterministic non-verified-user gate assertion + a spine overlay/lock-icon assertion. | `e2e/tests/age-gate.spec.ts` |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 2-US matrix (52 cells):

- **29 ✅ STRONG** — the moderation server pipeline and age-gate
  enforcement are genuinely well covered: `moderation_test` (30),
  `identify_book_job_test` (17), `age_gate_test` (8), the shared
  upload-pipeline suites, `UploadTest` / `UploadProgramTest` /
  `SettingsTest`, and a full Python sidecar suite for `/analyze`,
  `/classify`, `/extract`, and HMAC.
- **3 ⚠️ shallow** — `book.created` payload omits `visibility_tier`
  (code gap); and both US' operational-metrics sad cells require
  instrumentation that does not exist yet (pipeline step rates; AgeGate /
  verification counters).
- **1 ❌ missing** — no negative-emission test for age verification
  (feature is correct, test absent).
- **19 n/a** — background jobs / external services / storage / dbt /
  cache-sad / cost for US-4.2 (self-declaration, no side effects), plus
  performance and operational-happy cells covered by the SLO gate.

**Headline findings:**
1. **`book.created` payload is missing `visibility_tier`.** The
   moderation pipeline computes the tier and persists it on the book, but
   the event that fans out to enrichment / cache / dbt consumers only
   carries `isbn` + `title` — the exact class of bug the upload audit's
   Fix #5 caught for `placement.created`. Downstream consumers cannot see
   the age-gate decision on the event. This is a correctness gap, not
   just a test gap (punch #1).
2. **US-4.1 §6's event-handler list is stale.** `AuthorDiscoveryHandler`
   is now a no-op for `book.created`, and `DbtRefreshHandler` is not
   subscribed to `book.created` at all (confirmed by the registry and
   `upload_dbt_test`). Doc and code disagree (punch #2).
3. **E2E age-gate coverage is the weakest link.** age-gate.spec.ts is a
   single non-deterministic test (age gate *or* book detail), there is no
   post-verification access test, no `/settings/age-verification` UI auth
   guard, and no frosted-overlay/lock-icon assertion — three of the six
   Playwright scenarios Issue §1/§2 enumerate are absent (punches #6–#8).
4. **Operational metrics for the moderation funnel don't exist.** Issue
   §12/§13 want per-step pass/fail rates and AgeGate enforcement counts;
   nothing emits them today (punches #3, #5) — instrumentation decisions,
   not pure test work.

**Test runner totals at baseline (moderation-relevant, verified by
grep):** Elixir — moderation_test 30, identify_book_job_test 17,
age_gate_test 8, user_settings_controller_test age-verification 5,
book_controller_test age-gate ~6; Elm — UploadTest 60+, UploadProgramTest
~16, SettingsTest AgeVerification 6; Playwright — upload-pipeline.spec.ts
~30, age-gate.spec.ts 1, settings.spec.ts age-verification 4; Python —
test_analyze 10, test_classification 7, test_extraction 24, test_auth 10.
Punch list: **8 items**, of which #1 is a code gap, #2 is a doc/impl
reconciliation, and #3/#5 are partially blocked on instrumentation.
</content>
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local` (mock services)
- [ ] No flaky tests — vision mock responses are deterministic
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires moderation pipeline implementation, age gate plug, vision sidecar mock.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
