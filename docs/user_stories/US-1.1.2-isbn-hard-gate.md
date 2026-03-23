# US-1.1.2 — ISBN Hard Gate -- Book Rejection

## 1. User Story

> **As a** user, **I want to** receive a clear explanation when a book cannot be identified **so that** I understand why it was not added and what I can do about it.

**What the user wants to accomplish:** Understand why a book upload failed and know that this is by design -- The Stacks is a physical-books-first platform that requires ISBN verification.

**How they accomplish it:**
1. The user uploads photos as in US-1.1.1.
2. The vision model extracts text but the system cannot resolve it to a valid ISBN via Open Library or Google Books.
3. The system displays a rejection message within the upload modal.

**What they see on the page:**
- The upload modal shifts to a warm amber state with an icon of a closed book.
- The message reads: "We couldn't find an ISBN for this book. The Stacks relies on ISBN to ensure accurate metadata -- this is a physical-books-first platform. Try uploading a clearer photo of the back cover or barcode, or a different edition."
- Below the message, a "Try Again" button resets the upload flow and a "Cancel" button closes the modal.
- No book is created. No partial entry is saved.

---

## 2. UI Interaction Flow

### Happy Path
N/A -- this story IS the sad path of US-1.1.1. There is no "happy path" for rejection; the user's goal (adding a book) was not achieved.

### Sad Paths
- **ISBN not found**: User uploads image -> vision pipeline extracts text but no ISBN resolves -> `IdentifyBookJob` calls `mark_rejected(image_id, "isbn_not_found")` -> poll returns `status: "rejected"` -> Elm receives `StatusReceived (Ok {status: Rejected})` -> `result = IdentificationFailed` -> rejection UI is shown.
- **Recovery**: User can click "Try Another Photo" (`Reset`) to re-enter the upload flow, or click "Enter ISBN Manually" (`EnterManualMode`) to switch to manual ISBN entry (US-1.1.5).

### Elm State Machine
- **Page module**: `Page.Upload`
- **Model fields involved**: `result`, `uploadState`
- **Msg flow**: `StatusReceived (Ok {status: Rejected})` -> sets `result = IdentificationFailed`
- **View function**: `viewIdentificationFailed` renders the rejection UI
- **Recovery Msgs**: `Reset` (try another photo) or `EnterManualMode` (manual ISBN entry)

---

## 3. API Calls

### `GET /api/upload/:image_id/status`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UploadController.status/2`
- **Response (rejection case)**: `{ image_id: "...", status: "rejected", book_id: null, book_ids: [], rejection_reason: "isbn_not_found", is_duplicate: false }` -- HTTP 200

The response still returns HTTP 200 because the poll endpoint reports status, not success. The `status: "rejected"` field and `rejection_reason: "isbn_not_found"` convey the failure.

No other API calls are made. No book or placement is created.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` (for status poll)
- **Visibility checks**: N/A -- no book is created, so no visibility resolution occurs
- **Age gate**: N/A
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Write: Mark image as rejected
- **Table(s)**: `op.uploaded_images`
- **Operation**: UPDATE
- **Fields set**: `status = "rejected"`, `rejection_reason = "isbn_not_found"`, `updated_at = now()`
- **Performed by**: `IdentifyBookJob.mark_rejected/2` via `Repo.update_all` with raw query on `"uploaded_images"` table in `"op"` prefix
- **Transaction**: Not wrapped in Multi

### Read: Poll image status
- **Table(s)**: `op.uploaded_images`
- **Query**: `SELECT status, book_id, book_ids, rejection_reason FROM op.uploaded_images WHERE id = ?`
- **Performed by**: `UploadController.render_status/3`

### No writes to `op.books` or `op.book_editions`
The ISBN hard gate ensures that no book record is created when ISBN resolution fails. The `Moderation.resolve_and_store_all/2` function returns `{:error, :isbn_not_found}` when none of the candidates resolve, and `IdentifyBookJob` cancels with `:isbn_not_found`.

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `image.rejected`
- **Event type**: `image.rejected`
- **Aggregate**: `image` / image_id
- **Payload**: `%{reason: "isbn_not_found"}`
- **Emitted by**: `IdentifyBookJob.mark_rejected/2`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
No handlers are registered for `image.rejected` in `Stacks.Events.Registry`. The event is recorded in the `event_log` for audit purposes only.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
- **Queue**: `:vision`
- **Max attempts**: 3
- **Rejection flow**:
  1. Fetches presigned URL from `Storage.get_image_url/1`
  2. Calls `Moderation.run_pipeline/1`
  3. Pipeline successfully classifies image as a book (`check_is_book_url` returns `{:ok, :is_book}`)
  4. Pipeline calls vision sidecar `POST /extract` -- gets candidates
  5. `resolve_and_store_all/2` iterates candidates:
     - For candidates with `potential_isbns`: tries `ISBNResolver.resolve/1` for each ISBN
     - For candidates with title/author only: tries `ISBNResolver.search_by_title/3`
     - All resolution attempts fail
  6. Returns `{:error, :isbn_not_found}`
  7. `IdentifyBookJob` calls `mark_rejected(image_id, "isbn_not_found")`
  8. Returns `{:cancel, "isbn_not_found"}` -- Oban will not retry this job

The use of `{:cancel, ...}` (rather than `{:error, ...}`) is deliberate: ISBN-not-found is a permanent failure, not a transient one. Retrying the same image against the same ISBN databases would produce the same result.

---

## 8. External Service Calls

### Vision Sidecar -- Extraction
- **Service**: Modal vision sidecar
- **Endpoint**: `POST /extract`
- **Client module**: `Stacks.AI.Client` via `call_vision("extract_isbn", payload)`
- **Response**: Returns candidates, but their `potential_isbns` either don't resolve or are empty

### Open Library API
- **Service**: Open Library
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1`
- **Result**: `{:error, :not_found}` -- ISBN not in Open Library catalogue

### Google Books API
- **Service**: Google Books
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1` (fallback from Open Library)
- **Result**: `{:error, :not_found}` -- ISBN not in Google Books catalogue

### ISBNResolver Title Search (fallback)
- **Service**: Google Books Search API
- **Client module**: `Stacks.Books.ISBNResolver.search_by_title/3`
- **Query strategy**: Progressively broader queries (full title + author, trimmed title + author, full title + surname, raw text enrichment)
- **Result**: `{:error, :not_found}` -- no matching book found

---

## 9. Storage (R2 / Local)

The uploaded image remains in storage after rejection. It was stored during the initial upload step (US-1.1.1) and is not cleaned up on ISBN rejection.

- **Key**: `uploads/{image_id}`
- **Retention**: 30 days (per GDPR; `expires_at` on the `uploaded_images` record)

---

## 10. Cache Interactions

N/A -- no book is created, so no cache entries are written or invalidated.

---

## 11. dbt Model Dependencies

- **Model**: `stg_uploaded_images`
- **Impact**: The rejected image row (status = "rejected", rejection_reason = "isbn_not_found") will appear in the staging model
- **Consumer**: Metrics dashboard -- rejection rates can be tracked

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated

### Init
Same as US-1.1.1. The rejection state is reached during the update cycle, not at init.

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `StatusReceived (Ok {status: Rejected})` | `result = IdentificationFailed` | None | `NoOut` |
| `Reset` | Resets to `init` (try another photo) | None | `NoOut` |
| `EnterManualMode` | `result = ManualISBNEntry`, `isbnLookupState = NotAsked` | None | `NoOut` |

The poll timeout path also leads to `IdentificationFailed`:
| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `CheckStatus` (when `pollCount >= maxPollCount`) | `result = IdentificationFailed` | None | `NoOut` |

### View
- **Rendered by**: `viewIdentificationFailed`
- **Key elements**:
  - `h2`: "Could Not Identify Book"
  - `p`: "We couldn't read the ISBN from this photo. Try a clearer image or enter the ISBN manually."
  - Primary button: "Try Another Photo" (`onClick Reset`)
  - Secondary button: "Enter ISBN Manually" (`onClick EnterManualMode`)
- **CSS classes**: `upload-result`, `upload-result--failed`
- **ARIA attributes**: Inherits `aria-live="polite"` from parent `div.upload-status-region`

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `upload_status_poll_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/upload/:image_id/status`), status_code (200)

Note: The poll response returns HTTP 200 even for rejections — the `status: "rejected"` field conveys the failure. No distinct HTTP error code is generated.

### Oban Job Metrics

- **Metric name**: `identify_book_job_cancelled`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]` where state = `cancelled`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker (`Stacks.Workers.IdentifyBookJob`), cancel_reason (`isbn_not_found`)

- **Metric name**: `identify_book_job_duration`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]` duration
- **Type**: histogram
- **Labels/dimensions**: queue (`:vision`), worker, state (cancelled)

### Circuit Breaker Metrics

- **Metric name**: `vision_fuse_state`
- **Source**: `:fuse.ask(:vision_service, :sync)` — polled periodically. Not yet instrumented as a Telemetry event.
- **Type**: gauge (0 = ok, 1 = blown)
- **Labels/dimensions**: fuse_name (`:vision_service`)

Note: ISBN rejection does NOT trigger fuse melts. The vision sidecar responded successfully — the failure is in ISBN resolution, not in the vision service.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`image.rejected`), reason (`isbn_not_found`)

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`uploaded_images`), operation (update)

- **Metric name**: `isbn_rejection_count`
- **Source**: Not yet instrumented. Derivable from `event_log` where `event_type = 'image.rejected'` and payload `reason = 'isbn_not_found'`.
- **Type**: counter
- **Labels/dimensions**: rejection_reason

### Error Rate Metrics

- **Metric name**: `isbn_resolution_failure_rate`
- **Source**: Not yet instrumented. Derivable from `count(image.rejected where reason = isbn_not_found) / count(image.submitted)` in `event_log`.
- **Type**: gauge (percentage)
- **Labels/dimensions**: none

---

## 14. Performance & Usability Metrics

### Pipeline Timing (Rejection Path)

- **Metric name**: Upload-to-rejection total time
- **How measured**: Delta between `image.submitted` and `image.rejected` event timestamps in `event_log`. Not yet instrumented as a real-time metric.
- **Target/SLA**: p50 < 30s, p95 < 60s (same as happy path — the classification and extraction steps complete before rejection)
- **Dashboard**: Upload pipeline section

- **Metric name**: Vision extraction time (before rejection)
- **How measured**: Duration of `Stacks.AI.Client.call_vision("extract_isbn", ...)`. Not yet instrumented separately from the Oban job duration.
- **Target/SLA**: p50 < 5s, p95 < 15s
- **Dashboard**: Vision pipeline section

- **Metric name**: ISBN resolution attempt time
- **How measured**: Total time spent in `ISBNResolver.resolve/1` and `ISBNResolver.search_by_title/3` across all candidates. Not yet instrumented.
- **Target/SLA**: p50 < 2s (per candidate), p95 < 5s. Multiple candidates may extend total time.
- **Dashboard**: External API section

- **Metric name**: IdentifyBookJob cancelled duration
- **How measured**: Oban Telemetry `[:oban, :job, :stop]` duration for cancelled `:vision` jobs
- **Target/SLA**: p50 < 25s, p95 < 50s
- **Dashboard**: Oban jobs section

### User Experience Metrics

- **Metric name**: Poll count before rejection
- **How measured**: Elm-side `pollCount` at time of `StatusReceived Rejected`. Not yet instrumented server-side.
- **Target/SLA**: median < 15 polls (30s), p95 < 30 polls (60s)
- **Dashboard**: Upload pipeline section

- **Metric name**: ISBN rejection rate
- **How measured**: `count(image.rejected where reason = isbn_not_found) / count(image.submitted)` from `event_log`
- **Target/SLA**: < 20% (if higher, photo quality guidance needs improvement)
- **Dashboard**: Upload funnel section

- **Metric name**: Recovery action after rejection
- **How measured**: Not yet instrumented. Would need Elm-side tracking of whether user clicks "Try Another Photo" vs "Enter ISBN Manually" vs abandons.
- **Target/SLA**: > 50% of rejected users attempt recovery (try again or manual ISBN)
- **Dashboard**: Upload funnel section

- **Metric name**: Rejection-to-manual-entry conversion
- **How measured**: Not yet instrumented. Requires correlating `EnterManualMode` events with prior rejections.
- **Target/SLA**: Informational — no target set
- **Dashboard**: Upload funnel section

---

## 15. Cost Tracking

### Vision Classification (Modal GPU)
- **Service**: Modal (A10G GPU, Qwen2.5-VL-7B-Instruct)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("is_book", ...)` — the classification step runs and succeeds (the image IS a book) before ISBN rejection occurs
- **Unit cost**: ~R0.50-R2.50 per identification (~$0.03-$0.14/min GPU time, 30-60s per call)
- **Volume estimate**: 1 call per upload. This cost is incurred even though the ISBN is not found.
- **Tracked by**: `Stacks.AI.BudgetTracker` (`:modal` provider), `op.platform_costs` table, `mart_cost_tracking` dbt mart

### Vision Extraction (Modal GPU)
- **Service**: Modal (same GPU instance)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("extract_isbn", ...)` — extraction runs and returns candidates, but none resolve to valid ISBNs
- **Unit cost**: Included in classification call cost (same Modal container session)
- **Volume estimate**: 1 call per upload that passes classification
- **Tracked by**: `Stacks.AI.BudgetTracker` (combined under `:modal`)

### Open Library API
- **Service**: Open Library
- **Trigger**: `ISBNResolver.resolve/1` for each candidate ISBN, `ISBNResolver.search_by_title/3` for title-based fallback
- **Unit cost**: Free (public API)
- **Volume estimate**: 1-5 calls per rejected upload (all return `{:error, :not_found}`)
- **Tracked by**: No cost tracking needed (free API)

### Google Books API
- **Service**: Google Books
- **Trigger**: `ISBNResolver.resolve/1` (fallback) and `ISBNResolver.search_by_title/3`
- **Unit cost**: Free tier (1,000 requests/day)
- **Volume estimate**: Called as fallback for each candidate — 1-5 calls per rejected upload
- **Tracked by**: No cost tracking needed at current scale

### R2 Object Storage
- **Service**: Cloudflare R2
- **Trigger**: Image was already stored during initial upload (US-1.1.1). Presigned URL generated for vision pipeline.
- **Unit cost**: Class A write already incurred. Class B read for presigned URL: $0.00036/1,000 requests.
- **Volume estimate**: Image remains in storage for 30 days despite rejection (GDPR `expires_at`)
- **Tracked by**: `op.platform_costs` (category: "infrastructure", service: "r2")

### Per-Rejection Cost Estimate
- Classification + extraction: ~R0.50-R2.50 (full vision cost is incurred)
- ISBN resolution APIs: free
- R2 storage: ~R0.00007 (already incurred during upload)
- **Total per rejection: ~R0.50-R2.50 (~$0.03-$0.14 USD)**

Note: ISBN rejections are expensive relative to their outcome — the user gets no book added but the full vision pipeline cost is incurred. The manual ISBN entry fallback (US-1.1.5) avoids this cost entirely.
