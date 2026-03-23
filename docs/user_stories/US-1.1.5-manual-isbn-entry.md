# US-1.1.5 — Manual ISBN Entry

## 1. User Story

> **As a** user, **I want to** manually type an ISBN **so that** I can add a book when the vision model fails to identify it from my photos.

**What the user wants to accomplish:** Get a book into their collection even if their photos aren't clear enough for the vision model. They know the book exists and can find the ISBN on the back cover or copyright page.

**How they accomplish it:**
1. After a failed photo upload (US-1.1.2), the user clicks "Enter ISBN manually" in the rejection modal.
2. Alternatively, the user can access manual entry directly from the "Add a Book" button via a "Type ISBN instead" link below the photo upload area.
3. The user types a 10- or 13-digit ISBN.
4. The system validates the ISBN checksum client-side.
5. On submission, the system queries Open Library and Google Books for the ISBN.
6. If found, the system presents the same verification step as US-1.1.1 ("We think this is...") followed by the shelf placement prompt (defaulting to WishList).
7. If not found in either service, the system rejects the entry with the same message as US-1.1.2.

---

## 2. UI Interaction Flow

### Happy Path
1. User is on the Upload page (`/upload`), either after a failed upload (US-1.1.2) or from the initial view.
2. User clicks "Enter ISBN Manually" (`EnterManualMode`) or "Enter ISBN manually instead" button below the drop zone.
3. Model sets `result = ManualISBNEntry`. View switches to `viewManualEntry`.
4. User types ISBN into the `Components.ISBNInput` component. Each keystroke fires `ManualIsbnChanged isbn`.
5. The input field validates the ISBN checksum client-side via `Components.ISBNInput.isValidISBN/1`. The field shows a red border with error text when invalid (after submission attempt).
6. User clicks "Look Up Book" (`SubmitManualIsbn`).
7. `isValidISBN` is checked -- if valid, `isbnLookupState = Loading`, and `Api.lookupByIsbn isbn token IsbnLookupResult` is called.
8. API returns the book detail. `IsbnLookupResult (Ok response)` sets `result = Identified [response.book]`, `step = Verifying response.book`.
9. From here, the flow is identical to US-1.1.1 steps 7-9 (verification -> shelf placement -> success).

### Sad Paths
- **Invalid ISBN checksum**: User submits ISBN with bad checksum -> `showIsbnError = True` -> red input border with "Invalid ISBN checksum. Please check the number and try again."
- **ISBN not found**: API returns 404 -> `isbnLookupState = Failure err` -> "Book not found. Please check the ISBN and try again." with retry button.
- **Unauthenticated**: `SubmitManualIsbn` with `maybeToken = Nothing` -> no API call made (silent no-op).

### Elm State Machine
- **Page module**: `Page.Upload`
- **Component**: `Components.ISBNInput` (provides `isbnInput` view function, `isValidISBN`, `validateISBN10`, `validateISBN13`)
- **Model fields involved**: `result` (= `ManualISBNEntry`), `manualIsbn`, `showIsbnError`, `isbnLookupState`
- **Msg flow**:
  - `EnterManualMode` -> `result = ManualISBNEntry`, `isbnLookupState = NotAsked`
  - `ManualIsbnChanged isbn` -> `manualIsbn = isbn`, `showIsbnError = False`
  - `SubmitManualIsbn` -> validates ISBN, if valid: `isbnLookupState = Loading`, calls `Api.lookupByIsbn`
  - `IsbnLookupResult (Ok response)` -> `isbnLookupState = Success ()`, `result = Identified [response.book]`, `step = Verifying response.book`
  - `IsbnLookupResult (Err err)` -> `isbnLookupState = Failure err`
- **RemoteData states**: `isbnLookupState`: NotAsked -> Loading -> Success / Failure

---

## 3. API Calls

### `GET /api/books/isbn/:isbn`
- **Auth**: Required (Bearer token)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookController.show_by_isbn/2`
- **Request**: GET with ISBN in URL path
- **Response (success)**: `{ book: { id, title, description, author, editions, primary_edition, ... } }` -- HTTP 200
- **Response (not found)**: `{ error: "not_found" }` -- HTTP 404
- **Age gate**: `AgeGate.enforce(conn, book)` is called if the book exists -- may halt conn for age-gated content
- **Implementation**: Calls `Books.find_existing(isbn)` which queries `op.book_editions` by ISBN and preloads the parent book (work) with author and editions

Note: This endpoint looks up an *existing* book by ISBN. If the book doesn't exist in the platform yet, it returns 404. The Elm frontend shows the "Book not found" error, at which point the user can try a different ISBN.

For creating a book from a manually entered ISBN, the `POST /api/books` endpoint (`BookController.create/2`) calls `Books.create_from_isbn/1`, but the current Elm `Api.lookupByIsbn` function calls the GET endpoint instead.

### Subsequent calls (on success)
Same as US-1.1.1:
- `POST /api/bookshelves/:bookshelf_name/placements` for shelf placement

---

## 4. Auth & Middleware Guards

- **Plugs fired** (ISBN lookup): `SecurityHeaders` -> `AuthPipeline`
- **Age gate**: `AgeGate.enforce/2` is called in `show_by_isbn/2` -- halts conn if age-gated and user hasn't verified age
- **Visibility checks**: N/A for ISBN lookup (book is returned regardless of visibility tier, modulo age gate)
- **Ownership checks**: N/A for lookup

---

## 5. Database Interactions

### Read: Look up book by ISBN
- **Table(s)**: `op.book_editions` JOIN `op.books` JOIN `op.authors`
- **Query**: `BookEdition |> where(isbn: ^isbn) |> preload(book: [:author, :editions])` then extracts `edition.book`
- **Schema module**: `Stacks.Books.BookEdition`, `Stacks.Books.Book`
- **Indexes used**: Unique constraint on `book_editions.isbn`
- **Function**: `Books.find_existing/1`

### Write (if book doesn't exist and POST /api/books is used)
- Same as US-1.1.1 create flow via `Books.create_from_isbn/1`:
  1. Validates ISBN format via `BookEdition.changeset`
  2. Calls `ISBNResolver.resolve(isbn)` for metadata
  3. Calls `find_or_create_author/1`
  4. Creates book + edition via `Books.create/1` (Ecto.Multi)

---

## 6. Event Flow & Lifecycle

### Events Emitted
If the book already exists in the catalogue, no events are emitted during the ISBN lookup itself. Events are emitted during the subsequent shelf placement (same as US-1.1.1):
- `placement.created` -- when the user places the book on a shelf

If the book needs to be created (via `POST /api/books`):
- `book.created` -- same as US-1.1.1

### Event Handlers Triggered
Same as US-1.1.1 for any events that fire.

---

## 7. Background Jobs (Oban)

N/A -- manual ISBN entry is a synchronous flow. No Oban job is enqueued. The ISBN lookup (`GET /api/books/isbn/:isbn`) and book creation (`POST /api/books`) are handled inline in the request cycle.

This is a key difference from the photo upload flow (US-1.1.1), which enqueues `IdentifyBookJob` and uses polling.

---

## 8. External Service Calls

### Open Library API (if book needs to be created)
- **Service**: Open Library
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1`
- **Endpoint**: ISBN lookup
- **Auth**: None (public API)

### Google Books API (fallback, if book needs to be created)
- **Service**: Google Books
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1`
- **Auth**: API key

These calls only happen if the book doesn't already exist in the platform and the `POST /api/books` endpoint is used (calling `Books.create_from_isbn/1`). The `GET /api/books/isbn/:isbn` endpoint is a local database lookup only.

---

## 9. Storage (R2 / Local)

N/A -- no image is uploaded in the manual ISBN entry flow. If the user arrived here after a failed photo upload, the original image is already in storage from US-1.1.1.

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: `get` in `BookController.show/2` (if the user later views the book). The ISBN lookup (`show_by_isbn`) does not use the cache -- it queries the DB directly.

---

## 11. dbt Model Dependencies

Same as US-1.1.1 if a new book or placement is created. No special dbt models for manual ISBN entry.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Upload`
- **URL**: `/upload`
- **Public or authenticated**: Authenticated

### Init
Same as US-1.1.1. Manual entry is reached via user interaction, not at init.

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `EnterManualMode` | `result = ManualISBNEntry`, `isbnLookupState = NotAsked` | None | `NoOut` |
| `ManualIsbnChanged isbn` | `manualIsbn = isbn`, `showIsbnError = False` | None | `NoOut` |
| `SubmitManualIsbn` (valid ISBN) | `isbnLookupState = Loading` | `Api.lookupByIsbn manualIsbn token IsbnLookupResult` | `NoOut` |
| `SubmitManualIsbn` (invalid ISBN) | `showIsbnError = True` | None | `NoOut` |
| `IsbnLookupResult (Ok response)` | `isbnLookupState = Success ()`, `result = Identified [response.book]`, `step = Verifying response.book` | None | `NoOut` |
| `IsbnLookupResult (Err err)` | `isbnLookupState = Failure err` | None | `NoOut` |

After `IsbnLookupResult (Ok ...)`, the flow continues with US-1.1.1's verification and shelf placement cycle (`ConfirmIdentification` -> `ShelfSelected` -> `ConfirmPlacement` -> `PlacementCompleted`).

### View
- **Rendered by**: `viewManualEntry model`
- **Key elements**:
  - `h2`: "Enter ISBN Manually"
  - ISBN input: `Components.ISBNInput.isbnInput` with config `{ value = model.manualIsbn, onInput = ManualIsbnChanged, showError = model.showIsbnError }`
  - Input states:
    - Normal: `input.isbn-input` with placeholder "Enter ISBN-10 or ISBN-13"
    - Error: `input.isbn-input.isbn-input--error` with `p.isbn-input__error` text "Invalid ISBN checksum. Please check the number and try again."
  - Loading state: spinner with "Looking up book..." (`div.upload-manual__loading`)
  - Failure state: "Book not found. Please check the ISBN and try again." (`div.upload-manual__error`) with "Look Up Book" retry button
  - Default state: "Look Up Book" primary button (`onClick SubmitManualIsbn`)
  - "Cancel" ghost button (`onClick Reset`)
- **CSS classes**: `upload-result`, `upload-result--manual`, `isbn-input-wrapper`, `isbn-input`, `isbn-input--error`, `isbn-input__error`, `upload-manual__loading`, `upload-manual__error`, `upload-manual__error-text`
- **ARIA attributes**: Inherits `aria-live="polite"` from parent `div.upload-status-region`

### Client-Side ISBN Validation

`Components.ISBNInput` exposes three validation functions:

**`isValidISBN : String -> Bool`**: Strips hyphens and spaces, dispatches to `validateISBN10` or `validateISBN13` based on length.

**`validateISBN10 : String -> Bool`**: Weighted sum with multipliers 10, 9, 8, ..., 1. Check digit can be 'X' (= 10). Valid when `sum mod 11 == 0`.

**`validateISBN13 : String -> Bool`**: Alternating weights 1, 3, 1, 3, .... Valid when `sum mod 10 == 0`.

The server-side `BookEdition.changeset/2` performs the same validation via `validate_isbn_checksum/1`, so invalid ISBNs are caught at both layers.

---

## 13. Operational Metrics

### HTTP Request Metrics

- **Metric name**: `isbn_lookup_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`GET /api/books/isbn/:isbn`), status_code (200, 404)

- **Metric name**: `placement_request_count`
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/bookshelves/:bookshelf_name/placements`), status_code (201, 422)

- **Metric name**: `book_create_request_count` (if `POST /api/books` is used)
- **Source**: Phoenix Telemetry via `[:phoenix, :endpoint, :stop]`
- **Type**: counter
- **Labels/dimensions**: endpoint (`POST /api/books`), status_code (201, 404, 422)

### Oban Job Metrics

N/A — manual ISBN entry is a synchronous flow. No Oban jobs are enqueued.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`placement.created`, and `book.created` if book needs to be created)

### Database Metrics

- **Metric name**: `ecto_query_duration`
- **Source**: Ecto Telemetry via `[:core, :repo, :query]`
- **Type**: histogram (microseconds)
- **Labels/dimensions**: source (`book_editions`, `books`, `bookshelf_placements`), operation (select, insert)

- **Metric name**: `isbn_lookup_miss_count`
- **Source**: Not yet instrumented. Count of `GET /api/books/isbn/:isbn` returning 404 (book not in platform catalogue).
- **Type**: counter
- **Labels/dimensions**: none

### Error Rate Metrics

- **Metric name**: `manual_isbn_validation_failure_rate`
- **Source**: Not yet instrumented. Client-side only (Elm `showIsbnError`). No server-side metric unless the user bypasses client validation.
- **Type**: counter
- **Labels/dimensions**: validation_type (checksum)

---

## 14. Performance & Usability Metrics

### Response Latencies

- **Metric name**: ISBN lookup latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `GET /api/books/isbn/:isbn`
- **Target/SLA**: p50 < 30ms, p95 < 100ms (local DB query on unique index)
- **Dashboard**: API latency section

- **Metric name**: Book creation latency (if `POST /api/books` is used)
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `POST /api/books`
- **Target/SLA**: p50 < 500ms, p95 < 2s (includes synchronous Open Library/Google Books API calls)
- **Dashboard**: API latency section

- **Metric name**: Placement creation latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `POST /api/bookshelves/:name/placements`
- **Target/SLA**: p95 < 100ms
- **Dashboard**: API latency section

### End-to-End Timing

- **Metric name**: Manual ISBN entry to shelf placement time
- **How measured**: Client-side elapsed time from `SubmitManualIsbn` to `PlacementCompleted`. Not yet instrumented.
- **Target/SLA**: p50 < 3s, p95 < 5s (no vision pipeline involved — just DB lookup + placement)
- **Dashboard**: Upload pipeline section

Note: Manual ISBN entry is dramatically faster than photo upload because it bypasses the vision pipeline entirely. If the book already exists in the catalogue, the flow is purely local DB operations.

### User Experience Metrics

- **Metric name**: Manual ISBN entry success rate
- **How measured**: `count(successful ISBN lookups) / count(SubmitManualIsbn attempts)`. Not yet instrumented.
- **Target/SLA**: > 80% (most ISBNs typed by users looking at the book should be valid and in the catalogue)
- **Dashboard**: Upload funnel section

- **Metric name**: Manual ISBN entry after rejection
- **How measured**: Not yet instrumented. Would track users who arrive at manual entry via `EnterManualMode` after a photo upload rejection.
- **Target/SLA**: Informational
- **Dashboard**: Upload funnel section

- **Metric name**: Client-side ISBN validation rejection rate
- **How measured**: Not yet instrumented. Elm-side count of `showIsbnError = True` occurrences.
- **Target/SLA**: < 20% of manual entry attempts
- **Dashboard**: Not dashboarded (client-side only)

---

## 15. Cost Tracking

### No Vision Costs
Manual ISBN entry bypasses the vision pipeline entirely. No Modal GPU time is consumed.

### Open Library API (if book creation is needed)
- **Service**: Open Library
- **Trigger**: `ISBNResolver.resolve/1` called by `Books.create_from_isbn/1` when the book doesn't exist in the platform catalogue
- **Unit cost**: Free (public API)
- **Volume estimate**: 1 call per manual entry where the book is not yet in the catalogue
- **Tracked by**: No cost tracking needed

### Google Books API (if book creation is needed)
- **Service**: Google Books
- **Trigger**: `ISBNResolver.resolve/1` fallback
- **Unit cost**: Free tier (1,000 requests/day)
- **Volume estimate**: Called only when Open Library fails
- **Tracked by**: No cost tracking needed

### Neon Database Compute
- **Service**: Neon PostgreSQL
- **Trigger**: ISBN lookup query (`Books.find_existing/1`), optional book creation, placement creation
- **Unit cost**: Included in monthly Neon cost (free tier or R200-800/month)
- **Volume estimate**: 2-5 queries per manual ISBN entry
- **Tracked by**: `op.platform_costs` (category: "infrastructure", service: "neon")

### Per-Manual-Entry Cost Estimate
- Vision pipeline: R0 (not invoked)
- ISBN resolution APIs: free
- Database queries: negligible
- **Total per manual ISBN entry: effectively R0 (< R0.01)**

Note: Manual ISBN entry is the most cost-efficient path to adding a book. It avoids the ~R0.50-R2.50 Modal GPU cost entirely. Users who know their ISBN should be encouraged to use this path.
