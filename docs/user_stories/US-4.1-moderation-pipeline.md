# US-4.1 — Three-Step Content Moderation Pipeline

## 1. User Story

> **As a** user, **I want** every uploaded image to go through a rigorous moderation pipeline **so that** only legitimate book content enters the platform and sensitive material is appropriately gated.

The moderation pipeline runs automatically on every upload:

1. **Step 1 -- Image Classification**: The vision model checks whether the image is a photo of or about a book. If not, the image is rejected immediately. Nudes, pets, food, and other non-book images are caught here.
2. **Step 2 -- Text Extraction & ISBN Resolution**: The vision model extracts text and the system attempts to resolve an ISBN. If no ISBN is found, the book is rejected.
3. **Step 3 -- Subject Moderation**: The book's metadata subjects and categories are checked against a sensitive content list (BISAC codes, Open Library subjects). If flagged, the book is marked as age-gated.

For rejected images: a clear, specific rejection message. For age-gated books: the book is added but with a frosted overlay on the spine and a lock icon. The pipeline is invisible when everything passes.

---

## 2. UI Interaction Flow

### Happy Path
1. User uploads a photo via the upload page.
2. Image is stored (R2/local), and an `IdentifyBookJob` is enqueued.
3. The pipeline runs `Stacks.Moderation.run_pipeline/1` via a single `call_vision("analyze", ...)` to `POST /analyze` (the sidecar fuses classify + extract in one Modal invocation):
   - Returns `classification` (`CLASSIFICATION_RESULT_BOOK` | `CLASSIFICATION_RESULT_NOT_BOOK` | `CLASSIFICATION_RESULT_AMBIGUOUS`) plus, when `BOOK`, a `books` list of candidates with `potential_isbns`, `title`, `author`, `raw_text`, `confidence`.
   - Pipeline then: compound title expansion (split on " OR "), ISBN resolution (direct from `potential_isbns` or via `ISBNResolver.search_by_title/3`), BISAC subject classification, visibility tier assignment.
4. Book is created with `visibility_tier: "public"` or `"age_gated"`.
5. User sees the book appear on their shelf.

### Sad Paths
- **Not a book**: Vision returns `CLASSIFICATION_RESULT_NOT_BOOK` or `CLASSIFICATION_RESULT_AMBIGUOUS` -> `{:error, :not_a_book}` (per ADR-006-ambiguous-classification, both map to the same rejection). User sees rejection message.
- **No ISBN found**: Extraction returns empty books list or title search fails -> `{:error, :isbn_not_found}`. User sees "Could not identify a book ISBN."
- **Vision service unavailable**: `AIClient.call_vision` fails -> error propagated. Upload status shows failure.
- **Compound titles**: Vision joins multiple titles with " OR " -> pipeline splits them and resolves each independently.

### Elm State Machine
- **Page module**: `Page.Upload` (handles the upload flow; moderation is server-side)
- **Msg flow**: `SubmitUpload` -> API call -> poll status -> `GotUploadStatus` (pending/complete/failed)
- **RemoteData states**: NotAsked / Loading / Success (with results) / Failure (with rejection reason)

---

## 3. API Calls

### `POST /api/upload`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated` -> `:rate_limit_upload`
- **Controller**: `StacksWeb.UploadController.create/2`
- **Request body**: Multipart form with image file
- **Response (success)**: `{ image_id: uuid, status: "pending" }` — HTTP 202
- **Response (error)**: HTTP 422 on validation failure

### `GET /api/upload/:image_id/status`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UploadController.status/2`
- **Response**: `{ status: "pending" | "complete" | "failed", books: [...], error: "..." }` — HTTP 200

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` -> `RateLimiter(bucket: :upload)`
- **Visibility checks**: N/A — upload endpoint, not content display
- **Age gate**: Determined by the pipeline; books with adult BISAC codes get `visibility_tier: "age_gated"`
- **Ownership checks**: Upload associated with the authenticated user

---

## 5. Database Interactions

### Write: Create book with visibility tier
- **Table(s)**: `op.books`, `op.book_editions`
- **Operation**: INSERT (via `Books.create/1` or find existing via `Books.find_existing/1`)
- **Changeset validations**: Standard book changeset + `visibility_tier` field
- **Transaction**: Handled within `Books.create/1`
- **Denormalization**: `visibility_tier` stored on the book record

### Read: Check for existing book by ISBN
- **Table(s)**: `op.book_editions`
- **Query**: `Books.find_existing(isbn)` — looks up by ISBN in editions table
- **Schema module**: `Stacks.Books.Book`

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `book.created`
- **Aggregate**: `book` + book_id
- **Payload**: `{ isbn, title, visibility_tier, ... }`
- **Emitted by**: `Stacks.Books.create/1`
- **Emission method**: `Events.emit/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Enrichment.Handlers.BookCreatedHandler` — enqueues price scraping
- **Handler**: `Stacks.Enrichment.Handlers.AuthorDiscoveryHandler` — enqueues author source discovery
- **Handler**: `Stacks.Books.Handlers.CacheInvalidationHandler` — invalidates book detail cache
- **Handler**: `Stacks.Workers.DbtRefreshHandler` — refreshes dbt models

---

## 7. Background Jobs (Oban)

### IdentifyBookJob
- **Worker**: `Stacks.Workers.IdentifyBookJob`
- **Queue**: `:default`
- **Args**: `%{ "image_id" => uuid, "user_id" => uuid, "storage_key" => key, ... }` — the worker resolves a presigned URL via `Stacks.Storage` before invoking the pipeline
- **Max attempts**: Configurable
- **What it does**: Calls `Stacks.Moderation.run_pipeline/1` which:
  1. Calls `AIClient.call_vision("analyze", %{image_url: url})` — maps to `POST /analyze` on the sidecar (one request that returns both classification and book candidates)
  2. On `CLASSIFICATION_RESULT_BOOK` with a non-empty `books` list, expands compound candidates (titles joined with " OR ")
  3. For each candidate: resolves ISBN (direct from `potential_isbns` or via `ISBNResolver.search_by_title/3`)
  4. Maps subjects to BISAC codes via `subjects_to_bisac/1`
  5. Determines visibility tier via `determine_visibility_tier/1`:
     - Adult BISAC codes (FIC005000, FIC027000, FIC069000) -> `"age_gated"`
     - All others -> `"public"`
  6. Creates or finds the book via `Books.create/1` or `Books.find_existing/1`
- **On success**: Book(s) created, events emitted, upload status set to "complete"
- **On failure**: Upload status set to "failed" with reason

---

## 8. External Service Calls

### Vision sidecar (Python/FastAPI)
- **Service**: Vision sidecar (`apps/vision/`)
- **Endpoint**: `POST /analyze` — single fused classify + extract call. The sidecar still exposes `POST /classify` and `POST /extract` for direct/legacy use, but the moderation pipeline uses `/analyze` only.
- **Client module**: `Stacks.AI.Client` (`endpoint_path("analyze")` → `/analyze`)
- **Auth**: HMAC (`X-Internal-Token`)
- **Circuit breaker**: Fuse on the vision client
- **Fallback**: Pipeline fails; upload marked as failed
- **Mock in test**: Configurable via Application env

### Open Library / Google Books (ISBN resolution)
- **Service**: Open Library API, Google Books API
- **Client module**: `Stacks.Books.ISBNResolver`
- **Auth**: None (Open Library) / API key (Google Books)
- **Fallback**: If one service fails, tries the other

---

## 9. Storage (R2 / Local)

### Image upload
- **Operation**: Upload (before pipeline runs)
- **Key pattern**: `uploads/{image_id}`
- **Module**: `Stacks.Storage`
- **Backend**: `Storage.R2` (prod) / `Storage.Local` (dev) / `Storage.Mock` (test)
- **TTL**: 30-day retention (GDPR)

### Presigned URL for vision
- **Operation**: Presigned URL generation
- **Key pattern**: Same as upload key
- **TTL**: 900s (15 minutes)

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: Invalidated on `book.created` via `CacheInvalidationHandler`
- **Key**: Book ID
- **Invalidation trigger**: `book.created` event

---

## 11. dbt Model Dependencies

### `int_book_detail_view`
- **Model**: `int_book_detail_view`
- **Trigger**: `placement.created` via `DbtRefreshHandler`
- **Materialisation**: Intermediate
- **Consumer**: `mart_enrichment_gaps`, `mart_platform_searchable`

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Initializes upload form
- **API calls on init**: None
- **Initial model state**: Empty form, no image selected

### Update cycle
- **Msg**: `ImageSelected` -> stores file reference
- **Msg**: `SubmitUpload` -> `POST /api/upload` -> receives `image_id`
- **Msg**: `GotUploadStatus` -> polls `GET /api/upload/:image_id/status`
- **Msg**: Status transitions: pending -> complete (shows books) or failed (shows error with reason)

### View
- **Key elements**:
  - Upload form with file input
  - Processing state: spinner with "Identifying books..."
  - Success: List of identified books with covers
  - Failure: Specific rejection message ("This doesn't appear to be a book", "Could not identify an ISBN")
  - Age-gated books: Noted with visibility tier indicator
- **ARIA attributes**: Standard form accessibility
- **CSS classes**: `page--upload`, upload-specific classes

---

## 13. Operational Metrics

- **Oban job counts for `IdentifyBookJob`**: enqueued, completed, failed, retried — tracked via `mart_job_stats` and Oban telemetry
- **Vision sidecar call counts and latencies**: `POST /analyze` duration, success/failure rates. One call per upload (the sidecar internally short-circuits the extract step when classification is not BOOK).
- **Circuit breaker state**: vision client fuse events — open/closed transitions when sidecar is unavailable or slow
- **ISBN resolution call counts**: Open Library and Google Books API hit rates, latencies, and fallback rates (one fails, other succeeds)
- **Pipeline step pass/fail rates**: Step 1 (is_book) rejection rate, Step 2 (ISBN extraction) failure rate, Step 3 (BISAC classification) age-gate rate
- **Event handler execution times**: `BookCreatedHandler`, `AuthorDiscoveryHandler`, `CacheInvalidationHandler`, `DbtRefreshHandler` latencies on `book.created` events
- **Compound title expansion rate**: percentage of vision extractions that return " OR "-joined titles requiring splitting

---

## 14. Performance & Usability Metrics

- **Upload-to-result latency**: elapsed time from `POST /api/upload` (202 Accepted) to upload status transitioning to `complete` or `failed` — measures full pipeline duration
- **Classification accuracy**: percentage of uploads correctly classified as book vs not_book — derived from user feedback/re-uploads after rejection
- **ISBN resolution success rate**: percentage of identified books that successfully resolve to a verified ISBN via Open Library or Google Books
- **Age-gate precision**: percentage of books correctly flagged as age-gated by BISAC code matching (FIC005000, FIC027000, FIC069000)
- **Review summary quality** (downstream): LLM response parse success rate for summaries generated from vision-extracted book data
- **User retry rate**: percentage of users who re-upload after a rejection — indicates unclear rejection messages or false positives

---

## 15. Cost Tracking

- **Modal GPU** (vision sidecar): per-second billing for GPU compute. Together AI vision model inference at ~$0.18 per 1M tokens. Each image classification + extraction: ~1000-2000 tokens input (image) + ~200 tokens output. Estimated cost per upload: $0.0004-$0.001.
- **Fly.io compute** (core app): Oban `VisionProcessJob` worker, pipeline orchestration, ISBN resolution HTTP calls. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Fly.io compute** (vision sidecar): Python/FastAPI sidecar running on Fly.io. Separate machine from core. Cost depends on machine size; no auto-stop for always-available classification.
- **Open Library API**: free, no cost. Rate-limited but no billing.
- **Google Books API**: free tier allows 1000 requests/day. No cost for typical single-user usage.
- **R2 storage**: image uploads stored in Cloudflare R2. Free tier: 10GB storage, 10M reads/month, 1M writes/month. Paid: $0.015/GB/month storage.
- **Neon compute**: book creation queries, ISBN lookups, edition inserts, and dbt refreshes. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
