# US-1.1.7 — Bulk Image Upload with Grouping and Review

## 1. User Story

> **As a** user, **I want to** drop a pile of book photos at once and review what the system found before anything lands on my shelves **so that** I can add a batch of books efficiently without losing control over what gets added.

**What the user wants to accomplish:** Upload many images in one go -- including multiple photos of the same book (front, back, spine), photos of different books, screenshots of reading lists, and shelfie photos containing several titles -- and have the system do the grouping work, then confirm the results before committing.

**How they accomplish it:**
1. The user clicks "Add Books" and selects multiple images, or drags a batch onto the drop zone.
2. The system accepts all images immediately and begins processing in parallel. A progress indicator shows how many images are being processed.
3. In the background, each image is classified and partially extracted. Images that resolve to the same ISBN, or have strongly overlapping title/author signals, are grouped together automatically. A shelfie or screenshot yielding multiple distinct books produces one candidate per identified book.
4. When processing is complete, the user is taken to a Review screen.
5. The Review screen shows one card per detected book (Confirmed/Ambiguous/Rejected states).
6. The user reviews, dismisses any misidentifications, and selects which shelf each confirmed book should land on.
7. The user taps "Add N Books to Shelves". Each confirmed book goes through the standard ISBN resolution and duplicate detection pipeline.
8. Successfully added books appear on their chosen shelves.

---

## 2. UI Interaction Flow

### Happy Path (as designed in user stories)
This story describes a full batch upload with review screen. The current codebase implements a **single-image upload flow** that handles the multi-book-from-one-image case (e.g., a shelfie or screenshot listing multiple books), but does not yet implement the full batch review screen UX.

**What IS implemented:**
1. The drop zone accepts a single file (`Decode.index 0 File.decoder` -- takes the first file from a drop event).
2. The `IdentifyBookJob` and `Moderation.run_pipeline/1` support multiple books from a single image:
   - Vision sidecar `POST /extract` can return multiple books in the `"books"` array
   - `expand_compound_candidates/1` splits titles joined by " OR "
   - `resolve_and_store_all/2` iterates all candidates, creating a book for each resolved ISBN
   - `mark_resolved/2` stores all `book_ids` (array) on the uploaded image
3. The Elm frontend handles multiple book IDs in the poll response:
   - When `bookIds` has multiple entries, `Api.getBook` is called for each in parallel
   - `GotIdentifiedBook` accumulates results in `collectedBooks` and tracks remaining in `pendingBookIds`
   - When all are fetched, `result = Identified books` (a list)
   - `viewIdentified` renders a list of identified books with "View Book" links

**What is NOT yet implemented:**
- Multi-file drop/select (file picker currently takes the first file only)
- Review screen with per-book shelf selection (the multi-book view shows books as a flat list with "View Book" links, not the full review card grid with per-book shelf pickers)
- Confidence tiers (Confirmed/Ambiguous/Rejected card states)
- Batch "Add N Books to Shelves" action
- Per-book dismiss functionality on the review screen

### Elm State Machine (current implementation)
- **Page module**: `Page.Upload`
- **Model fields for multi-book**: `pendingBookIds : List String`, `collectedBooks : List Book`
- **Msg flow for multi-book from single image**:
  - `StatusReceived (Ok {Resolved, bookIds: [id1, id2, ...]})` -> sets `pendingBookIds = [id1, id2, ...]`, dispatches `Api.getBook` for each via `Cmd.batch`
  - `GotIdentifiedBook bookId (Ok response)` -> adds `response.book` to `collectedBooks`, removes `bookId` from `pendingBookIds`
  - When `pendingBookIds` is empty -> `result = Identified allCollectedBooks`
  - If some fetches fail, those are silently dropped; the successfully fetched books are still shown

---

## 3. API Calls

### `POST /api/upload`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:rate_limit_upload`
- **Controller**: `StacksWeb.UploadController.create/2`
- **Note**: Currently accepts a single `Plug.Upload` file per request. Bulk upload would require either multiple sequential calls or a new batch endpoint.

### `POST /api/upload/identify` (synchronous alternative)
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:rate_limit_upload`
- **Controller**: `StacksWeb.UploadController.identify/2`
- **Request body**: `{ image_b64: "..." }` or `{ image_url: "..." }`
- **Response**: `{ status: "identified", candidates: [...] }` -- HTTP 200
- **Note**: This synchronous endpoint calls `Books.identify/2` inline (no Oban job). It could power a batch flow where the client sends each image and gets candidates back immediately.

### `GET /api/upload/:image_id/status`
- Same as US-1.1.1, but the response `book_ids` array may contain multiple UUIDs

### `GET /api/books/:id` (called per identified book)
- Same as US-1.1.1, called once per book in the batch

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` -> `RateLimiter (bucket: :upload)`
- **Rate limiting**: The `:upload` rate limit bucket applies. For batch upload, each `POST /api/upload` call would count against the rate limit.

---

## 5. Database Interactions

### Write: Store multiple books from one image
- **Table(s)**: `op.books`, `op.book_editions` (one pair per identified book)
- **Operation**: INSERT (via `Books.create/1` for each, within `Moderation.store_book/3`)
- **Transaction**: Each book creation is its own `Ecto.Multi` transaction

### Write: Update uploaded_image with multiple book_ids
- **Table(s)**: `op.uploaded_images`
- **Operation**: UPDATE
- **Fields**: `book_ids = [uuid1, uuid2, ...]` (array of binary_ids), `book_id = uuid1` (first book for backwards compat)
- **Performed by**: `IdentifyBookJob.mark_resolved/2`

### Read: Poll with multiple book_ids
- **Table(s)**: `op.uploaded_images`
- **Query**: Same as US-1.1.1 but returns `book_ids` array
- **Duplicate check**: `Enum.any?(effective_ids, &Shelving.book_on_any_shelf?(user.id, &1))` -- checks ALL identified books against the user's shelves

---

## 6. Event Flow & Lifecycle

### Events Emitted
For each successfully identified and created book:
- `book.created` -- per book
- `image.resolved` -- once, with `%{book_count: N}`

### Event Handlers Triggered
Same as US-1.1.1 per book:
- `BookCreatedHandler`, `AuthorDiscoveryHandler`, `CacheInvalidationHandler` for each `book.created`

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
- **Queue**: `:vision`
- **Max attempts**: 3
- **Multi-book flow**:
  1. Same classification step as US-1.1.1
  2. `extract_all_candidates_url/1` returns multiple candidates from the vision sidecar
  3. `expand_compound_candidates/1` splits compound titles (e.g., "Book A OR Book B")
  4. `resolve_and_store_all/2` iterates each candidate:
     - Resolves ISBN (direct or via title search)
     - Creates book if not already in catalogue (`Books.find_existing/1` check)
     - Collects all successfully created/found books
  5. `mark_resolved(image_id, book_ids)` stores the full list
  6. Returns `:ok` if at least one book was resolved; `{:cancel, ...}` if none resolved

---

## 8. External Service Calls

### Vision Sidecar -- Extraction (multi-book)
- **Service**: Modal vision sidecar
- **Endpoint**: `POST /extract`
- **Response**: `%{"books" => [candidate1, candidate2, ...]}` -- array with one entry per detected book in the image
- **Each candidate**: `%{"title" => str, "author" => str, "potential_isbns" => [str], "raw_text" => str, "confidence" => float}`

### Open Library / Google Books
- Called once per candidate ISBN, same as US-1.1.1

---

## 9. Storage (R2 / Local)

Same as US-1.1.1 -- one uploaded image, one storage key `uploads/{image_id}`.

For a true multi-file batch upload, each file would need its own storage key and `uploaded_images` record.

---

## 10. Cache Interactions

Same as US-1.1.1 per created book.

---

## 11. dbt Model Dependencies

Same as US-1.1.1. Each created book triggers the standard `book.created` -> `DbtRefreshHandler` chain.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated

### Init
Same as US-1.1.1.

### Update cycle (multi-book case)

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `StatusReceived (Ok {Resolved, bookIds: [id1, id2, ...]})` | `pendingBookIds = [id1, id2, ...]`, `collectedBooks = []` | `Cmd.batch [Api.getBook id1 ..., Api.getBook id2 ...]` | `NoOut` |
| `GotIdentifiedBook id1 (Ok resp)` | `collectedBooks = [book1]`, `pendingBookIds = [id2, ...]` | None | `NoOut` |
| `GotIdentifiedBook id2 (Ok resp)` | `collectedBooks = [book1, book2]`, `pendingBookIds = []` | None | `NoOut` |
| (when pendingBookIds empty, multiple books) | `result = Identified [book1, book2]`, `collectedBooks = []`, `pendingBookIds = []` | None | `NoOut` |

Note: For a single identified book, the step transitions to `Verifying singleBook`. For multiple books, the step stays at `Uploading` and the `Identified books` result is shown via `viewIdentified`.

### View (multi-book)
- **Rendered by**: `viewIdentified books`
- **Key elements**:
  - `h2`: "Books Identified!" (plural when `List.length books > 1`)
  - `ul.upload-result__book-list`: one `li.upload-result__book-item` per book, each showing:
    - `p.upload-result__book-title`: book title
    - `p.upload-result__book-author`: author name (via `authorName book`)
    - `a.btn.btn--primary`: "View Book" link to `Route.BookDetail book.id`
  - "Try Another" ghost button (`Reset`)
- **CSS classes**: `upload-result`, `upload-result--identified`, `upload-result__book-list`, `upload-result__book-item`, `upload-result__book-title`, `upload-result__book-author`
- **ARIA attributes**: `role="status"` on the result container

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `upload_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/upload`), status_code (202, 422, 500)

- **Metric name**: `identify_request_count` (synchronous alternative)
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/upload/identify`), status_code (200, 422, 500)

- **Metric name**: `upload_status_poll_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/upload/:image_id/status`), status_code (200)

- **Metric name**: `book_detail_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/books/:id`), status_code (200, 404). Note: called once per identified book — may be N calls for multi-book results.

### Oban Job Metrics

- **Metric name**: `identify_book_job_enqueued`
- **Source**: Oban Telemetry via `[:oban, :job, :start]`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker (`Stacks.Workers.IdentifyBookJob`)

- **Metric name**: `identify_book_job_completed`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker, state (completed, cancelled)

- **Metric name**: `identify_book_job_books_per_image`
- **Source**: Not yet instrumented. Would need a Telemetry event in `IdentifyBookJob.mark_resolved/2` reporting the count of `book_ids`.
- **Type**: histogram
- **Labels/dimensions**: queue (`:vision`)

- **Metric name**: `vision_queue_depth`
- **Source**: Oban queue inspection
- **Type**: gauge
- **Labels/dimensions**: queue (`:vision`). Note: bulk uploads may cause queue depth spikes.

### Rate Limiting Metrics

- **Metric name**: `rate_limit_hit_count`
- **Source**: Not yet instrumented. `RateLimiter` plug in the `:rate_limit_upload` pipeline.
- **Type**: counter
- **Labels/dimensions**: bucket (`:upload`), user_id. Note: batch uploads of N images would consume N rate limit tokens.

### Circuit Breaker Metrics

- **Metric name**: `vision_fuse_state`
- **Source**: `:fuse.ask(:vision_service, :sync)` — polled periodically.
- **Type**: gauge
- **Labels/dimensions**: fuse_name (`:vision_service`). Note: bulk uploads increase the risk of fuse trips due to sustained load.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`image.submitted`, `image.resolved`, `book.created`). Note: `book.created` fires once per identified book — a single image may trigger multiple `book.created` events.

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source, operation. Note: multi-book results generate more DB queries (one `Books.create/1` Multi per book).

---

## 14. Performance & Usability Metrics

### End-to-End Pipeline Timing

- **Metric name**: Upload-to-all-books-identified total time
- **How measured**: Delta between `image.submitted` and `image.resolved` event timestamps. Not yet instrumented as a real-time metric.
- **Target/SLA**: p50 < 40s, p95 < 90s. Multi-book identification takes longer than single-book because `resolve_and_store_all/2` iterates all candidates sequentially.
- **Dashboard**: Upload pipeline section

- **Metric name**: Per-candidate resolution time
- **How measured**: Not yet instrumented. Would need timing within `resolve_and_store_all/2` for each candidate.
- **Target/SLA**: p50 < 3s per candidate (ISBN lookup + book creation)
- **Dashboard**: Vision pipeline section

### Multi-Book Specific Metrics

- **Metric name**: Books identified per image
- **How measured**: `book_count` from `image.resolved` event payload in `event_log`. Also derivable from `length(book_ids)` in `uploaded_images` table.
- **Target/SLA**: Informational — expected 1-5 books per image for shelfie photos, 1-10 for reading list screenshots
- **Dashboard**: Upload pipeline section

- **Metric name**: Candidate-to-resolved-book ratio
- **How measured**: Not yet instrumented. Would need `count(candidates from extract) / count(successfully resolved books)` within `IdentifyBookJob`.
- **Target/SLA**: > 50% of extracted candidates should resolve to books
- **Dashboard**: Vision pipeline section

### Vision Pipeline Timing

- **Metric name**: Vision extraction time (multi-book)
- **How measured**: `Stacks.AI.Client.call_vision("extract_isbn", ...)` duration. Not yet instrumented separately.
- **Target/SLA**: p50 < 8s, p95 < 20s (may be longer for images with many books)
- **Dashboard**: Vision pipeline section

### API Response Latencies

- **Metric name**: Parallel book detail fetch time
- **How measured**: Client-side: time from dispatching `Cmd.batch [Api.getBook ...]` to last `GotIdentifiedBook` received. Not yet instrumented.
- **Target/SLA**: p95 < 2s for up to 5 books fetched in parallel
- **Dashboard**: Upload pipeline section

### User Experience Metrics

- **Metric name**: Multi-book upload completion rate
- **How measured**: Not yet instrumented. Would track how many multi-book results lead to user viewing at least one identified book.
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

- **Metric name**: Batch review abandoned rate
- **How measured**: Not yet instrumented. Would need tracking when users leave the multi-book result view without acting.
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

---

## 15. Cost Tracking

### Vision Classification (Modal GPU)
- **Service**: Modal (A10G GPU, Qwen2.5-VL-7B-Instruct)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("is_book", ...)` — one classification per image
- **Unit cost**: ~R0.50-R2.50 per image classification
- **Volume estimate**: 1 call per uploaded image (not per book in the image). For true multi-file batch upload, each file incurs its own classification.
- **Tracked by**: `Stacks.AI.BudgetTracker` (`:modal` provider), `op.platform_costs`, `mart_cost_tracking`

### Vision Extraction (Modal GPU)
- **Service**: Modal (same GPU instance)
- **Trigger**: `Stacks.AI.Client.call_vision("extract_isbn", ...)` — one extraction per image
- **Unit cost**: Included in classification cost (same Modal container session). Multi-book extraction may take longer (5-15s vs 3-8s for single book), slightly increasing GPU cost.
- **Volume estimate**: 1 call per image that passes classification
- **Tracked by**: `Stacks.AI.BudgetTracker`

### Open Library API
- **Service**: Open Library
- **Trigger**: `ISBNResolver.resolve/1` and `ISBNResolver.search_by_title/3` — called once per candidate book
- **Unit cost**: Free (public API)
- **Volume estimate**: 1-10 calls per image (one per extracted candidate). Shelfie images with many books generate more calls.
- **Tracked by**: No cost tracking needed

### Google Books API
- **Service**: Google Books
- **Trigger**: `ISBNResolver.resolve/1` (fallback from Open Library)
- **Unit cost**: Free tier (1,000 requests/day)
- **Volume estimate**: Called for candidates that fail Open Library lookup. Batch uploads may consume more daily quota.
- **Tracked by**: Monitor daily quota — batch uploads are the highest risk for quota exhaustion

### R2 Object Storage
- **Service**: Cloudflare R2
- **Trigger**: `Stacks.Storage.upload_image/2` — one upload per image file
- **Unit cost**: Class A writes: $0.0036/1,000 requests. Storage: $0.015/GB/month.
- **Volume estimate**: For true multi-file batch, N writes for N images. Currently single-image only.
- **Tracked by**: `op.platform_costs` (category: "infrastructure", service: "r2")

### Per-Batch-Upload Cost Estimate (Current: Single Image, Multiple Books)
- Classification + extraction: ~R0.50-R2.50 (one image)
- ISBN resolution: free, but 1-10 API calls per image
- R2 storage: ~R0.00007 per image
- **Total per multi-book image: ~R0.50-R2.50 (~$0.03-$0.14 USD) regardless of how many books are identified**

### Per-Batch-Upload Cost Estimate (Future: Multiple Images)
- Classification + extraction: ~R0.50-R2.50 PER IMAGE
- ISBN resolution: free
- R2 storage: ~R0.00007 per image
- **Total for N images: ~R0.50N-R2.50N (e.g., 10 images = R5-R25)**
- **Budget concern**: A batch of 10 images could consume the entire daily R5 BudgetTracker limit. Rate limiting and budget checks are critical for batch upload.

Note: The multi-book-from-single-image path is the most cost-efficient batch approach — one GPU call identifies multiple books. True multi-file batch upload would be significantly more expensive and should be rate-limited appropriately.
