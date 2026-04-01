# US-1.1.6 — Duplicate Book Detection

## 1. User Story

> **As a** user, **I want to** be told when I'm adding a book that's already in my collection **so that** I don't create duplicates and can choose which shelf it belongs on.

**What the user wants to accomplish:** Avoid confusion from having the same book appear multiple times. The system should recognise the duplicate and offer helpful options.

**How they accomplish it:**
1. The user uploads photos or enters an ISBN (US-1.1.1 or US-1.1.5).
2. The ISBN resolves successfully, but a book with that ISBN already exists in the user's collection.
3. The system displays the existing book and its current shelf location.
4. The user can: (a) move the existing book to a different shelf, (b) do nothing and close the modal, or (c) view the book's detail overlay.

---

## 2. UI Interaction Flow

### Happy Path
1. User uploads an image or enters an ISBN.
2. Vision pipeline resolves the ISBN. The `IdentifyBookJob` creates/finds the book and stores `book_ids` on the uploaded image.
3. Elm polls `GET /api/upload/:image_id/status`. The controller calls `Shelving.book_on_any_shelf?(user.id, book_id)` which returns `true`.
4. Poll response includes `is_duplicate: true`.
5. Elm receives `StatusReceived (Ok {status: Resolved, isDuplicate: Just True, bookIds: [id]})`.
6. Elm calls `Api.getBook id (Just token) GotDuplicateBook` (using the `GotDuplicateBook` callback instead of `GotIdentifiedBook`).
7. `GotDuplicateBook (Ok response)` sets `result = DuplicateDetected response.book`.
8. **Duplicate view** (`viewDuplicate`): Shows "Already in Your Library" heading, "You own "[Title]" as [existing format]." message, merge prompt (see US-1.1.8), and secondary actions.
9. User can:
   - Click "Yes, merge" to add a new format edition (-> US-1.1.8 flow)
   - Click "No, add as separate" (`SkipMerge`) to treat as new entry (-> verification and shelf picker)
   - Click "View Book" link to navigate to book detail page
   - Click "Go Back" (`Reset`) to return to upload

### Sad Paths
- **Book fetch fails**: `GotDuplicateBook (Err _)` -> `result = IdentificationFailed` -> standard failure view

### Elm State Machine
- **Page module**: `Page.Upload`
- **Model fields involved**: `result` (= `DuplicateDetected book`), `duplicateShelf`, `duplicateMoveState`, `mergeIsbn`, `mergeFormatLabel`, `mergeFormatState`
- **Msg flow**:
  - `StatusReceived` with `isDuplicate = Just True` -> calls `Api.getBook` with `GotDuplicateBook` callback
  - `GotDuplicateBook (Ok response)` -> sets `result = DuplicateDetected response.book`, captures `mergeIsbn` and `mergeFormatLabel` from `primaryEdition`
  - `SkipMerge` -> converts `DuplicateDetected book` to `Identified [book]`, `step = Verifying book` (normal flow continues)
  - `Reset` -> resets to initial state

---

## 3. API Calls

### `GET /api/upload/:image_id/status`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UploadController.status/2`
- **Duplicate detection logic**:
  ```
  effective_ids = effective_book_ids(book_ids_strs, book_id_str)
  is_duplicate = Enum.any?(effective_ids, &Shelving.book_on_any_shelf?(user.id, &1))
  ```
- **Response**: `{ ..., is_duplicate: true, book_ids: ["<uuid>"] }` -- HTTP 200

### `GET /api/books/:id`
- **Auth**: Optional (Bearer token)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Response**: Full book detail with editions, author, etc.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` (for status poll with duplicate check)
- **Visibility checks**: `Visibility.resolve_visibility/2` called in `BookController.show/2`
- **Age gate**: `AgeGate.enforce/2` called in `BookController.show/2`
- **Ownership checks**: `Shelving.book_on_any_shelf?(user.id, book_id)` in `UploadController.status/2` is the core duplicate detection mechanism -- it checks if the authenticated user already has a placement for this book on any of their bookshelves

---

## 5. Database Interactions

### Read: Check if book is already on user's shelf
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Shelving.book_on_any_shelf?(user_id, book_id)`:
  ```elixir
  from(p in Placement,
    join: s in Bookshelf,
    on: s.id == p.bookshelf_id,
    where: s.user_id == ^user_id and p.book_id == ^book_id and is_nil(p.removed_at)
  ) |> Repo.exists?(prefix: "op")
  ```
- **Schema modules**: `Stacks.Shelving.Placement`, `Stacks.Shelving.Bookshelf`
- **Important**: Only active placements are checked (`is_nil(p.removed_at)`) -- books that were previously removed do not trigger duplicate detection

### Read: Fetch existing placement details
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Shelving.get_placement_for_book(user_id, book_id)`:
  ```elixir
  Placement
  |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id and bs.user_id == ^user_id)
  |> where([p], p.book_id == ^book_id and is_nil(p.removed_at))
  |> preload(:bookshelf)
  |> Repo.one()
  ```
- **Used by**: `BookController.confirm/2` to return placement info with the book

### No writes
No book or placement is created during duplicate detection. The book already exists, and the user's existing placement is preserved unless they explicitly choose to merge formats (US-1.1.8) or add as a new entry.

---

## 6. Event Flow & Lifecycle

### Events Emitted
No events are emitted during duplicate detection itself. If the user chooses "No, add as separate" and proceeds through the normal flow, the standard `placement.created` event fires.

### Event Handlers Triggered
N/A for the detection step.

---

## 7. Background Jobs (Oban)

The background job (`IdentifyBookJob`) runs as in US-1.1.1 to identify the book. The duplicate detection itself is synchronous, performed during the `GET /api/upload/:image_id/status` poll:

1. `IdentifyBookJob` resolves the ISBN and creates/finds the book -> stores `book_ids` on the uploaded image
2. `UploadController.status/2` reads the `book_ids` from the uploaded image record
3. For each book_id, calls `Shelving.book_on_any_shelf?(user.id, book_id)`
4. Sets `is_duplicate: true` in the poll response if any match

No additional background job is enqueued for duplicate detection.

---

## 8. External Service Calls

Same as US-1.1.1 for the ISBN resolution. No additional external calls for duplicate detection -- it's purely a local database check.

---

## 9. Storage (R2 / Local)

Same as US-1.1.1. The uploaded image is stored regardless of whether a duplicate is detected.

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: `get` -- the book detail is retrieved from cache if available when the Elm frontend fetches via `GET /api/books/:id`
- **No invalidation**: Duplicate detection doesn't modify any data, so no cache invalidation occurs

---

## 11. dbt Model Dependencies

N/A -- duplicate detection doesn't create or modify any records that would trigger dbt refreshes.

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
| `StatusReceived (Ok {Resolved, isDuplicate: Just True, bookIds: [id]})` | `pendingBookIds = [], collectedBooks = []` | `Api.getBook id (Just token) GotDuplicateBook` | `NoOut` |
| `GotDuplicateBook (Ok response)` | `result = DuplicateDetected response.book`, `mergeIsbn = primaryEdition.isbn`, `mergeFormatLabel = primaryEdition.formatLabel` | None | `NoOut` |
| `GotDuplicateBook (Err _)` | `result = IdentificationFailed` | None | `NoOut` |
| `SkipMerge` | `result = Identified [book]`, `step = Verifying book` | None | `NoOut` |
| `Reset` | Resets to `init` | None | `NoOut` |

### View
- **Rendered by**: `viewDuplicate model book`
- **Key elements**:
  - `h2`: "Already in Your Library"
  - `p`: "You own "[Title]" as [existing format]." (format from `book.primaryEdition.formatLabel`, defaults to "an edition")
  - Merge prompt (`viewMergePrompt`): "Add a new format?" with "Yes, merge" (`ConfirmMergeFormat book.id`) and "No, add as separate" (`SkipMerge`) buttons
  - Merge loading: spinner with "Merging format..." (`div.upload-duplicate__merge-loading`)
  - Merge success (`viewMergeSuccess`): "[Title] now has N editions" with "View book details" link and "Add another" button
  - Merge error: "Merge failed. Please try again." with retry merge prompt
  - Secondary actions: "View Book" link (`href` to `Route.BookDetail book.id`), "Go Back" button (`Reset`)
- **CSS classes**: `upload-result`, `upload-result--duplicate`, `upload-duplicate__merge`, `upload-duplicate__merge-actions`, `upload-duplicate__merge-loading`, `upload-duplicate__merge-error`, `upload-duplicate__merge-success`, `upload-duplicate__merge-success-text`, `upload-duplicate__secondary`
- **ARIA attributes**: Inherits `aria-live="polite"` from parent

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `upload_status_poll_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/upload/:image_id/status`), status_code (200)

- **Metric name**: `book_detail_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/books/:id`), status_code (200, 404)

### Duplicate Detection Metrics

- **Metric name**: `duplicate_detection_count`
- **Source**: Not yet instrumented. `Shelving.book_on_any_shelf?/2` is called in `UploadController.status/2` but does not emit Telemetry.
- **Type**: counter
- **Labels/dimensions**: result (duplicate, not_duplicate)

- **Metric name**: `duplicate_detection_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]` for the `EXISTS` query in `Shelving.book_on_any_shelf?/2`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`bookshelf_placements`), operation (select)

### Oban Job Metrics

Same as US-1.1.1 — the `IdentifyBookJob` runs normally. Duplicate detection happens synchronously during the status poll, not in the background job.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type. Note: no events are emitted during duplicate detection itself.

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`bookshelf_placements`, `bookshelves`, `uploaded_images`), operation (select)

---

## 14. Performance & Usability Metrics

### Duplicate Detection Timing

- **Metric name**: Duplicate check latency
- **How measured**: Ecto Telemetry for the `Shelving.book_on_any_shelf?/2` query. Not separately instrumented — included in the overall status poll response time.
- **Target/SLA**: < 5ms (simple `EXISTS` query with index on `book_id` and `bookshelf_id`)
- **Dashboard**: API latency section (part of status poll p95)

- **Metric name**: Status poll with duplicate check latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `GET /api/upload/:image_id/status`
- **Target/SLA**: p95 < 100ms (the duplicate check adds negligible time to the poll)
- **Dashboard**: API latency section

### User Experience Metrics

- **Metric name**: Duplicate detection rate
- **How measured**: `count(polls returning is_duplicate = true) / count(polls returning resolved)` from `event_log` or server logs. Not yet instrumented as a real-time metric.
- **Target/SLA**: Informational — expected to increase as users build larger collections
- **Dashboard**: Upload funnel section

- **Metric name**: Duplicate action distribution
- **How measured**: Not yet instrumented. Would track which action users take: "Yes, merge" (US-1.1.8), "No, add as separate" (`SkipMerge`), "View Book", or "Go Back" (`Reset`).
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

- **Metric name**: Duplicate-to-merge conversion rate
- **How measured**: Not yet instrumented. `count(ConfirmMergeFormat) / count(DuplicateDetected)` — requires Elm-side tracking.
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

---

## 15. Cost Tracking

### Vision Pipeline Costs
Same as US-1.1.1 — the full vision pipeline runs before duplicate detection occurs. The `IdentifyBookJob` identifies the book, then the status poll detects the duplicate.

### Vision Classification + Extraction (Modal GPU)
- **Service**: Modal (A10G GPU)
- **Trigger**: Same as US-1.1.1 — `IdentifyBookJob` runs the full vision pipeline
- **Unit cost**: ~R0.50-R2.50 per identification
- **Volume estimate**: Same as US-1.1.1. The duplicate detection itself adds no external API cost.
- **Tracked by**: `Stacks.AI.BudgetTracker`, `op.platform_costs`, `mart_cost_tracking`

### No Additional External API Costs
Duplicate detection is a local database query (`Shelving.book_on_any_shelf?/2`). No external APIs are called during the detection step.

### Book Detail Fetch
- **Service**: None (local DB query, potentially served from `BookDetailCache`)
- **Trigger**: `GET /api/books/:id` called by Elm to display the duplicate book's details
- **Unit cost**: Negligible
- **Volume estimate**: 1 call per detected duplicate
- **Tracked by**: Not tracked as a cost item

### Per-Duplicate-Detection Cost Estimate
- Vision pipeline: ~R0.50-R2.50 (same as US-1.1.1 — already incurred before duplicate detection)
- Duplicate check: R0 (local DB query)
- Book detail fetch: R0 (local DB or cache)
- **Total per duplicate detection: ~R0.50-R2.50 (~$0.03-$0.14 USD)**

Note: The vision pipeline cost is incurred regardless of whether a duplicate is detected. If `Books.find_existing/1` inside `IdentifyBookJob` finds the book already in the catalogue, the existing book is returned without creating a new one — but the GPU cost for classification and extraction was already spent. Frequent duplicates from the same user do not increase platform costs beyond the base vision cost per upload.
