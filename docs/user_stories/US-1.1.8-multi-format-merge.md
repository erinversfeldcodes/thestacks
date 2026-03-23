# US-1.1.8 — Multi-Format Book Merging

## 1. User Story

> **As a** user, **I want** different editions and formats of the same book to be recognised as a single work **so that** my shelves don't fill up with duplicates just because I own the hardcover and the Kindle edition.

**What the user wants to accomplish:** Maintain a single, unified entry per work in their collection, with each format (hardcover, softcover, Kindle, e-book, audiobook) tracked as a variant under that entry. Each format may have its own ISBN, but the shelf placement and reading journey are shared.

**How they accomplish it:**
1. The user uploads a photo or enters an ISBN for a book format they don't yet own.
2. The ISBN resolves successfully. The system checks for an exact ISBN match first (standard duplicate detection, US-1.1.6).
3. If no exact ISBN match is found, the system checks for an existing book in the user's collection with the same title and author (fuzzy match, normalised for subtitle variations and author name ordering).
4. If a potential match is found, the system presents a merge prompt: "You own [Title] as a [existing format]. Is this the same book in [new format]?"
5. The user confirms: the new ISBN is linked to the existing book record. The corresponding format indicator is toggled on. No new shelf placement is created.
6. The user declines: the book is treated as a new entry and follows the standard upload flow (US-1.1.1 steps 8-9).

---

## 2. UI Interaction Flow

### Happy Path (Merge)
1. User uploads image or enters ISBN (US-1.1.1 / US-1.1.5).
2. ISBN resolves. Duplicate detection finds an existing book on the user's shelf (`is_duplicate: true` in poll response).
3. Elm displays the duplicate view (`viewDuplicate`).
4. User sees: "Already in Your Library" with "You own "[Title]" as [existing format]."
5. Merge prompt: "Add a new format?" with "Yes, merge" and "No, add as separate".
6. User clicks "Yes, merge" (`ConfirmMergeFormat book.id`).
7. Elm sets `mergeFormatState = Loading`, calls `Api.mergeFormat bookId { isbn = mergeIsbn, formatLabel = mergeFormatLabel } token MergeFormatCompleted`.
8. API creates a new `book_edition` row linked to the existing work.
9. `MergeFormatCompleted (Ok response)` -> `mergeFormatState = Success response`, updates `book.editionCount`.
10. Merge success view: "[Title] now has N editions" with "View book details" link and "Add another" button.

### Happy Path (Decline Merge)
1. Steps 1-5 same as above.
2. User clicks "No, add as separate" (`SkipMerge`).
3. Elm converts `DuplicateDetected book` to `Identified [book]`, `step = Verifying book`.
4. Normal verification and shelf placement flow continues (US-1.1.1 steps 7-9).

### Sad Paths
- **Merge API failure**: `MergeFormatCompleted (Err err)` -> `mergeFormatState = Failure err` -> "Merge failed. Please try again." with retry merge prompt.
- **Duplicate ISBN**: API returns 422 with `error: "duplicate_isbn"` -- the ISBN is already registered to an edition.
- **Book not found**: API returns 404 -- the work ID doesn't exist (shouldn't happen in normal flow).

### Elm State Machine
- **Page module**: `Page.Upload`
- **Model fields involved**: `result` (= `DuplicateDetected book`), `mergeFormatState`, `mergeIsbn`, `mergeFormatLabel`
- **Msg flow**:
  - `ConfirmMergeFormat bookId` -> `mergeFormatState = Loading`, calls `Api.mergeFormat`
  - `MergeFormatCompleted (Ok response)` -> `mergeFormatState = Success response`, updates `book.editionCount += 1`
  - `MergeFormatCompleted (Err err)` -> `mergeFormatState = Failure err`
  - `SkipMerge` -> `result = Identified [book]`, `step = Verifying book`
- **RemoteData states**: `mergeFormatState`: NotAsked -> Loading -> Success / Failure

---

## 3. API Calls

### `POST /api/books/:id/merge-format`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookController.merge_format/2`
- **Request body**: `{ isbn: "9780316556347", format_label: "Kindle" }`
- **Response (success)**: `{ edition: { id, isbn, format_label, cover_image_url, page_count, publisher, publication_year, is_primary } }` -- HTTP 200
- **Response (not found)**: `{ error: "not_found" }` -- HTTP 404
- **Response (duplicate ISBN)**: `{ error: "duplicate_isbn" }` -- HTTP 422
- **Response (validation error)**: `{ error: "validation_failed", details: {...} }` -- HTTP 422

### Server-side merge detection (via `POST /api/books/confirm`)
The `Books.confirm/2` function also detects merge opportunities:
1. After ISBN resolution, if no exact ISBN match is found, it calls `Books.find_same_work(title, author)`.
2. `find_same_work/2` uses Jaro-Winkler string similarity on title and author:
   - Fetches candidate books with matching title or author prefixes (via `ILIKE`)
   - Computes `(title_sim + author_sim) / 2.0`
   - Returns matches where combined score > 0.8
3. If matches are found, returns `{:error, {:merge_required, existing_work_id}}`.
4. Controller maps this to HTTP 409: `{ error: "merge_required", work_id: "..." }`.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: N/A (merge operates on user's own book)
- **Age gate**: N/A (the book already exists in user's collection)
- **Ownership checks**: No explicit ownership check on the merge endpoint -- any authenticated user can merge an edition into any work. This is acceptable because the merge adds metadata (a new edition row) to the platform-wide catalogue, not to a specific user's collection.

---

## 5. Database Interactions

### Read: Find existing work by ISBN
- **Table(s)**: `op.book_editions` JOIN `op.books` JOIN `op.authors`
- **Query**: `Books.find_existing(isbn)` -- looks up edition by ISBN, returns parent book
- **Schema module**: `Stacks.Books.BookEdition`

### Read: Fuzzy match by title + author
- **Table(s)**: `op.books` JOIN `op.authors`
- **Query**: `Books.find_same_work(title, author)`:
  1. Extracts first word of title and author for prefix matching
  2. `ILIKE` query for candidates: `WHERE title ILIKE '%prefix%' OR author.name ILIKE '%prefix%'`
  3. Computes Jaro-Winkler similarity in Elixir using `String.jaro_distance/2` + prefix bonus
  4. Filters results where `(title_sim + author_sim) / 2.0 > 0.8`
  5. Sorts by similarity descending
- **Schema modules**: `Stacks.Books.Book`, `Stacks.Books.Author`

### Write: Insert new edition
- **Table(s)**: `op.book_editions`
- **Operation**: INSERT
- **Changeset validations**: `isbn` required, format validated (`^\d{10}(\d{3})?$`), checksum validated, unique constraint on `isbn`
- **Key fields**: `isbn`, `book_id` (FK to existing work), `format_label`, `is_primary = false`
- **Schema module**: `Stacks.Books.BookEdition`
- **Function**: `Books.merge_edition/2`
  1. Validates ISBN via `ISBNResolver.resolve(isbn)` (must exist in Open Library/Google Books)
  2. Verifies the work exists via `Repo.get(Book, work_id)`
  3. Inserts new `BookEdition` with `is_primary: false`
- **Transaction**: Not wrapped in Multi (single insert)

### Read: Verify work exists
- **Table(s)**: `op.books`
- **Query**: `Repo.get(Book, work_id)`

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `books.edition_merged`
- **Event type**: `books.edition_merged`
- **Aggregate**: `book_edition` / edition.id
- **Payload**: `%{isbn: isbn, work_id: work_id}`
- **Emitted by**: `Books.merge_edition/2` (via `emit_or_classify_edition/3`)
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
No handlers are currently registered for `books.edition_merged` in `Stacks.Events.Registry`. The event is stored in the `event_log` for audit purposes.

---

## 7. Background Jobs (Oban)

N/A -- the merge is synchronous. `Books.merge_edition/2` performs the ISBN validation, work lookup, and edition insertion inline in the request cycle.

The ISBN validation step (`ISBNResolver.resolve(isbn)`) makes synchronous HTTP calls to Open Library / Google Books to verify the ISBN exists. If this fails, the merge returns `{:error, :isbn_not_found}`.

---

## 8. External Service Calls

### Open Library API (ISBN validation during merge)
- **Service**: Open Library
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1`
- **Purpose**: Verify the new ISBN exists before creating the edition
- **Fallback**: Google Books API

### Google Books API (fallback ISBN validation)
- **Service**: Google Books
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1`

---

## 9. Storage (R2 / Local)

N/A -- no image storage occurs during the merge operation itself. The merge adds a `book_editions` row; cover images for the new edition may be fetched later via enrichment handlers.

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: The merge does not explicitly invalidate the cache for the affected work. However, `book.created` events (which do trigger `CacheInvalidationHandler`) are separate from edition merges. The `books.edition_merged` event does not have a registered `CacheInvalidationHandler`.
- **Potential staleness**: After a merge, the cached book detail may not include the new edition until the cache TTL expires or the entry is evicted for another reason.

---

## 11. dbt Model Dependencies

- **Model**: `stg_book_editions`
- **Impact**: New edition row appears in staging
- **No dbt refresh trigger**: `books.edition_merged` is not in the `DbtRefreshHandler` registry. The staging model will pick up the new edition on the next scheduled dbt run.

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
| `GotDuplicateBook (Ok response)` | `result = DuplicateDetected response.book`, `mergeIsbn = response.book.primaryEdition.isbn`, `mergeFormatLabel = response.book.primaryEdition.formatLabel` | None | `NoOut` |
| `ConfirmMergeFormat bookId` | `mergeFormatState = Loading` | `Api.mergeFormat bookId { isbn = mergeIsbn, formatLabel = mergeFormatLabel } token MergeFormatCompleted` | `NoOut` |
| `MergeFormatCompleted (Ok response)` | `mergeFormatState = Success response`, `result = DuplicateDetected { book | editionCount = editionCount + 1 }` | None | `NoOut` |
| `MergeFormatCompleted (Err err)` | `mergeFormatState = Failure err` | None | `NoOut` |
| `SkipMerge` | `result = Identified [book]`, `step = Verifying book` | None | `NoOut` |

### Elm API Call Details

**`Api.mergeFormat`**:
```
POST /api/books/{bookId}/merge-format
Headers: Authorization: Bearer {token}
Body: { isbn: string, format_label: string }
Response decoder: mergeFormatResponseDecoder (Decode.map MergeFormatResponse (Decode.field "edition" editionDecoder))
```

**`MergeFormatResponse`** type: `{ edition : Edition }`

### View
- **Merge prompt** (`viewMergePrompt`):
  - "Add a new format?"
  - "Yes, merge" primary button (`ConfirmMergeFormat book.id`)
  - "No, add as separate" secondary button (`SkipMerge`)
  - CSS: `upload-duplicate__merge`, `upload-duplicate__merge-actions`

- **Merge loading**:
  - Spinner + "Merging format..."
  - CSS: `upload-duplicate__merge-loading`

- **Merge success** (`viewMergeSuccess`):
  - "[Title] now has N edition(s)" (pluralised)
  - "View book details" primary link to `Route.BookDetail book.id`
  - "Add another" secondary button (`Reset`)
  - CSS: `upload-duplicate__merge-success`, `upload-duplicate__merge-success-text`

- **Merge error**:
  - "Merge failed. Please try again."
  - Re-renders `viewMergePrompt` for retry
  - CSS: `upload-duplicate__merge-error`

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `merge_format_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/books/:id/merge-format`), status_code (200, 404, 422)

- **Metric name**: `merge_format_error_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint, status_code (422 for `duplicate_isbn`, `validation_failed`)

- **Metric name**: `confirm_merge_detection_count`
- **Source**: Not yet instrumented. `Books.find_same_work/2` in `POST /api/books/confirm` returning `{:error, {:merge_required, work_id}}`.
- **Type**: counter
- **Labels/dimensions**: result (merge_required, no_match)

### Oban Job Metrics

N/A — the merge is synchronous. No Oban jobs are enqueued.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`books.edition_merged`)

Note: `books.edition_merged` has no registered handlers in `Stacks.Events.Registry` — the event is recorded in `event_log` for audit only.

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`book_editions`, `books`), operation (insert, select)

- **Metric name**: `fuzzy_match_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]` for the `ILIKE` query in `Books.find_same_work/2`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`books`), operation (select)

- **Metric name**: `jaro_winkler_candidates_count`
- **Source**: Not yet instrumented. Count of candidate books returned by the `ILIKE` query before Jaro-Winkler filtering.
- **Type**: histogram
- **Labels/dimensions**: none

### Cache Staleness Metrics

- **Metric name**: `book_detail_cache_stale_after_merge`
- **Source**: Not yet instrumented. `books.edition_merged` does not trigger `CacheInvalidationHandler` — the cached book detail may not include the new edition.
- **Type**: gauge (informational — identifies a known gap)
- **Labels/dimensions**: none

---

## 14. Performance & Usability Metrics

### Merge Operation Timing

- **Metric name**: Merge format API latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `POST /api/books/:id/merge-format`
- **Target/SLA**: p50 < 500ms, p95 < 2s (includes synchronous `ISBNResolver.resolve/1` call to validate the ISBN)
- **Dashboard**: API latency section

- **Metric name**: ISBN validation during merge
- **How measured**: Duration of `ISBNResolver.resolve/1` within `Books.merge_edition/2`. Not yet instrumented separately.
- **Target/SLA**: p50 < 500ms, p95 < 2s
- **Dashboard**: External API section

- **Metric name**: Fuzzy match computation time
- **How measured**: Duration of `Books.find_same_work/2` including `ILIKE` query + Jaro-Winkler computation. Not yet instrumented.
- **Target/SLA**: p95 < 200ms (depends on catalogue size — `ILIKE` prefix queries may slow with large book tables)
- **Dashboard**: API latency section

### User Experience Metrics

- **Metric name**: Merge acceptance rate
- **How measured**: `count(ConfirmMergeFormat) / count(DuplicateDetected)`. Not yet instrumented — requires Elm-side tracking.
- **Target/SLA**: Informational — tracks whether users find the merge prompt useful
- **Dashboard**: Upload funnel section

- **Metric name**: Merge-to-completion time
- **How measured**: Client-side elapsed time from `ConfirmMergeFormat` to `MergeFormatCompleted`. Not yet instrumented.
- **Target/SLA**: p50 < 2s, p95 < 5s
- **Dashboard**: Upload pipeline section

- **Metric name**: Skip merge rate
- **How measured**: `count(SkipMerge) / count(DuplicateDetected)`. Not yet instrumented.
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

- **Metric name**: Merge error rate
- **How measured**: `count(MergeFormatCompleted Err) / count(ConfirmMergeFormat)`. Not yet instrumented.
- **Target/SLA**: < 5%
- **Dashboard**: Upload funnel section

### Fuzzy Match Quality Metrics

- **Metric name**: False positive merge suggestions
- **How measured**: Not yet instrumented. Would require user feedback tracking (e.g., user clicks "No, add as separate" after a merge prompt).
- **Target/SLA**: < 10% of merge prompts should be rejected by users
- **Dashboard**: Content quality section

- **Metric name**: Jaro-Winkler similarity distribution
- **How measured**: Not yet instrumented. Would log the similarity score from `find_same_work/2` for accepted vs rejected merge prompts.
- **Target/SLA**: Informational — may inform tuning of the 0.8 threshold
- **Dashboard**: Content quality section

---

## 15. Cost Tracking

### Open Library API (ISBN Validation)
- **Service**: Open Library
- **Trigger**: `ISBNResolver.resolve/1` called by `Books.merge_edition/2` to validate the new ISBN before creating the edition
- **Unit cost**: Free (public API)
- **Volume estimate**: 1 call per merge operation
- **Tracked by**: No cost tracking needed

### Google Books API (ISBN Validation Fallback)
- **Service**: Google Books
- **Trigger**: `ISBNResolver.resolve/1` fallback
- **Unit cost**: Free tier (1,000 requests/day)
- **Volume estimate**: Called only when Open Library fails
- **Tracked by**: No cost tracking needed

### Vision Pipeline (Pre-Merge)
The merge prompt is reached after the upload flow (US-1.1.1) has already run the vision pipeline. The merge operation itself does NOT invoke the vision sidecar.

- **Service**: Modal (already incurred during upload)
- **Trigger**: Pre-merge: same as US-1.1.1
- **Unit cost**: ~R0.50-R2.50 (already counted in US-1.1.1/US-1.1.6)
- **Volume estimate**: No additional vision cost for the merge step
- **Tracked by**: `Stacks.AI.BudgetTracker` (already tracked under the original upload)

### Neon Database Compute
- **Service**: Neon PostgreSQL
- **Trigger**: `Books.find_same_work/2` (ILIKE query + Jaro-Winkler), `Books.merge_edition/2` (ISBN lookup + edition insert), work existence check
- **Unit cost**: Included in monthly Neon cost
- **Volume estimate**: 3-5 queries per merge operation
- **Tracked by**: `op.platform_costs` (category: "infrastructure", service: "neon")

### Per-Merge Cost Estimate
- Vision pipeline: R0 (not invoked during merge — cost already incurred during upload)
- ISBN validation APIs: free
- Database queries: negligible
- **Total per merge operation: effectively R0 (< R0.01)**

Note: The merge operation itself is nearly free because it leverages the already-completed vision identification. The only external call is `ISBNResolver.resolve/1` to validate the new ISBN, which uses free APIs. This makes format merging a cost-efficient alternative to creating a new book entry.
