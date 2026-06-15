# US-1.1.4 — Age-Gated Content Flagging

## 1. User Story

> **As a** user, **I want** books with sensitive content to be automatically flagged **so that** age-appropriate access controls are applied without manual moderation.

**What the user wants to accomplish:** Have the system automatically detect and flag books covering sensitive topics (anatomy, sexuality, etc.) based on their metadata.

**How they accomplish it:**
1. The user uploads a book that resolves to a valid ISBN.
2. The system retrieves the book's subjects and categories (BISAC codes, Open Library subjects).
3. The subjects are checked against a sensitive content list (nudity, anatomy, sexuality -- including children's body-education books).
4. If flagged, the book is marked as age-gated (18+ only).
5. The book is still added to the shelf but requires age verification to view its detail overlay.

**What they see on the page:**
- The book spine appears on the shelf with a small, discreet frosted-glass overlay and a lock icon.
- Clicking the spine prompts age verification before the detail overlay opens.
- A notice in the upload success state reads: "This book has been marked as age-gated based on its subject matter. Age verification is required to view its details."

---

## 2. UI Interaction Flow

### Happy Path
1. User uploads a book image (same as US-1.1.1 steps 1-3).
2. Vision pipeline identifies the book and resolves ISBN.
3. During `Moderation.store_book/3`, the system determines the book's `visibility_tier` is `"age_gated"` based on BISAC codes.
4. The book is created with `visibility_tier: "age_gated"` in `op.books`.
5. The upload flow proceeds normally through verification and shelf placement (US-1.1.1 steps 7-9).
6. When the user later views the book detail via `GET /api/books/:id`, `AgeGate.enforce/2` checks whether the user has completed age verification.

### Sad Paths
- **No age verification on file**: User clicks the age-gated book spine -> `GET /api/books/:id` -> `AgeGate.enforce/2` halts the conn -> user sees age verification prompt (handled by `PUT /api/settings/age_verification` flow).
- **Under 18**: Age verification denied -- book detail remains inaccessible.

### Elm State Machine
- **Page module**: `Page.Upload` (for the upload flow -- no special handling for age-gated content during upload)
- **Model fields involved**: Same as US-1.1.1; the age-gating is transparent to the upload UI
- **Note**: The upload Elm code does not display different UI for age-gated books. The flagging is entirely server-side. The book detail page (`Page.BookDetail`) and `Page.Settings.AgeVerification` handle the age gate enforcement on the frontend.

---

## 3. API Calls

The upload flow API calls are identical to US-1.1.1. The age-gating affects downstream book detail retrieval:

### `GET /api/books/:id` (downstream, when viewing the book later)
- **Auth**: Optional (Bearer token)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Age gate enforcement**: `AgeGate.enforce(conn, book)` is called. If `book.visibility_tier == "age_gated"` and the user has not verified their age, the conn is halted.
- **Response (age-gated, not verified)**: conn halted by `AgeGate.enforce/2`
- **Response (age-gated, verified)**: normal book detail response with `visibility_tier: "age_gated"` in the book object

---

## 4. Auth & Middleware Guards

- **Plugs fired** (upload): Same as US-1.1.1
- **Plugs fired** (book detail): `SecurityHeaders` -> `OptionalAuthPipeline` -> then inline `AgeGate.enforce/2`
- **Age gate**: `AgeGate.enforce/2` checks `book.visibility_tier == "age_gated"` and verifies the user has completed age verification via their user settings
- **Visibility checks**: `Visibility.resolve_visibility/2` also participates -- age-gated books may be hidden from unauthenticated users via `maybe_exclude_age_gated/2` in `Books.list_catalogue/1`

---

## 5. Database Interactions

### Write: Create book with age_gated visibility_tier
- **Table(s)**: `op.books`
- **Operation**: INSERT (same as US-1.1.1, but with `visibility_tier: "age_gated"`)
- **Changeset validations**: `visibility_tier` validated via `validate_inclusion(:visibility_tier, ["public", "age_gated"])`
- **Schema module**: `Stacks.Books.Book`
- **Column**: `visibility_tier` (string, default `"public"`)

### Read: Catalogue filtering
- **Table(s)**: `op.books`
- **Query**: `Books.list_catalogue/1` with `maybe_exclude_age_gated/2` -- `WHERE visibility_tier != 'age_gated'` for unauthenticated viewers
- **Impact**: Age-gated books are excluded from public catalogue listings

---

## 6. Event Flow & Lifecycle

### Events Emitted
Same as US-1.1.1 (`image.submitted`, `image.resolved`, `book.created`, `placement.created`). No special event is emitted for age-gating; the `book.created` payload includes the book data, and the `visibility_tier` is a column on the book record.

### Event Handlers Triggered
Same as US-1.1.1 -- `BookCreatedHandler`, `AuthorDiscoveryHandler`, `CacheInvalidationHandler` for `book.created`.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
Same as US-1.1.1, but during the `Moderation.store_book/3` step, the age-gating logic executes:

1. `store_book/3` retrieves subjects from ISBN metadata
2. Calls `subjects_to_bisac(subjects)` to map Open Library subjects to BISAC codes
3. Calls `determine_visibility_tier(bisac_codes)`:
   - Checks BISAC codes against `adult_codes = ["FIC005000", "FIC027000", "FIC069000"]`
   - `FIC005000` = Erotica, `FIC027000` = Romance / Erotic Romance, `FIC069000` = Erotic Fiction
   - If any match: returns `"age_gated"`
   - Otherwise: returns `"public"`
4. Sets `visibility_tier` in the book attributes passed to `Books.create/1`

**Subject-to-BISAC mapping** (in `Moderation.subjects_to_bisac/1`):
| Subject (lowercase) | BISAC Code |
|---------------------|------------|
| "fiction" | FIC000000 |
| "mystery" | FIC022000 |
| "science fiction" | FIC028000 |
| "fantasy" | FIC009000 |
| "romance" | FIC027000 (triggers age gate) |
| "biography" | BIO000000 |
| "history" | HIS000000 |
| "self-help" | SEL000000 |
| "children" | JUV000000 |

---

## 8. External Service Calls

Same as US-1.1.1. The age-gating decision is made locally based on subjects returned by Open Library / Google Books metadata -- no additional external calls are needed.

---

## 9. Storage (R2 / Local)

Same as US-1.1.1.

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: Same as US-1.1.1
- **Note**: Cached book detail includes `visibility_tier`, so cache invalidation on `book.created` ensures stale entries don't bypass the age gate

---

## 11. dbt Model Dependencies

- **Model**: `stg_books`
- **Column**: `visibility_tier` -- available for analytics on age-gated content proportion
- **Model**: `int_visibility_resolution` -- intermediate model that resolves visibility rules
- **Consumer**: Metrics dashboard, catalogue API filtering

---

## 12. Elm Frontend State Machine (Detail)

### Route
Same as US-1.1.1 for the upload flow.

### Init
Same as US-1.1.1.

### Update cycle
Same as US-1.1.1. The age-gating is invisible to the upload Elm module. The `Page.Upload` module does not differentiate between age-gated and public books.

The age gate enforcement is handled by:
- `Page.BookDetail` -- which receives the `visibility_tier` field in the book API response and shows the age verification gate if needed
- `Page.Settings.AgeVerification` -- which handles the `PUT /api/settings/age_verification` call

### View
During upload, no visual difference. The age-gating manifests later:
- On the bookshelf page: the book spine renders with a frosted-glass overlay and lock icon (CSS-driven based on `visibility_tier`)
- On the book detail page: age verification gate appears before content is shown

---

## 13. Operational Metrics

### HTTP Request Metrics

All upload-flow HTTP metrics are identical to US-1.1.1. The age-gating adds metrics for downstream book detail access:

- **Metric name**: `age_gate_enforcement_count`
- **Source**: Not yet instrumented. `AgeGate.enforce/2` in `BookController.show/2` — would need a Telemetry event for gate checks.
- **Type**: counter
- **Labels/dimensions**: result (passed, halted), book_id, visibility_tier (`age_gated`)

- **Metric name**: `age_gate_halted_count`
- **Source**: Not yet instrumented. Count of conns halted by `AgeGate.enforce/2`.
- **Type**: counter
- **Labels/dimensions**: none

- **Metric name**: `age_verification_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`PUT /api/settings/age_verification`), status_code (200, 422)

### Oban Job Metrics

Same as US-1.1.1. The age-gating decision is made inline within `IdentifyBookJob` during `Moderation.store_book/3` — no additional Oban job is enqueued.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`book.created` — the payload includes `visibility_tier: "age_gated"`)

- **Metric name**: `age_gated_book_count`
- **Source**: Not yet instrumented. Derivable from `event_log` where `event_type = 'book.created'` and payload contains `visibility_tier = 'age_gated'`.
- **Type**: counter
- **Labels/dimensions**: visibility_tier

### Database Metrics

Same as US-1.1.1 plus:

- **Metric name**: `catalogue_age_gate_filter_count`
- **Source**: Not yet instrumented. `Books.list_catalogue/1` with `maybe_exclude_age_gated/2` — count of queries that filter out age-gated content.
- **Type**: counter
- **Labels/dimensions**: filter_applied (true/false)

---

## 14. Performance & Usability Metrics

### Pipeline Timing

Same as US-1.1.1. The age-gating decision adds negligible time — `determine_visibility_tier/1` is a local BISAC code comparison (microseconds). No additional external API calls.

- **Metric name**: Age-gating decision time
- **How measured**: Not separately measured. Part of `Moderation.store_book/3` which runs within `IdentifyBookJob`.
- **Target/SLA**: < 1ms (local string comparison only)
- **Dashboard**: Not dashboarded (too fast to be meaningful)

### Downstream Access Metrics

- **Metric name**: Age verification completion rate
- **How measured**: `count(successful age verifications) / count(age gate halts)`. Not yet instrumented — would require correlating `AgeGate.enforce/2` halts with subsequent `PUT /api/settings/age_verification` calls.
- **Target/SLA**: Informational — no target set
- **Dashboard**: User settings section

- **Metric name**: Age verification latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `PUT /api/settings/age_verification`
- **Target/SLA**: p95 < 100ms (simple DB update)
- **Dashboard**: API latency section

- **Metric name**: Age-gated content proportion
- **How measured**: `count(books where visibility_tier = 'age_gated') / count(books)` from `stg_books` dbt model
- **Target/SLA**: Informational — expected < 5% of catalogue
- **Dashboard**: Content moderation section

### User Experience Metrics

- **Metric name**: Upload-to-shelf time for age-gated books
- **How measured**: Same as US-1.1.1 — the upload flow is identical. Age-gating is transparent to the upload UI.
- **Target/SLA**: Same as US-1.1.1 (p50 < 30s, p95 < 60s)
- **Dashboard**: Upload pipeline section

---

## 15. Cost Tracking

### Upload Flow Costs
Identical to US-1.1.1. The age-gating decision adds no external API calls or compute costs.

### Vision Classification + Extraction (Modal GPU)
- **Service**: Modal (A10G GPU)
- **Trigger**: Same as US-1.1.1 — `IdentifyBookJob` runs the full vision pipeline
- **Unit cost**: ~R0.50-R2.50 per identification
- **Volume estimate**: Same as US-1.1.1
- **Tracked by**: `Stacks.AI.BudgetTracker`, `op.platform_costs`, `mart_cost_tracking`

### Open Library / Google Books API
- **Service**: Open Library, Google Books
- **Trigger**: ISBN resolution — same as US-1.1.1. The subjects/BISAC codes used for age-gating are returned as part of the ISBN metadata response (no additional API call).
- **Unit cost**: Free
- **Volume estimate**: Same as US-1.1.1
- **Tracked by**: No cost tracking needed

### Age Verification (Downstream)
- **Service**: None — age verification is a local database operation (`PUT /api/settings/age_verification` updates the user's settings)
- **Trigger**: User attempts to view an age-gated book detail
- **Unit cost**: Negligible (single DB update)
- **Volume estimate**: Once per user who encounters an age-gated book (not per-book)
- **Tracked by**: Not tracked as a cost item

### Per-Upload Cost Estimate (Age-Gated Books)
- Same as US-1.1.1: **~R0.50-R2.50 (~$0.03-$0.14 USD) per upload**
- No additional cost for the age-gating decision itself

---

## 16. Cross-References

- **US-4.2 — Age Verification** (`docs/user_stories/US-4.2-age-verification.md`): the user-facing age verification flow that lets a verified user pass `AgeGate.enforce/2`. The `PUT /api/settings/age_verification` endpoint sets `users.age_verified = true`, which this story's age gate consults.
- **US-1.1.1 — Book Upload** (`docs/user_stories/`): parent flow whose `IdentifyBookJob` invokes `Moderation.store_book/3` where the visibility tier is decided.
- **ADR 006 — Row-Level Security Plus Application-Layer Visibility** (`docs/decisions/006-rls-plus-application-visibility.md`): the defence-in-depth visibility model that `Stacks.Visibility` and `AgeGate` together implement. Book-level `visibility_tier` sits alongside the bookshelf/placement visibility ceilings described there.
- **Implementation modules**:
  - `apps/core/lib/stacks/moderation.ex` — `determine_visibility_tier/1`, `subjects_to_bisac/1`
  - `apps/core/lib/stacks_web/plugs/age_gate.ex` — `AgeGate.enforce/2`
  - `apps/core/lib/stacks/books.ex` — `list_catalogue/1`, `maybe_exclude_age_gated/2`, `book_changeset` (validates `visibility_tier` ∈ `["public", "age_gated"]`)
  - `apps/core/lib/stacks/visibility.ex` — `check_age_gate/2` (per-resource visibility resolver)
