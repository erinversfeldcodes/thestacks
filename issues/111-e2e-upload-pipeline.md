# Issue #111: E2E Test Suite — Upload Pipeline

## Summary
Comprehensive end-to-end test coverage for the entire upload pipeline, from photo drop through vision classification, ISBN resolution, verification, shelf placement, and all failure/edge-case paths.

## User Stories Covered
- [US-1.1.1 — Upload a Photo to Add a Book](../docs/user_stories/US-1.1.1-upload-photo.md)
- [US-1.1.2 — ISBN Hard Gate -- Book Rejection](../docs/user_stories/US-1.1.2-isbn-hard-gate.md)
- [US-1.1.3 — Non-Book Image Rejection](../docs/user_stories/US-1.1.3-non-book-rejection.md)
- [US-1.1.4 — Age-Gated Content Flagging](../docs/user_stories/US-1.1.4-age-gated-flagging.md)
- [US-1.1.5 — Manual ISBN Entry](../docs/user_stories/US-1.1.5-manual-isbn-entry.md)
- [US-1.1.6 — Duplicate Book Detection](../docs/user_stories/US-1.1.6-duplicate-detection.md)
- [US-1.1.7 — Bulk Upload (partial — multi-book from single image)](../docs/user_stories/US-1.1.7-bulk-upload.md)
- [US-1.1.8 — Multi-Format Book Merging](../docs/user_stories/US-1.1.8-multi-format-merge.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (UploadController, BookController, BookshelfPlacementController).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all upload pipeline).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Happy Path — Single Photo Upload
- Navigate to `/upload` while authenticated
- Drop an image file onto the drop zone; verify `div.upload-area--dragging` class appears on dragover
- Verify spinner with "Processing image..." appears (`div.upload-area__loading`, `role="status"`)
- Mock status poll to return `Resolved` with `bookIds`; verify "We think this is..." view renders (`div.upload-verify`)
- Verify book cover image (or "No cover" placeholder), title, and author display in verification view
- Click "Yes, that's it"; verify shelf picker renders (`div.upload-shelf-picker`) with 5 shelf buttons
- Verify WishList is pre-selected (`upload-shelf-picker__shelf--selected`)
- Change shelf selection; verify button text updates to "Add to [Shelf]"
- Click "Add to [Shelf]"; verify success view (`div.upload-complete`, `role="status"`) shows "[Title] added to [Shelf]"
- Verify "Add another" and "View on shelf" buttons present
- Click "View on shelf"; verify navigation to correct shelf route

#### Happy Path — File Picker
- Click "Choose Photo" button; verify file picker dialog opens (via `Select.files ["image/*"]`)
- Select a file; verify upload flow proceeds identically to drag-and-drop

#### Sad Path — Upload HTTP Failure (US-1.1.1)
- Mock `POST /api/upload` to return 500
- Verify error state: "Upload failed. Please try again." (`div.upload-area__error`)
- Verify "Try Again" button resets the form

#### Sad Path — Poll Timeout (US-1.1.1)
- Mock status poll to always return `Pending`
- After 150 polls, verify "Could Not Identify Book" view with "Try Another Photo" and "Enter ISBN Manually" buttons

#### Sad Path — ISBN Not Found / Hard Gate (US-1.1.2)
- Mock status poll to return `Rejected` with `rejection_reason: "isbn_not_found"`
- Verify rejection message includes ISBN hard gate explanation
- Verify "Try Another Photo" and "Enter ISBN Manually" buttons present
- Click "Try Another Photo"; verify form resets to initial state

#### Sad Path — Non-Book Rejection (US-1.1.3)
- Mock status poll to return `Resolved` with empty `bookIds`
- Verify "That Doesn't Look Like a Book" view (`result = NotABook`)
- Verify "Try Again" button present

#### Sad Path — Age-Gated Flagging (US-1.1.4)
- Mock vision pipeline to return a book with `visibility_tier: "age_gated"`
- Verify upload success proceeds normally (age-gating is transparent during upload)
- Navigate to shelf; click the age-gated spine; verify age gate prompt appears
- Verify frosted-glass overlay and lock icon on age-gated spine

#### Sad Path — Placement API Failure (US-1.1.1)
- Mock `POST /api/bookshelves/:name/placements` to return 422
- Verify "Failed to add book. Please try again." with retry button

#### Sad Path — Unauthenticated (US-1.1.1)
- Navigate to `/upload` without auth
- Verify "You need to sign in to add books." with "Sign In" link to `/login`

#### Manual ISBN Entry (US-1.1.5)
- Click "Enter ISBN manually instead" link below drop zone; verify manual entry form renders
- Type invalid ISBN (bad checksum); submit; verify red border and "Invalid ISBN checksum" error
- Type valid ISBN-10; verify input accepts it
- Type valid ISBN-13; verify input accepts it
- Submit valid ISBN; mock `GET /api/isbn/:isbn` to return book data
- Verify "We think this is..." verification view appears
- Submit valid ISBN; mock API to return 404; verify "Book not found" error with retry
- Verify entry from rejection flow: after ISBN hard gate rejection, click "Enter ISBN Manually"; verify form appears

#### Duplicate Detection (US-1.1.6)
- Mock status poll to return `is_duplicate: true`
- Verify "Already in Your Library" heading with existing book details
- Verify "You own [Title] as [format]" message
- Verify "Yes, merge", "No, add as separate", "View Book", and "Go Back" buttons
- Click "No, add as separate"; verify normal verification flow continues
- Click "Go Back"; verify upload resets

#### Multi-Format Merge (US-1.1.8)
- From duplicate detection view, click "Yes, merge"
- Mock merge API to succeed; verify "[Title] now has N editions" success view
- Verify "View book details" link and "Add another" button
- Mock merge API to fail; verify "Merge failed. Please try again." with retry

#### Multi-Book Extraction (US-1.1.7 — partial)
- Mock status poll to return multiple `bookIds`
- Verify all identified books render in the verification view
- Verify "View Book" links for each identified book

#### ARIA and Accessibility
- Verify `aria-live="polite"` on `div.upload-status-region`
- Verify `role="status"` on loading, identified, and complete views
- Verify drop zone is keyboard-accessible

### 2. API Endpoint Tests

#### `POST /api/upload`
- Authenticated request with valid image: returns 202 with `{ status: "accepted", image_id: uuid }`
- Authenticated request without image: returns 422 with `{ error: "no image provided" }`
- Unauthenticated request: returns 401
- Rate-limited request (`:upload` bucket): returns 429

#### `GET /api/upload/:image_id/status`
- Pending image: returns 200 with `{ status: "pending" }`
- Resolved image: returns 200 with `{ status: "resolved", book_id, book_ids, is_duplicate }`
- Rejected image: returns 200 with `{ status: "rejected", rejection_reason }`
- Invalid image_id format: returns 422
- Non-existent image_id: returns 404
- Status check by non-owner: returns 404 (or 403)

#### `GET /api/books/:id`
- Valid book: returns 200 with full book detail JSON (title, author, editions, edition_count, primary_edition)
- Non-existent book: returns 404
- Age-gated book without verification: returns 403
- Hidden book: returns 404

#### `POST /api/bookshelves/:bookshelf_name/placements`
- Valid placement: returns 201 with placement data
- Duplicate placement: returns 422
- Invalid bookshelf name: returns 404
- Unauthenticated: returns 401

#### `GET /api/isbn/:isbn`
- Valid ISBN found: returns 200 with book data
- Valid ISBN not found in external APIs: returns 404
- Invalid ISBN format: returns 422

### 3. Database Assertion Tests

#### `op.uploaded_images`
- INSERT on upload: verify `id`, `storage_path` ("uploads/{image_id}"), `status` ("pending"), `uploaded_at`, `expires_at` (now + 30 days)
- UPDATE on resolution: verify `status` changes to "resolved", `book_id` set, `book_ids` array populated
- UPDATE on rejection: verify `status` changes to "rejected", `rejection_reason` set ("not_a_book" or "isbn_not_found")

#### `op.books` and `op.book_editions`
- INSERT via Ecto.Multi: verify `title` required, `visibility_tier` in ("public", "age_gated")
- BookEdition: verify `isbn` required, ISBN format validated (regex `^\d{10}(\d{3})?$`), ISBN checksum validated, `isbn` unique constraint
- Multi atomicity: if edition insert fails, book insert is rolled back

#### `op.bookshelf_placements` and `op.bookshelves`
- Placement INSERT: verify `bookshelf_id`, `book_id`, `placed_at` set
- Duplicate check: `Shelving.book_on_any_shelf?(user_id, book_id)` returns correct boolean via EXISTS query on placements JOIN bookshelves where `removed_at IS NULL`

#### Age-gated books
- Verify `visibility_tier = "age_gated"` set on books with sensitive BISAC codes

### 4. Event Flow Tests

#### Event Sequence
- `image.submitted` emitted by `Books.store_upload/2` with payload `%{storage_path: "uploads/{image_id}"}`
- `image.resolved` emitted by `IdentifyBookJob.mark_resolved/2` with payload `%{book_count: N}`
- `book.created` emitted by `Books.create/1` via Multi `:emit_event` step with payload `%{isbn: isbn, title: title}`
- `placement.created` emitted by `Shelving.place_book/3` with placement details

#### Event Handler Execution
- `book.created` triggers `BookCreatedHandler` (enqueues enrichment jobs), `AuthorDiscoveryHandler`, `CacheInvalidationHandler`
- `placement.created` triggers `PlacementHandler` (feed update), `DbtRefreshHandler`

#### Event Log Records
- All events recorded in `event_log` table with correct `aggregate_type`, `aggregate_id`, `event_type`, `payload`
- Events recorded in correct chronological sequence
- Emission via `Events.emit_safe/1` (not `emit/1`)

#### Rejection Events
- `image.submitted` still emitted even when pipeline rejects
- No `book.created` or `placement.created` events on rejection

### 5. Background Job Tests

#### `Stacks.Workers.IdentifyBookJob`
- Enqueued on `:vision` queue with args `%{user_id, image_id, storage_key}`
- Max attempts: 3
- Happy path: fetches presigned URL -> calls `/classify` -> calls `/extract` -> resolves ISBN -> creates book -> calls `mark_resolved/2`
- Not-a-book: `/classify` returns `not_book` -> calls `mark_rejected/2` with "not_a_book" -> returns `{:cancel, ...}`
- ISBN not found: extraction succeeds but no ISBN resolves -> calls `mark_rejected/2` with "isbn_not_found" -> returns `{:cancel, ...}`
- Transient failure: retries up to 3 times
- Permanent failure (`:cancel`): does not retry
- Multi-book extraction: creates multiple books, stores all `book_ids` in uploaded_images
- Compound candidate expansion: titles joined by " OR " are split and processed individually

### 6. External Service Tests

#### Vision Sidecar — Classification (`POST /classify`)
- Mock `Stacks.AI.MockClient` returns `%{"classification" => "book", "confidence" => 0.95}`
- Mock returns `%{"classification" => "not_book", "confidence" => 0.98}` -> job cancels
- Mock returns `%{"classification" => "ambiguous", "confidence" => 0.5}` -> proceeds to extraction
- HMAC auth: `X-Internal-Token` header format `<timestamp>.<HMAC-SHA256>`
- Circuit breaker: `:vision_service` fuse blown -> `{:error, :circuit_open}`

#### Vision Sidecar — Extraction (`POST /extract`)
- Mock returns `%{"books" => [%{"title" => ..., "author" => ..., "potential_isbns" => [...]}]}`
- Mock returns empty `books` array -> isbn_not_found path
- Mock returns multiple books -> multi-book path

#### Open Library API
- Mock ISBN lookup success -> returns metadata
- Mock ISBN lookup failure -> falls through to Google Books
- Mock title search -> returns ISBN candidates

#### Google Books API
- Mock as fallback when Open Library fails
- Mock failure of both -> `{:error, :not_found}`

#### BudgetTracker
- `check_budget(:modal)` called before every vision API call
- Budget exceeded -> vision call skipped

### 7. Storage Tests

#### Upload
- `Stacks.Storage.upload_image/2` stores image at key `uploads/{image_id}`
- Content type: `image/jpeg`
- Backend: `Storage.Mock` in test

#### Presigned URL
- `Stacks.Storage.get_image_url/1` generates URL for `uploads/{image_id}`
- TTL: 900 seconds

#### Cleanup on Failure
- `Stacks.Storage.delete_image/1` called when DB insert fails after storage upload succeeds
- Verify image removed from storage on cleanup

### 8. Cache Tests

#### BookDetailCache
- `put` on first book detail fetch after creation
- `invalidate` triggered by `CacheInvalidationHandler` on `book.created` event
- Cache key: book UUID
- Verify cache miss on first fetch, hit on second

#### BudgetTracker
- `check_budget(:modal)` returns `:ok` within daily limit (R5)
- `check_budget(:modal)` returns `:budget_exceeded` when daily limit hit
- Monthly limit (R100) enforced

### 9. dbt Model Tests

#### After successful upload + placement
- `stg_books` contains the new book record
- `stg_book_editions` contains the new edition with correct ISBN
- `stg_uploaded_images` contains the image record with status "resolved"
- `stg_bookshelf_placements` contains the new placement

#### `DbtRefreshHandler` triggered
- `placement.created` event triggers dbt model refresh
- `mart_community_read_count` updated after refresh

### 10. Elm State Machine Tests

#### Upload Step Transitions
- Initial state: `step = Uploading`, `uploadState = NotAsked`, `selectedShelf = "wishlist"`, `isDragging = False`
- `GotFile file` -> `uploadState = Loading`, `step = Uploading`, `isDragging = False`
- `DragOver` -> `isDragging = True`
- `DragLeave` -> `isDragging = False`
- `FilepickerRequested` -> triggers `Select.files ["image/*"]`
- `UploadAccepted (Ok imageId)` -> `uploadState = Success imageId`, starts `sleepThenPoll`
- `UploadAccepted (Err err)` -> `uploadState = Failure err`
- `CheckStatus` -> `pollCount += 1`
- `StatusReceived (Ok {Resolved, bookIds})` -> sets `pendingBookIds`, calls `Api.getBook` for each
- `StatusReceived (Ok {Pending})` -> continues polling via `sleepThenPoll`
- `StatusReceived (Ok {Rejected})` -> `result = IdentificationFailed`
- `GotIdentifiedBook id (Ok resp)` -> when all fetched: `result = Identified`, `step = Verifying book`
- `ConfirmIdentification` -> `step = ChoosingShelf book`
- `RejectIdentification` -> resets to init
- `ShelfSelected shelf` -> `selectedShelf = shelf`
- `ConfirmPlacement` -> `placementState = Loading`
- `PlacementCompleted (Ok _)` -> `step = Complete book selectedShelf`
- `GoToShelf shelfName` -> OutMsg `NavigateTo (shelfRoute shelfName)`
- `Reset` -> resets to init

#### Manual ISBN Entry
- `EnterManualMode` -> `result = ManualISBNEntry`
- `ManualIsbnChanged isbn` -> updates `manualIsbn`
- `SubmitManualIsbn` with valid ISBN -> `isbnLookupState = Loading`
- `IsbnLookupResult (Ok response)` -> `result = Identified`, `step = Verifying`

#### Duplicate Detection
- `StatusReceived` with `isDuplicate: Just True` -> calls `GotDuplicateBook` callback
- `GotDuplicateBook (Ok response)` -> `result = DuplicateDetected book`
- `ConfirmMergeFormat` -> `mergeFormatState = Loading`
- `SkipMerge` -> converts to `Identified [book]`, `step = Verifying`

#### ISBN Validation
- `validateISBN10` accepts valid ISBN-10 checksums
- `validateISBN13` accepts valid ISBN-13 checksums
- Both reject invalid checksums

### 11. Metrics & Telemetry Tests

#### HTTP Request Metrics
- `upload_request_count` incremented on `POST /api/upload` (labels: status_code 202, 422, 500)
- `upload_status_poll_count` incremented on `GET /api/upload/:image_id/status`
- `book_detail_request_count` incremented on `GET /api/books/:id`
- `placement_request_count` incremented on `POST /api/bookshelves/:name/placements`

#### Oban Job Metrics
- `identify_book_job_enqueued` counter via `[:oban, :job, :start]` for `:vision` queue
- `identify_book_job_completed` counter via `[:oban, :job, :stop]` with state completed/cancelled
- `identify_book_job_failed` counter via `[:oban, :job, :exception]`
- `vision_queue_depth` gauge accurate

#### Circuit Breaker Metrics
- `vision_fuse_state` reports 0 (ok) / 1 (blown)

#### Cost Tracking
- `BudgetTracker` records cost against `:modal` provider
- `op.platform_costs` row created with category "ai", service "modal"
- `mart_cost_tracking` dbt model reflects the cost

#### Database Metrics
- `ecto_query_duration` histogram populated for upload flow queries
- `ecto_query_count` counter incremented for each operation (insert, select, update)

## Dependencies
- Vision sidecar mock infrastructure (`Stacks.AI.MockClient`)
- Storage mock (`Stacks.Storage.Mock`)
- Oban testing setup (`Oban.Testing`)
- Playwright test harness with auth helpers
- dbt test infrastructure
- `data-testid` attributes on upload UI elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/job tests, `elm-agent` for state machine tests, `dbt-agent` for model tests.

## Progress Notes
[Updated by agents during execution.]
