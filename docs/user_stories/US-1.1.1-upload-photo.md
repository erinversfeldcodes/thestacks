# US-1.1.1 — Upload a Photo to Add a Book

## 1. User Story

> **As a** user, **I want to** upload a photo or screenshot **so that** the system can identify the book and add it to my collection without manual data entry.

**What the user wants to accomplish:** Get a book into their collection by photographing it or sharing a screenshot — cover, spine, back cover, mirrored selfie-mode shot, or a screenshot from TikTok, Instagram, a reading list, or anywhere a book title or author appears as text.

**How they accomplish it:**
1. The user navigates to the Upload page (`/upload`) via the "Add a Book" link in the top navigation.
2. A drop zone is displayed. Drag-and-drop and file picker are both supported. Accepted inputs include photos of covers, spines, back covers, mirrored or rotated photos, and screenshots containing book titles or recommendations.
3. The user drops or selects one image. (For bulk upload of multiple images, see US-1.1.7.)
4. The system pre-processes the image before sending it to the vision model: orientation is corrected using EXIF data, horizontal mirroring is detected and corrected, and the image is re-encoded to a canonical format with EXIF stripped.
5. The system sends the pre-processed image to an open-source vision model (Qwen2.5-VL-7B-Instruct hosted on Modal) to extract visible text — title, author, ISBN barcode, publisher information. If the image contains multiple identifiable books, all are extracted.
6. The extracted text is used to query the Open Library API and Google Books API to resolve an ISBN.
7. **Verification step:** The system presents a side-by-side view showing the uploaded image on the left and the identified book on the right (cover image, title, author, ISBN). The message reads: "We think this is..." followed by the book details. The user confirms or rejects the identification.
8. **Shelf placement step:** On confirmation, the user is prompted to choose which shelf to place the book on. The default is WishList. A shelf picker displays all five bookshelves (Library, AntiLibrary, WishList, Reading Pile, Looking for a Home) as labelled options.
9. The book is created with full metadata and its spine slides into place on the chosen shelf with a soft thud animation. The user is shown a brief success state before being offered "Add another" or "View on shelf".

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/upload`.
2. User sees the drop zone with "Drag a photo of a book cover here" prompt and a "Choose Photo" button. Below the drop zone, an "Enter ISBN manually instead" link is visible.
3. User drops or selects an image file (`image/*` MIME type).
4. The drop zone shows a spinner with "Processing image..." while upload is in flight (`uploadState = Loading`), then continues showing the spinner while polling (`uploadState = Success imageId`).
5. Polling completes with `Resolved` status. The system fetches the identified book via `Api.getBook`.
6. **Verification view** (`step = Verifying book`): "We think this is..." heading, book cover image (or "No cover" placeholder), title, author. Two buttons: "Yes, that's it" and "No, try again".
7. User clicks "Yes, that's it" (`ConfirmIdentification`). State transitions to `step = ChoosingShelf book`.
8. **Shelf picker view**: heading "Add "[Title]" to a shelf", five shelf buttons (Library, Antilibrary, Wish List, Reading Pile, Looking for a Home). WishList is pre-selected. An "Add to Wish List" primary button and "Cancel" ghost button.
9. User optionally changes shelf selection via `ShelfSelected`, then clicks "Add to [Shelf]" (`ConfirmPlacement`).
10. API call places the book on the chosen shelf. On success, `step = Complete book shelfName`.
11. **Success view**: "[Title] added to [Shelf Name]". Two buttons: "Add another" (`Reset`) and "View on shelf" (`GoToShelf`).

### Sad Paths
- **Upload HTTP failure**: `uploadState = Failure err` -- "Upload failed. Please try again." with "Try Again" button.
- **Poll timeout** (150 polls at 2s intervals = ~300s): `result = IdentificationFailed` -- "Could Not Identify Book" with "Try Another Photo" and "Enter ISBN Manually" buttons.
- **ISBN not found on vision pipeline**: poll returns `Rejected` status -- same IdentificationFailed view.
- **Not a book image**: poll returns `Resolved` with empty `bookIds` -- `result = NotABook` -- "That Doesn't Look Like a Book" with "Try Again" button.
- **Placement API failure**: `placementState = Failure err` -- "Failed to add book. Please try again." with retry button.
- **Unauthenticated**: "You need to sign in to add books." with "Sign In" link to `/login`.

### Elm State Machine
- **Page module**: `Page.Upload`
- **Model fields involved**: `file`, `uploadState`, `pollCount`, `result`, `step`, `selectedShelf`, `placementState`, `pendingBookIds`, `collectedBooks`
- **Msg flow**:
  - `GotFile file` -> sets `uploadState = Loading`, calls `Api.uploadImage`
  - `UploadAccepted (Ok imageId)` -> sets `uploadState = Success imageId`, starts `sleepThenPoll`
  - `CheckStatus` -> calls `Api.pollUploadStatus`
  - `StatusReceived (Ok {status: Resolved, bookIds, isDuplicate})` -> calls `Api.getBook` for each ID
  - `GotIdentifiedBook bookId (Ok response)` -> when all fetched, sets `result = Identified`, `step = Verifying book`
  - `ConfirmIdentification` -> `step = ChoosingShelf book`
  - `ShelfSelected shelf` -> updates `selectedShelf`
  - `ConfirmPlacement` -> calls `Api.placeBook`
  - `PlacementCompleted (Ok _)` -> `step = Complete book shelfName`
- **RemoteData states**: `uploadState` goes NotAsked -> Loading -> Success (imageId) or Failure; `placementState` goes NotAsked -> Loading -> Success or Failure
- **OutMsg pattern**: `NavigateTo Route.Route` on `GoToShelf` (propagated to Main for navigation)

---

## 3. API Calls

### `POST /api/upload`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:rate_limit_upload`
- **Controller**: `StacksWeb.UploadController.create/2`
- **Request body**: multipart form with `image` file part
- **Response (success)**: `{ status: "accepted", image_id: "<uuid>" }` -- HTTP 202
- **Response (error)**: `{ error: "upload_failed" }` -- HTTP 500; `{ error: "no image provided" }` -- HTTP 422

### `GET /api/upload/:image_id/status`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UploadController.status/2`
- **Request body**: None
- **Response (success)**: `{ image_id, status: "pending"|"resolved"|"rejected", book_id, book_ids, rejection_reason, is_duplicate }` -- HTTP 200
- **Response (error)**: `{ error: "not found" }` -- HTTP 404; `{ error: "invalid image_id" }` -- HTTP 422

### `GET /api/books/:id`
- **Auth**: Optional (Bearer token)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Request body**: None
- **Response (success)**: `{ book: { id, title, description, author, editions, edition_count, primary_edition, ... }, placement, my_writing }` -- HTTP 200
- **Response (error)**: `{ error: "not_found" }` -- HTTP 404

### `POST /api/bookshelves/:bookshelf_name/placements`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.create/2`
- **Request body**: `{ book_id: "<uuid>" }`
- **Response (success)**: `{ placement: { id, book_id, bookshelf_name, formats, ... } }` -- HTTP 201
- **Response (error)**: HTTP 422 on validation failure

---

## 4. Auth & Middleware Guards

- **Plugs fired** (upload): `SecurityHeaders` -> `AuthPipeline` -> `RateLimiter (bucket: :upload)`
- **Plugs fired** (status poll): `SecurityHeaders` -> `AuthPipeline`
- **Plugs fired** (book detail): `SecurityHeaders` -> `OptionalAuthPipeline`
- **Plugs fired** (placement): `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: `Visibility.resolve_visibility/2` is called in `BookController.show/2` -- returns `:hidden` for books the viewer cannot see.
- **Age gate**: `AgeGate.enforce/2` is called in `BookController.show/2` -- halts the conn if age verification is required and not yet provided.
- **Ownership checks**: `UploadController.status/2` checks `Shelving.book_on_any_shelf?(user.id, book_id)` to set `is_duplicate` flag. Placement creation in `Shelving.place_book/3` verifies user owns the target bookshelf.

---

## 5. Database Interactions

### Write: Store uploaded image record
- **Table(s)**: `op.uploaded_images`
- **Operation**: INSERT
- **Changeset validations**: required `status`, `uploaded_at`, `expires_at`; `status` must be in `~w(pending resolved rejected)`
- **Schema module**: `Stacks.Books.UploadedImage`
- **Fields set**: `id` (generated UUID), `storage_path` ("uploads/{image_id}"), `status` ("pending"), `uploaded_at` (now), `expires_at` (now + 30 days)
- **Transaction**: Not wrapped in Multi; standalone insert

### Write: Create book (work) + primary edition
- **Table(s)**: `op.books`, `op.book_editions`
- **Operation**: INSERT (both)
- **Changeset validations**:
  - Book: `title` required; `visibility_tier` must be "public" or "age_gated"
  - BookEdition: `isbn` and `book_id` required; ISBN format validated via regex `^\d{10}(\d{3})?$`; ISBN checksum validated; `isbn` unique constraint
- **Transaction**: `Ecto.Multi` with steps: `:book` (insert), `:edition` (insert, references book.id), `:emit_event`
- **Schema modules**: `Stacks.Books.Book`, `Stacks.Books.BookEdition`

### Write: Update uploaded_image to resolved
- **Table(s)**: `op.uploaded_images`
- **Operation**: UPDATE
- **Fields set**: `status` = "resolved", `book_id` = first book UUID, `book_ids` = all book UUIDs, `updated_at`
- **Performed by**: `IdentifyBookJob.mark_resolved/2` via `Repo.update_all`

### Read: Poll image status
- **Table(s)**: `op.uploaded_images`
- **Query**: `SELECT status, book_id, book_ids, rejection_reason FROM op.uploaded_images WHERE id = ?`
- **Schema module**: Raw Ecto query (not schema-based), using `from(i in "uploaded_images", ...)`

### Read: Check duplicate
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Shelving.book_on_any_shelf?(user_id, book_id)` -- `EXISTS` query joining placements to bookshelves, filtering by user_id and book_id, where `removed_at IS NULL`
- **Schema module**: `Stacks.Shelving.Placement`, `Stacks.Shelving.Bookshelf`

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `image.submitted`
- **Aggregate**: `image` / image.id
- **Payload**: `%{storage_path: "uploads/{image_id}"}`
- **Emitted by**: `Books.store_upload/2`
- **Emission method**: `Events.emit_safe/1`

#### `image.resolved`
- **Aggregate**: `image` / image_id
- **Payload**: `%{book_count: N}`
- **Emitted by**: `IdentifyBookJob.mark_resolved/2`
- **Emission method**: `Events.emit_safe/1`

#### `book.created`
- **Aggregate**: `book` / book.id
- **Payload**: `%{isbn: isbn, title: title}`
- **Emitted by**: `Books.create/1` (via Multi `:emit_event` step)
- **Emission method**: `Events.emit_safe/1`

#### `placement.created`
- **Aggregate**: `placement` / placement.id
- **Payload**: placement details
- **Emitted by**: `Shelving.place_book/3`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered

#### `book.created`
- **Handlers**: `Stacks.Enrichment.Handlers.BookCreatedHandler`, `Stacks.Enrichment.Handlers.AuthorDiscoveryHandler`, `Stacks.Books.Handlers.CacheInvalidationHandler`
- **Actions**: Enqueue enrichment jobs (price scraping, review scraping), discover author metadata, invalidate `BookDetailCache`

#### `placement.created`
- **Handlers**: `Stacks.Feeds.Handlers.PlacementHandler`, `Stacks.Workers.DbtRefreshHandler`
- **Actions**: Update activity feed, trigger dbt model refresh

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
- **Queue**: `:vision`
- **Args**: `%{user_id: uuid, image_id: uuid, storage_key: "uploads/{image_id}"}`
- **Max attempts**: 3
- **Uniqueness**: None configured explicitly
- **What it does**:
  1. Fetches a presigned URL for the image from `Stacks.Storage.get_image_url/1`
  2. Calls `Stacks.Moderation.run_pipeline/1` which:
     a. Calls vision sidecar `POST /classify` to check if the image is a book
     b. Calls vision sidecar `POST /extract` to extract book candidates
     c. Expands compound candidates (titles joined by " OR ")
     d. For each candidate, resolves ISBN directly or via `ISBNResolver.search_by_title/3`
     e. For each resolved ISBN, calls `Books.resolve_isbn/1` for metadata
     f. Checks `Books.find_existing/1` to avoid duplicates
     g. Creates book (work + edition) via `Books.create/1` if new
  3. On success: calls `mark_resolved/2` to update `op.uploaded_images`
  4. On `:not_a_book`: calls `mark_rejected/2` with reason "not_a_book" and returns `{:cancel, ...}`
  5. On `:isbn_not_found`: calls `mark_rejected/2` with reason "isbn_not_found" and returns `{:cancel, ...}`
- **On success**: `image.resolved` event emitted; book(s) available for polling
- **On failure**: Oban retries up to 3 times for transient errors; `:cancel` for permanent failures (not_a_book, isbn_not_found)

---

## 8. External Service Calls

### Vision Sidecar -- Classification
- **Service**: Modal vision sidecar (Qwen2.5-VL-7B-Instruct)
- **Endpoint**: `POST /classify`
- **Client module**: `Stacks.AI.Client` via `call_vision("is_book", payload)`
- **Auth**: HMAC (`X-Internal-Token` header: `<timestamp>.<HMAC-SHA256>`)
- **Circuit breaker**: `:vision_service` fuse
- **Response**: `%{"classification" => "book"|"not_book"|"ambiguous", "confidence" => float, "model_used" => str}`
- **Fallback**: Returns `{:error, :circuit_open}` when fuse is blown
- **Mock in test**: `Stacks.AI.MockClient` (configured via `config :core, :vision_client`)

### Vision Sidecar -- Extraction
- **Service**: Modal vision sidecar
- **Endpoint**: `POST /extract`
- **Client module**: `Stacks.AI.Client` via `call_vision("extract_isbn", payload)`
- **Auth**: Same HMAC scheme
- **Response**: `%{"books" => [%{"title" => str, "author" => str, "potential_isbns" => [str], "raw_text" => str, "confidence" => float}]}`

### Open Library API
- **Service**: Open Library
- **Client module**: `Stacks.Books.ISBNResolver`
- **Endpoint**: ISBN lookup and title search
- **Auth**: None (public API)
- **Fallback**: Falls through to Google Books API on failure

### Google Books API
- **Service**: Google Books
- **Client module**: `Stacks.Books.ISBNResolver`
- **Auth**: API key
- **Fallback**: Returns `{:error, :not_found}` if both services fail

---

## 9. Storage (R2 / Local)

### Upload: Store user image
- **Operation**: upload
- **Key pattern**: `uploads/{image_id}`
- **Module**: `Stacks.Storage.upload_image/2`
- **Backend**: `Storage.R2` (prod) / `Storage.Local` (dev) / `Storage.Mock` (test)
- **Content type**: `image/jpeg` (default)

### Read: Generate presigned URL for vision pipeline
- **Operation**: presigned URL
- **Key pattern**: `uploads/{image_id}`
- **Module**: `Stacks.Storage.get_image_url/1`
- **TTL**: 900 seconds (15 minutes) default

### Cleanup on failure
- **Operation**: delete
- **Key pattern**: `uploads/{image_id}`
- **Module**: `Stacks.Storage.delete_image/1`
- **Trigger**: Called in `Books.store_upload/2` when the DB insert fails after storage upload succeeds

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: `put` (on book creation when detail is first fetched), `invalidate` (via `CacheInvalidationHandler` triggered by `book.created`)
- **Key**: book UUID
- **TTL**: Configured in `BookDetailCache` module
- **Invalidation trigger**: `book.created` event

- **Cache**: `BudgetTracker`
- **Operation**: `check_budget(:modal)` before every vision API call
- **Key**: `:modal`
- **Purpose**: Prevents runaway vision API costs

---

## 11. dbt Model Dependencies

- **Model**: `stg_books` -- staging model for `op.books`
- **Trigger**: `book.created` event -> `DbtRefreshHandler` (indirectly via `placement.created`)
- **Consumer**: `mart_community_read_count`, catalogue API

- **Model**: `stg_book_editions` -- staging model for `op.book_editions`
- **Consumer**: Book detail API

- **Model**: `stg_uploaded_images` -- staging model for `op.uploaded_images`
- **Consumer**: Metrics dashboard

- **Model**: `stg_bookshelf_placements` -- staging model for `op.bookshelf_placements`
- **Trigger**: `placement.created` event -> `DbtRefreshHandler`
- **Consumer**: Bookshelf API, feed

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated (UI shows sign-in prompt if unauthenticated; API calls require Bearer token)

### Init
- **`initPage` branch**: Creates `Page.Upload.init` model
- **API calls on init**: None (upload is user-initiated)
- **Initial model state**: `file = Nothing`, `uploadState = NotAsked`, `pollCount = 0`, `result = NoResult`, `step = Uploading`, `selectedShelf = "wishlist"`, `manualIsbn = ""`, `isDragging = False`, all RemoteData fields `NotAsked`

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `GotFile file` | `file = Just file`, `uploadState = Loading`, `step = Uploading`, `isDragging = False` | `Api.uploadImage file token UploadAccepted` | `NoOut` |
| `DragOver` | `isDragging = True` | None | `NoOut` |
| `DragLeave` | `isDragging = False` | None | `NoOut` |
| `FilepickerRequested` | (none) | `Select.files ["image/*"]` | `NoOut` |
| `UploadAccepted (Ok imageId)` | `uploadState = Success imageId` | `sleepThenPoll` (2000ms delay then `CheckStatus`) | `NoOut` |
| `UploadAccepted (Err err)` | `uploadState = Failure err` | None | `NoOut` |
| `CheckStatus` | `pollCount += 1` | `Api.pollUploadStatus imageId token StatusReceived` | `NoOut` |
| `StatusReceived (Ok {Resolved, bookIds})` | `pendingBookIds = ids` | `Api.getBook` for each ID | `NoOut` |
| `StatusReceived (Ok {Pending})` | (none) | `sleepThenPoll` | `NoOut` |
| `StatusReceived (Ok {Rejected})` | `result = IdentificationFailed` | None | `NoOut` |
| `GotIdentifiedBook id (Ok resp)` | When all fetched: `result = Identified [book]`, `step = Verifying book` | None | `NoOut` |
| `ConfirmIdentification` | `step = ChoosingShelf book` | None | `NoOut` |
| `RejectIdentification` | Resets to `init` | None | `NoOut` |
| `ShelfSelected shelf` | `selectedShelf = shelf` | None | `NoOut` |
| `ConfirmPlacement` | `placementState = Loading` | `Api.placeBook selectedShelf book.id token PlacementCompleted` | `NoOut` |
| `PlacementCompleted (Ok _)` | `step = Complete book selectedShelf`, `placementState = Success` | None | `NoOut` |
| `GoToShelf shelfName` | (none) | None | `NavigateTo (shelfRoute shelfName)` |
| `Reset` | Resets to `init` | None | `NoOut` |

### View
- **Key elements**:
  - `NotAsked` / `NoResult`: Drop zone (`div.upload-area`) with drag-and-drop handlers and "Choose Photo" button
  - `Loading` / polling: Spinner with "Processing image..." (`div.upload-area__loading`, `role="status"`)
  - `Verifying book`: "We think this is..." card with cover image, title, author, confirm/reject buttons (`div.upload-verify`)
  - `ChoosingShelf book`: Shelf picker with 5 shelf buttons and "Add to [shelf]" button (`div.upload-shelf-picker`)
  - `Complete book shelfName`: Success message with "Add another" and "View on shelf" buttons (`div.upload-complete`, `role="status"`)
  - `Failure`: "Upload failed" error with retry button (`div.upload-area__error`)
- **ARIA attributes**: `aria-live="polite"` on `div.upload-status-region`; `role="status"` on loading, identified, and complete views
- **CSS classes**: `page--upload`, `upload-area`, `upload-area--dragging`, `upload-area__loading`, `upload-area__error`, `upload-area__prompt`, `upload-verify`, `upload-verify__heading`, `upload-verify__cover`, `upload-shelf-picker`, `upload-shelf-picker__shelf`, `upload-shelf-picker__shelf--selected`, `upload-complete`, `upload-manual-link`

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `upload_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/upload`), status_code (202, 422, 500)

- **Metric name**: `upload_status_poll_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/upload/:image_id/status`), status_code (200, 404, 422)

- **Metric name**: `book_detail_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/books/:id`), status_code (200, 404)

- **Metric name**: `placement_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/bookshelves/:bookshelf_name/placements`), status_code (201, 422)

### Oban Job Metrics

- **Metric name**: `identify_book_job_enqueued`
- **Source**: Oban Telemetry via `[:oban, :job, :start]` where worker = `Stacks.Workers.IdentifyBookJob`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker

- **Metric name**: `identify_book_job_completed`
- **Source**: Oban Telemetry via `[:oban, :job, :stop]`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker, state (completed, cancelled)

- **Metric name**: `identify_book_job_failed`
- **Source**: Oban Telemetry via `[:oban, :job, :exception]`
- **Type**: counter
- **Labels/dimensions**: queue (`:vision`), worker, attempt

- **Metric name**: `vision_queue_depth`
- **Source**: Oban queue inspection (`Oban.check_queue(queue: :vision)`)
- **Type**: gauge
- **Labels/dimensions**: queue (`:vision`)

### Circuit Breaker Metrics

- **Metric name**: `vision_fuse_state`
- **Source**: `:fuse.ask(:vision_service, :sync)` polled periodically. Not yet instrumented as a Telemetry event.
- **Type**: gauge (0 = ok, 1 = blown)
- **Labels/dimensions**: fuse_name (`:vision_service`)

- **Metric name**: `vision_fuse_melt_count`
- **Source**: Not yet instrumented. Would need a Telemetry emit wrapping `:fuse.melt/1` calls in `Stacks.AI.Client`.
- **Type**: counter
- **Labels/dimensions**: fuse_name

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`image.submitted`, `image.resolved`, `book.created`, `placement.created`)

- **Metric name**: `event_handler_error_count`
- **Source**: `:telemetry.execute([:stacks, :events, :handler_error], ...)` in `Stacks.Events.SubscriberWorker`
- **Type**: counter
- **Labels/dimensions**: handler, event_type, error

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (table name), operation (insert, select, update)

- **Metric name**: `ecto_query_count`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: counter
- **Labels/dimensions**: source, operation

### Storage Metrics

- **Metric name**: `r2_upload_count`
- **Source**: `Stacks.Storage.upload_image/2` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: operation (upload, delete), result (ok, error)

---

## 14. Performance & Usability Metrics

### End-to-End Pipeline Timing

- **Metric name**: Upload-to-shelf total time
- **How measured**: Client-side: elapsed time from `GotFile` to `PlacementCompleted` in Elm (not yet instrumented — would require a `Performance.now()` port). Server-side: delta between `image.submitted` and `placement.created` event timestamps in `event_log`.
- **Target/SLA**: p50 < 30s, p95 < 60s (dominated by Modal cold start at 15-30s)
- **Dashboard**: Upload pipeline section

### Per-Stage Timing

- **Metric name**: Image upload latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` duration for `POST /api/upload`
- **Target/SLA**: p95 < 2s
- **Dashboard**: API latency section

- **Metric name**: Vision classification time
- **How measured**: `Stacks.AI.Client.call_vision/2` response time — not yet instrumented. Currently only observable via Oban job duration.
- **Target/SLA**: p50 < 8s warm, p95 < 45s (includes cold start)
- **Dashboard**: Vision pipeline section

- **Metric name**: Vision extraction time
- **How measured**: Same as classification — `call_vision("extract_isbn", ...)` duration. Not yet instrumented separately.
- **Target/SLA**: p50 < 5s, p95 < 15s
- **Dashboard**: Vision pipeline section

- **Metric name**: ISBN resolution time
- **How measured**: `ISBNResolver.resolve/1` and `ISBNResolver.search_by_title/3` duration. Not yet instrumented.
- **Target/SLA**: p50 < 500ms, p95 < 2s (per capacity-model.md)
- **Dashboard**: External API section

- **Metric name**: IdentifyBookJob total duration
- **How measured**: Oban Telemetry `[:oban, :job, :stop]` duration for `:vision` queue
- **Target/SLA**: p50 < 20s, p95 < 60s
- **Dashboard**: Oban jobs section

### API Response Latencies

- **Metric name**: Status poll latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `GET /api/upload/:image_id/status`
- **Target/SLA**: p95 < 100ms (simple DB read)
- **Dashboard**: API latency section

- **Metric name**: Book detail fetch latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `GET /api/books/:id`
- **Target/SLA**: p50 < 50ms, p95 < 150ms (per capacity-model.md)
- **Dashboard**: API latency section

- **Metric name**: Placement creation latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `POST /api/bookshelves/:name/placements`
- **Target/SLA**: p95 < 100ms
- **Dashboard**: API latency section

### User Funnel Metrics

- **Metric name**: Upload-to-confirmation conversion rate
- **How measured**: `count(image.resolved) / count(image.submitted)` from `event_log`. Not yet instrumented as a real-time metric.
- **Target/SLA**: > 70% (depends on photo quality)
- **Dashboard**: Upload funnel section

- **Metric name**: Confirmation-to-placement conversion rate
- **How measured**: `count(placement.created where triggered_by = upload) / count(image.resolved)`. Requires event correlation — not yet instrumented.
- **Target/SLA**: > 90% (most confirmed books should be placed)
- **Dashboard**: Upload funnel section

- **Metric name**: Poll count before resolution
- **How measured**: Elm-side `pollCount` at time of `StatusReceived Resolved`. Not yet instrumented server-side.
- **Target/SLA**: median < 15 polls (30s), p95 < 30 polls (60s)
- **Dashboard**: Upload pipeline section

### Cache Metrics

- **Metric name**: BookDetailCache hit/miss ratio
- **How measured**: Not yet instrumented. Would need Telemetry events in `BookDetailCache.get/1`.
- **Target/SLA**: > 80% hit rate for repeat views
- **Dashboard**: Cache section

### Retry Metrics

- **Metric name**: IdentifyBookJob retry rate
- **How measured**: Oban Telemetry — jobs with `attempt > 1` in `[:oban, :job, :start]`
- **Target/SLA**: < 10% of jobs require retry
- **Dashboard**: Oban jobs section

---

## 15. Cost Tracking

### Vision Classification (Modal GPU)
- **Service**: Modal (A10G GPU, Qwen2.5-VL-7B-Instruct)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("is_book", ...)` — one classification per upload
- **Unit cost**: ~R0.50-R2.50 per identification (~$0.03-$0.14/min GPU time, 30-60s per call). Cold start adds 15-30s of billable time.
- **Volume estimate**: 1 call per upload. Early phase: 20-50 uploads/user/month; steady state: 2-5 uploads/user/month (per capacity-model.md)
- **Tracked by**: `Stacks.AI.BudgetTracker` (GenServer, daily limit R5, monthly limit R100), `op.platform_costs` table (via `Stacks.Costs.upsert_cost/1`), `mart_cost_tracking` dbt mart

### Vision Extraction (Modal GPU)
- **Service**: Modal (same GPU instance as classification)
- **Trigger**: `IdentifyBookJob` calls `Stacks.AI.Client.call_vision("extract_isbn", ...)` — one extraction per upload that passes classification
- **Unit cost**: Included in the classification call cost above (same Modal container session, 3-8s additional)
- **Volume estimate**: ~95% of uploads pass classification, so nearly 1:1 with uploads
- **Tracked by**: `Stacks.AI.BudgetTracker` (combined with classification under `:modal` provider)

### Open Library API
- **Service**: Open Library
- **Trigger**: `ISBNResolver.resolve/1` and `ISBNResolver.search_by_title/3` during ISBN resolution
- **Unit cost**: Free (public API, no rate limit charges)
- **Volume estimate**: 1-5 calls per upload (one per candidate ISBN, plus title search fallbacks)
- **Tracked by**: No cost tracking needed (free API). Request counts logged.

### Google Books API
- **Service**: Google Books
- **Trigger**: `ISBNResolver.resolve/1` (fallback from Open Library) and `ISBNResolver.search_by_title/3`
- **Unit cost**: Free tier (1,000 requests/day). No charges at current scale.
- **Volume estimate**: Called only when Open Library fails — estimated 10-30% of uploads
- **Tracked by**: No cost tracking needed at current scale. Monitor daily quota usage.

### R2 Object Storage
- **Service**: Cloudflare R2
- **Trigger**: `Stacks.Storage.upload_image/2` — one upload per image; `Storage.get_image_url/1` — presigned URL generation for vision pipeline
- **Unit cost**: Class A operations (writes): $0.0036/1,000 requests (~R0.065/1,000). Class B operations (reads): $0.00036/1,000 requests. Storage: $0.015/GB/month.
- **Volume estimate**: 1 write + 1 read per upload. Image size ~1-5MB. At 1,000 users: ~5K uploads/month = ~25GB stored (before 30-day GDPR expiry)
- **Tracked by**: `op.platform_costs` table (category: "infrastructure", service: "r2"), `mart_cost_tracking`

### Neon Database Compute
- **Service**: Neon PostgreSQL
- **Trigger**: All DB reads/writes during the upload flow — image insert, book+edition insert, placement insert, status polls
- **Unit cost**: Free tier (10GB storage, 1 compute). Paid: ~R200-800/month at scale.
- **Volume estimate**: ~10-15 queries per upload flow (insert image, poll status x N, insert book, insert edition, check duplicate, insert placement)
- **Tracked by**: `op.platform_costs` table (category: "infrastructure", service: "neon"), `mart_cost_tracking`

### Fly.io Compute
- **Service**: Fly.io (core app)
- **Trigger**: All HTTP requests and Oban job processing
- **Unit cost**: R150-R250/month flat (2x shared-cpu-1x 256MB)
- **Volume estimate**: Shared across all requests, not per-upload
- **Tracked by**: `op.platform_costs` table (category: "infrastructure", service: "fly_core"), `mart_cost_tracking`

### Per-Upload Cost Estimate
- Classification + extraction: ~R0.50-R2.50 (dominates)
- R2 storage: ~R0.00007 per upload
- Database queries: negligible (included in Neon monthly)
- ISBN resolution APIs: free
- **Total per upload: ~R0.50-R2.50 (~$0.03-$0.14 USD)**
