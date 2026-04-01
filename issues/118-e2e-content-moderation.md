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
- `VisionProcessJob` enqueued on upload with correct args (`image_id`, `user_id`)
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
- Oban telemetry for `VisionProcessJob`: enqueued, completed, failed counts
- Vision sidecar call latency tracked per endpoint
- Pipeline step pass/fail rates: step 1 rejection, step 2 failure, step 3 age-gate rates
- AgeGate enforcement counts: 403 blocked vs pass-through
- Age verification request counts: success vs failure

## Reviewer Context
- Vision sidecar endpoint mapping: `"is_book"` -> `/classify`, `"extract_isbn"` -> `/extract` (defined in `Stacks.AI.Client.endpoint_path/1`). Python sidecar paths must NOT change.
- BISAC codes for age gating: FIC005000, FIC027000, FIC069000.
- `AgeGate.enforce/2` is an inline plug call, not a router-level plug.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local` (mock services)
- [ ] No flaky tests — vision mock responses are deterministic
- [ ] `just verify` passes

## Dependencies
Requires moderation pipeline implementation, age gate plug, vision sidecar mock.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
