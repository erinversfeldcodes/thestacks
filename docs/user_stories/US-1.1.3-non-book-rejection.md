# US-1.1.3 — Non-Book Image Rejection

## 1. User Story

> **As a** user, **I want** images with no book-related content to be rejected immediately **so that** the platform remains focused on books and inappropriate content never appears.

**What the user wants to accomplish:** Upload only book-related content; accidental or intentional non-book uploads are caught before wasting processing time on them.

**What counts as book-related:** Any image from which a book title, author, or ISBN can plausibly be extracted. This includes physical book photos (cover, spine, back, barcode), mirrored or rotated photos of books, and screenshots of text that mention specific books -- social media posts, reading lists, articles, captions. The classification criterion is "can we identify a book from this?" not "is this a photo of a physical book?"

**What gets rejected:** Images with no book-related content whatsoever -- a pet, a landscape, food, a selfie with no book in frame, a meme with no book reference. Ambiguous images are passed through to extraction rather than rejected conservatively.

**How they accomplish it:**
1. The user uploads an image.
2. The vision model's first pass answers: "Does this image contain enough information to identify a book?"
3. If no -- the image is rejected before any ISBN lookup occurs.
4. If yes or ambiguous -- the image proceeds to extraction.

---

## 2. UI Interaction Flow

### Happy Path
N/A -- this story IS the rejection path. There is no happy outcome for a non-book image.

### Sad Paths
- **Not a book**: User uploads non-book image -> vision pipeline classifies as `not_book` -> `IdentifyBookJob` calls `mark_rejected(image_id, "not_a_book")` -> poll returns `Resolved` with empty `bookIds` (or `Rejected` with reason) -> Elm sets `result = NotABook` -> rejection UI is shown.
- **Recovery**: User clicks "Try Again" (`Reset`) to upload a different image.

### Elm State Machine
- **Page module**: `Page.Upload`
- **Model fields involved**: `result`
- **Msg flow**: `StatusReceived (Ok {status: Resolved, bookIds: [], bookId: Nothing})` -> `result = NotABook`
- **View function**: `viewNotABook`
- **Recovery Msg**: `Reset`

Note: The Elm side detects the `NotABook` state when a `Resolved` status comes back with zero book IDs. This covers both the case where the vision sidecar classified the image as not-a-book (and the worker stored `book_ids: []`) and the edge case where extraction found no candidates.

---

## 3. API Calls

### `GET /api/upload/:image_id/status`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UploadController.status/2`
- **Response (not-a-book case)**: `{ image_id: "...", status: "rejected", book_id: null, book_ids: [], rejection_reason: "not_a_book", is_duplicate: false }` -- HTTP 200

No other API calls are made. No book creation or ISBN lookup occurs.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` (for status poll)
- **Visibility checks**: N/A
- **Age gate**: N/A
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Write: Mark image as rejected
- **Table(s)**: `op.uploaded_images`
- **Operation**: UPDATE
- **Fields set**: `status = "rejected"`, `rejection_reason = "not_a_book"`, `updated_at = now()`
- **Performed by**: `IdentifyBookJob.mark_rejected/2` via `Repo.update_all`
- **Transaction**: Not wrapped in Multi

### No reads beyond status polling
No ISBN resolution, book lookup, or duplicate detection occurs -- the rejection happens at the classification step, before any of those operations.

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `image.rejected`
- **Event type**: `image.rejected`
- **Aggregate**: `image` / image_id
- **Payload**: `%{reason: "not_a_book"}`
- **Emitted by**: `IdentifyBookJob.mark_rejected/2`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
No handlers are registered for `image.rejected` in `Stacks.Events.Registry`. The event exists for audit trail purposes only.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
- **Queue**: `:vision`
- **Max attempts**: 3
- **Non-book rejection flow**:
  1. Fetches presigned URL from `Storage.get_image_url/1`
  2. Calls `Moderation.run_pipeline/1`
  3. Pipeline calls `check_is_book_url(image_url)` which sends `POST /classify` to the vision sidecar
  4. Vision sidecar responds with `%{"classification" => "not_book"}` (or any value other than `"book"`)
  5. `check_is_book_url/1` returns `{:error, :not_a_book}`
  6. Pipeline short-circuits -- **no extraction or ISBN lookup occurs**
  7. `IdentifyBookJob` matches `{:error, :not_a_book}`, calls `mark_rejected(image_id, "not_a_book")`
  8. Returns `{:cancel, "image does not contain a book"}`

Key design decision: the `{:cancel, ...}` return prevents Oban retries. A non-book image will still be a non-book on the second attempt.

The classification step is deliberately permissive: ambiguous images (where `classification` is anything other than explicitly `"book"`) are treated as not-a-book. However, the vision sidecar itself is tuned to return `"book"` for ambiguous cases, so the Elixir side's strict matching is a safety net, not the primary filter.

---

## 8. External Service Calls

### Vision Sidecar -- Classification
- **Service**: Modal vision sidecar (Qwen2.5-VL-7B-Instruct)
- **Endpoint**: `POST /classify`
- **Client module**: `Stacks.AI.Client` via `call_vision("is_book", payload)`
- **Endpoint mapping**: `endpoint_path("is_book")` returns `"classify"`
- **Auth**: HMAC (`X-Internal-Token` header)
- **Circuit breaker**: `:vision_service` fuse; melts on non-200 responses
- **Budget check**: `BudgetTracker.check_budget(:modal)` called before request
- **Timeout**: 210 seconds receive timeout
- **Request payload**: `%{image_url: presigned_url}` (new path) or `%{image: base64_data}` (legacy path)
- **Response**: `%{"classification" => "not_book", "confidence" => float, "model_used" => str}`
- **Mock in test**: `Stacks.AI.MockClient`

No extraction (`POST /extract`) or ISBN resolution calls are made when classification fails.

---

## 9. Storage (R2 / Local)

The uploaded image remains in storage after rejection (same as US-1.1.2).

- **Key**: `uploads/{image_id}`
- **Retention**: 30 days (GDPR `expires_at`)

---

## 10. Cache Interactions

N/A -- no book is created, so no cache entries are affected.

---

## 11. dbt Model Dependencies

- **Model**: `stg_uploaded_images`
- **Impact**: The rejected image row (status = "rejected", rejection_reason = "not_a_book") appears in staging
- **Consumer**: Metrics dashboard -- non-book rejection rates

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated

### Init
Same as US-1.1.1.

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `StatusReceived (Ok {status: Resolved, bookIds: [], bookId: Nothing})` | `result = NotABook` | None | `NoOut` |
| `Reset` | Resets to `init` | None | `NoOut` |

### View
- **Rendered by**: `viewNotABook`
- **Key elements**:
  - `h2`: "That Doesn't Look Like a Book"
  - `p`: "We couldn't detect a book in that image. Please try a photo of a book cover."
  - Primary button: "Try Again" (`onClick Reset`)
- **CSS classes**: `upload-result`, `upload-result--not-book`
- **ARIA attributes**: Inherits `aria-live="polite"` from parent `div.upload-status-region`

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `upload_status_poll_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/upload/:image_id/status`), status_code (200)

### Oban Job Metrics

- **Metric name**: `identify_book_job_cancelled_not_a_book`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]` where state = `cancelled`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker (`Stacks.Workers.IdentifyBookJob`), cancel_reason (`not_a_book`)

- **Metric name**: `identify_book_job_duration_not_a_book`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]` duration for cancelled jobs
- **Type**: histogram
- **Labels/dimensions**: queue (`:vision`), worker

Note: Non-book rejection jobs should be significantly shorter than successful identifications because the pipeline short-circuits after classification — no extraction or ISBN resolution occurs.

### Circuit Breaker Metrics

- **Metric name**: `vision_fuse_melt_count`
- **Source**: Not yet instrumented. `:fuse.melt(:vision_service)` is called on non-200 responses from the vision sidecar. A classification that returns `"not_book"` is a successful 200 response and does NOT trigger a fuse melt.
- **Type**: counter
- **Labels/dimensions**: fuse_name (`:vision_service`)

- **Metric name**: `vision_fuse_state`
- **Source**: `:fuse.ask(:vision_service, :sync)` polled periodically. Not yet instrumented as Telemetry.
- **Type**: gauge
- **Labels/dimensions**: fuse_name

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`image.rejected`), reason (`not_a_book`)

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`uploaded_images`), operation (update)

- **Metric name**: `not_a_book_rejection_count`
- **Source**: Not yet instrumented. Derivable from `event_log` where `event_type = 'image.rejected'` and payload `reason = 'not_a_book'`.
- **Type**: counter
- **Labels/dimensions**: rejection_reason

### Budget Check Metrics

- **Metric name**: `budget_check_result`
- **Source**: `BudgetTracker.check_budget(:modal)` — not yet instrumented with Telemetry. Result is `:ok` or `{:error, :daily_limit_exceeded | :monthly_limit_exceeded}`.
- **Type**: counter
- **Labels/dimensions**: provider (`:modal`), result (ok, daily_limit_exceeded, monthly_limit_exceeded)

---

## 14. Performance & Usability Metrics

### Pipeline Timing (Non-Book Rejection Path)

- **Metric name**: Upload-to-non-book-rejection total time
- **How measured**: Delta between `image.submitted` and `image.rejected` event timestamps in `event_log`.
- **Target/SLA**: p50 < 20s, p95 < 45s. Should be faster than ISBN rejection because the pipeline short-circuits at classification — no extraction or ISBN resolution occurs.
- **Dashboard**: Upload pipeline section

- **Metric name**: Vision classification time
- **How measured**: Duration of `Stacks.AI.Client.call_vision("is_book", ...)`. Not yet instrumented separately from Oban job duration.
- **Target/SLA**: p50 < 8s warm, p95 < 45s (includes Modal cold start)
- **Dashboard**: Vision pipeline section

- **Metric name**: IdentifyBookJob cancelled duration (not_a_book)
- **How measured**: Oban Telemetry `[:oban, :job, :stop]` duration for cancelled `:vision` jobs
- **Target/SLA**: p50 < 15s, p95 < 40s (should be shorter than ISBN rejection since extraction is skipped)
- **Dashboard**: Oban jobs section

### User Experience Metrics

- **Metric name**: Poll count before non-book rejection
- **How measured**: Elm-side `pollCount` at time of `StatusReceived` with empty `bookIds`. Not yet instrumented server-side.
- **Target/SLA**: median < 10 polls (20s), p95 < 25 polls (50s)
- **Dashboard**: Upload pipeline section

- **Metric name**: Non-book rejection rate
- **How measured**: `count(image.rejected where reason = not_a_book) / count(image.submitted)` from `event_log`
- **Target/SLA**: < 10% (if higher, the upload UI needs better guidance about what to photograph)
- **Dashboard**: Upload funnel section

- **Metric name**: Recovery action after non-book rejection
- **How measured**: Not yet instrumented. Would track whether user clicks "Try Again" or abandons.
- **Target/SLA**: > 40% of rejected users try again with a different image
- **Dashboard**: Upload funnel section

---

## 15. Cost Tracking

### Vision Classification (Modal GPU)
- **Service**: Modal (A10G GPU, Qwen2.5-VL-7B-Instruct)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("is_book", ...)` — classification runs and returns `"not_book"`
- **Unit cost**: ~R0.25-R1.25 per classification (~$0.03-$0.14/min GPU time). Non-book rejections use only the classification step (shorter than full identification), estimated 15-30s.
- **Volume estimate**: 1 call per upload. This cost is incurred even though the image is rejected.
- **Tracked by**: `Stacks.AI.BudgetTracker` (`:modal` provider), `op.platform_costs` table, `mart_cost_tracking` dbt mart

### No Extraction Cost
- The pipeline short-circuits after classification — `POST /extract` is NOT called for non-book images. This saves the extraction GPU time (~3-8s).

### No ISBN Resolution Cost
- Open Library and Google Books APIs are NOT called. No ISBN-related external calls occur.

### R2 Object Storage
- **Service**: Cloudflare R2
- **Trigger**: Image was already stored during initial upload. Presigned URL generated for vision classification.
- **Unit cost**: Class B read for presigned URL: $0.00036/1,000 requests.
- **Volume estimate**: Image remains in storage for 30 days despite rejection (GDPR `expires_at`)
- **Tracked by**: `op.platform_costs` (category: "infrastructure", service: "r2")

### Per-Non-Book-Rejection Cost Estimate
- Classification only: ~R0.25-R1.25 (cheaper than ISBN rejection since extraction is skipped)
- No ISBN resolution APIs called
- R2 storage: ~R0.00007 (already incurred)
- **Total per non-book rejection: ~R0.25-R1.25 (~$0.015-$0.07 USD)**

Note: Non-book rejections are the cheapest rejection path because the pipeline short-circuits at classification. The `BudgetTracker.check_budget(:modal)` call before the vision request prevents this cost from being incurred when the daily/monthly budget is exhausted.
