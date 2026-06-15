# US-1.4.1 — Open a Book's Detail Overlay

## 1. User Story

> **As a** user, **I want to** click on a book spine to see its full details **so that** I can learn more about a book and manage it within my collection.

**What the user wants to accomplish:** Access all enriched data about a specific book -- metadata, reviews, prices, author info, and personal notes.

**How they accomplish it:**
1. The user clicks on a book spine on any shelf, in the Reading Pile, or on a search result.
2. The book detail overlay opens on top of the current page with all enriched sections.
3. The underlying page remains visible as a blurred background behind the overlay, preserving spatial context.
4. The user dismisses the overlay by clicking the X button, clicking outside the overlay area, or pressing Escape.
5. The browser URL does not change -- the overlay is a UI state, not a route.

**Important: This is an overlay, not a full-page route.** The overlay pattern was adopted to maintain the user's spatial context on their shelf.

**Acceptance Criteria:**
- Clicking a spine opens a modal overlay with book details.
- Overlay has backdrop blur and click-to-dismiss.
- Close button (X) in top-right corner.
- All detail sections render: Hero, About, Reviews, Prices, Author, Writing, Shelf Actions.
- If user owns the book: Move to Shelf, Format toggles, and Remove actions are shown.
- If authenticated but book not owned: "Add to Collection" action is shown.
- If unauthenticated: "Sign In or Register" prompt is shown.

---

## 2. UI Interaction Flow

### Happy Path
1. User clicks a book spine on any shelf -> `BookClicked book` msg fires.
2. The shelf page emits `OutMsg NavigateTo (BookDetail book.id)`.
3. `Main.elm` receives the `OutMsg`, initialises `Page.BookDetail.init bookId maybeToken maybePreviousRoute`.
4. Model initialises with `book = Loading`, `entryAnimationActive = True`; API request fires to `GET /api/books/:id`.
5. The overlay renders immediately via `Page.BookDetail.overlayView model`.
6. Backdrop with blur (`rgba(10, 8, 6, 0.75)`, `backdrop-filter: blur(4px)`) covers the shelf.
7. Card renders centered with `max-width: 900px`, `width: 90vw`, `max-height: 90vh`, `overflow-y: auto`.
8. On `BookLoaded (Ok response)`, the book detail content fills in: hero, about, reviews, prices, author, writing, shelf actions.
9. User dismisses by clicking X, clicking backdrop, or pressing Escape -> `CloseOverlay` msg -> `OutMsg RequestCloseOverlay`.

### Sad Paths
- **Book not found**: API returns 404 -> `BookLoaded (Err (Http.BadStatus 404))` -> "Could not load this book. Please try again."
- **Age-gated content**: API returns 403 -> `showAgeGate = True` -> age gate UI renders within the overlay.
- **Move failure**: `MoveCompleted (Err err)` -> "Failed to move book. Please try again."
- **Remove failure**: `RemoveCompleted (Err err)` -> "Failed to remove book. Please try again."

### Elm State Machine
- **Page module**: `Page.BookDetail`
- **Model fields involved**: `book : RemoteData Http.Error Book`, `placement : Maybe Placement`, `bookshelfMoverOpen : Bool`, `removeModalOpen : Bool`, `formatPickerOpen : Bool`, `currentBookshelf : String`, `selectedBookshelf : String`, `selectedFormats : List Format`, `moveState : RemoteData Http.Error ()`, `removeState : RemoteData Http.Error ()`, `selectedEdition : Maybe Edition`, `previousRoute : Maybe Route`, `showAgeGate : Bool`, `entryAnimationActive : Bool`, `isAuthenticated : Bool`
- **Msg flow**: `init` -> `Api.getBook bookId maybeToken BookLoaded` -> `BookLoaded (Ok response)` -> model populated with book, placement, formats, edition data
- **RemoteData states**: `Loading` -> `Success book` / `Failure err` for book; `NotAsked` -> `Loading` -> `Success` / `Failure` for move/remove operations
- **OutMsg pattern**: `NavigateTo route` for age verification; `RequestCloseOverlay` to dismiss

---

## 3. API Calls

### `GET /api/books/:id`
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Request body**: N/A
- **Response (success)**: `{ book: { id, title, description, language, subjects, bisac_codes, visibility_tier, author: { id, name, bio, website }, editions: [...], edition_count, primary_edition: {...}, community_read_count }, placement: { id, book_id, bookshelf_name, formats, personal_rating, notes } | null, my_writing: [{ id, title, published_at }] }` -- HTTP 200
- **Response (error)**: `{ error: "not_found" }` -- HTTP 404; HTTP 403 for age-gated content
- **FallbackController handling**: 404 for missing book or hidden visibility; 403 for age-gated books via `AgeGate.enforce/2`

### `PUT /api/placements/:id/move` (when moving book)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.move/2`
- **Request body**: `{ bookshelf: "target_shelf_name" }`
- **Response (success)**: `{ placement: { id, book_id, bookshelf_id, position, placed_at, removed_at } }` -- HTTP 200
- **Response (error)**: `{ error: "forbidden" }` -- HTTP 403; `{ error: "..." }` -- HTTP 422

### `DELETE /api/placements/:id` (when removing book)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.delete/2`
- **Request body**: N/A
- **Response (success)**: HTTP 204 (no body)
- **Response (error)**: `{ error: "not found" }` -- HTTP 404; `{ error: "forbidden" }` -- HTTP 403

### `POST /api/bookshelves/:bookshelf_name/placements` (when adding to collection)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.create/2`
- **Request body**: `{ book_id: "uuid" }`
- **Response (success)**: `{ placement: { id, book_id, bookshelf_id, position, placed_at, removed_at } }` -- HTTP 201

---

## 4. Auth & Middleware Guards

- **Plugs fired for book detail**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Plugs fired for move/remove**: `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: `Visibility.resolve_visibility(book, viewer)` -- hidden books return 404.
- **Age gate**: `AgeGate.enforce(conn, book)` checks BISAC codes and subjects; returns 403 if age-gated and user hasn't verified.
- **Ownership checks**: Move and remove operations verify `placement.bookshelf.user_id == user.id`; returns `:unauthorized` on mismatch.

---

## 5. Database Interactions

### Read: Book detail with cache
- **Table(s)**: `op.books` JOIN `op.authors` JOIN `op.book_editions`
- **Query**: `Book |> where([b], b.id == ^id) |> preload([:author, :editions])` via `Books.get_book_detail/1`
- **Indexes used**: PK index on `books.id`
- **Schema module**: `Stacks.Books.Book`

### Read: User's placement for this book
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Placement |> join(:inner, [p], bs in Bookshelf, on: bs.user_id == ^user_id) |> where([p], p.book_id == ^book_id and is_nil(p.removed_at)) |> preload(:bookshelf)`
- **Indexes used**: FK indexes on `bookshelf_id`, `book_id`
- **Schema module**: `Stacks.Shelving.Placement`

### Read: Community read count
- **Table(s)**: `wh.mart_community_read_count`
- **Query**: Raw SQL `SELECT read_count FROM wh.mart_community_read_count WHERE book_id = $1 LIMIT 1`
- **Schema module**: N/A (raw query)

### Read: User's writing linked to book
- **Table(s)**: `op.blog_posts` (via `Blog.list_posts_for_book_by_user/2`)
- **Query**: Posts associated with the book by the current user
- **Schema module**: `Stacks.Blog.Post`

---

## 6. Event Flow & Lifecycle

### Events Emitted
No events are emitted during the read-only book detail view. Events are emitted by move, place, and remove actions:
- `placement.moved` -- when `ConfirmMove` succeeds (see US-1.6.1)
- `placement.created` -- when `ConfirmPlace` succeeds
- `placement.removed` -- when `ConfirmRemove` succeeds (see US-1.6.4)

### Event Handlers Triggered
See US-1.6.1, US-1.6.4 for handler details.

---

## 7. Background Jobs (Oban)

N/A for the read-only detail view. Move/place/remove may trigger handlers (see respective stories).

---

## 8. External Service Calls

N/A -- the detail view shows locally-stored data. Review summaries, prices, and author enrichment are fetched by background enrichment jobs and stored locally.

---

## 9. Storage (R2 / Local)

- **Operation**: Presigned URL read (cover image display)
- **Key pattern**: `edition.cover_image_url` -- pre-stored URL, no runtime storage operation
- **Module**: N/A -- URLs are served directly
- **Backend**: The `cover_image_url` may point to R2 (prod) or local storage (dev)
- **TTL**: N/A for display

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: `get(book_id)` on read; `put(book_id, book)` on cache miss
- **Key**: `book_id` (UUID string)
- **TTL**: 5 minutes (300,000ms)
- **Invalidation trigger**: `book.created` and `book.cover_confirmed` events trigger `CacheInvalidationHandler` which calls `BookDetailCache.invalidate(book_id)`

---

## 11. dbt Model Dependencies

- **Model**: `wh.mart_community_read_count`
- **Trigger**: Refreshed when `placement.created` or `placement.moved` events fire (via `DbtRefreshHandler`)
- **Materialisation**: Likely view or incremental
- **Consumer**: `BookController.show/2` reads `community_read_count` from this mart

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.BookDetail bookId` (`/books/:id`) exists and coexists with the overlay (see ADR-005 closing note). The route is reachable via direct URL entry / deep link and renders the same `Page.BookDetail` content as a full page; the in-app interaction path opens the overlay instead. When a deep link is followed, `Main.elm` opens the overlay (`openOverlay`) for the matching `BookDetail bookId` route rather than navigating away.
- **URL**: URL does NOT change when the overlay is opened by clicking a spine / search result / catalogue item.
- **Public or authenticated**: Book detail API is `:optional_auth` (public books visible to all; placement/writing only for authenticated users).

### Init
- **`initPage` branch**: `Page.BookDetail.init bookId maybeToken maybePreviousRoute`
- **API calls on init**: `Api.getBook bookId maybeToken BookLoaded`
- **Initial model state**: `{ book = Loading, placement = Nothing, bookshelfMoverOpen = False, removeModalOpen = False, formatPickerOpen = False, currentBookshelf = routeToBookshelf(previousRoute), selectedBookshelf = firstAvailableBookshelf(...), selectedFormats = [], moveState = NotAsked, removeState = NotAsked, selectedEdition = Nothing, previousRoute = maybePreviousRoute, showAgeGate = False, entryAnimationActive = True, isAuthenticated = maybeToken /= Nothing }`

### Update cycle
- **Msg `BookLoaded (Ok response)`**: `book` -> `Success response.book`; `placement` -> `response.placement`; `currentBookshelf`, `selectedFormats`, `selectedEdition` populated from response
- **Msg `OpenBookshelfMover`**: `bookshelfMoverOpen` -> `True`
- **Msg `SelectBookshelf shelf`**: `selectedBookshelf` -> `shelf`
- **Msg `ConfirmMove`**: fires `Api.moveBook placement.id selectedBookshelf token MoveCompleted`; `moveState` -> `Loading`
- **Msg `MoveCompleted (Ok _)`**: `moveState` -> `Success ()`; `currentBookshelf` -> `selectedBookshelf`; placement updated
- **Msg `OpenRemoveModal`**: `removeModalOpen` -> `True`
- **Msg `ConfirmRemove`**: fires `Api.removeBook placement.id token RemoveCompleted`; `removeState` -> `Loading`
- **Msg `RemoveCompleted (Ok _)`**: `removeState` -> `Success ()`; `NavigateTo previousRoute`
- **Msg `ToggleFormat format`**: toggles format in `selectedFormats` list
- **Msg `EditionSelected editionId`**: finds edition in `book.editions` and sets `selectedEdition`
- **Msg `CloseOverlay`**: `RequestCloseOverlay` OutMsg

### View (overlayView)
- **Key elements**:
  - `div.book-overlay` -- fixed position, full viewport, z-index 1000, flex centered
  - `div.book-overlay__backdrop` -- absolute, `rgba(10, 8, 6, 0.75)`, `backdrop-filter: blur(4px)`, click fires `CloseOverlay`
  - `div.book-overlay__card` -- `role="dialog"`, `aria-modal="true"`, max-width 900px, 90vw, max-height 90vh, scrollable, border-radius 12px, box-shadow
  - `button.book-overlay__close` -- round X button, absolute top-right, z-index 1002
  - Inside card: same content as full-page view (`viewBook model book`)
  - Sections: `.book-detail__hero`, `.book-detail__about`, ReviewSummary (NotAsked), PriceInfo (NotAsked), AuthorCard, `.book-detail__writing`
  - Conditional sections based on placement/auth: `.book-detail__shelf-formats`, `.book-detail__shelf-actions`, `.book-detail__danger-zone`, or `.book-detail__signup-prompt`
  - Remove modal: `Components.RemoveBookModal.removeBookModal` renders on top of overlay when `removeModalOpen = True`
- **ARIA attributes**: `role="dialog"`, `aria-label="Book details: [title]"`, `aria-modal="true"`, `tabindex=-1` on card; `aria-label="Close book details"` on close button; `role="region"` and `aria-labelledby` on each section
- **CSS classes**: `book-overlay`, `book-overlay__backdrop`, `book-overlay__card`, `book-overlay__close`, `book-detail__parchment`, `book-detail`, `book-detail__hero`, `book-detail__cover-frame`, `book-detail__cover`, `book-detail__cover-img`, `book-detail__meta`, `book-detail__title`, `book-detail__author`, `book-detail__edition-selector`, `book-detail__meta-details`, `book-detail__isbn`, `book-detail__rating`, `book-detail__about`, `book-detail__shelf-actions`, `book-detail__shelf-formats`, `book-detail__danger-zone`, `book-detail__writing`, `book-detail__status`, `book-detail__status--loading`, `book-detail__status--success`, `book-detail__status--error`, `shelf-mover`, `modal-overlay`, `modal`, `btn btn--danger`, `btn btn--secondary`, `btn btn--ghost`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/books/:id", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/books/:id", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 98% of requests |
| `http.response.status{endpoint="/api/books/:id", status=404}` | Phoenix.Telemetry | Counter | Increment per 404 response | Informational |
| `http.response.status{endpoint="/api/books/:id", status=403}` | Phoenix.Telemetry | Counter | Increment per 403 (age-gated) response | Informational |
| `db.query.count{table="op.books", op="select"}` | Ecto.Telemetry | Counter | Increment per book detail query | 0 on cache hit, 1 on cache miss |
| `db.query.duration{table="op.books", op="select"}` | Ecto.Telemetry | Histogram (ms) | Book detail query with author/edition preloads | p95 < 30ms |
| `db.query.count{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Counter | Increment per user placement lookup | 1 per request (authenticated users only) |
| `db.query.count{table="wh.mart_community_read_count", op="select"}` | Ecto.Telemetry | Counter | Increment per community read count lookup | 1 per request |
| `db.query.duration{table="wh.mart_community_read_count", op="select"}` | Ecto.Telemetry | Histogram (ms) | Raw SQL query to dbt mart | p95 < 15ms |
| `db.query.count{table="op.blog_posts", op="select"}` | Ecto.Telemetry | Counter | Increment per user writing lookup | 1 per request (authenticated users only) |
| `cache.hit{cache="BookDetailCache"}` | BookDetailCache | Counter | Increment on cache hit for book detail | Informational |
| `cache.miss{cache="BookDetailCache"}` | BookDetailCache | Counter | Increment on cache miss for book detail | Informational |
| `cache.hit_ratio{cache="BookDetailCache"}` | BookDetailCache | Gauge (%) | hits / (hits + misses) over 5-min window | > 70% |
| `event.emit.count{type="placement.moved"}` | Events module | Counter | Increment per move event (from overlay actions) | Informational |
| `event.emit.count{type="placement.removed"}` | Events module | Counter | Increment per remove event (from overlay actions) | Informational |
| `event.emit.count{type="placement.created"}` | Events module | Counter | Increment per place event (from overlay actions) | Informational |
| `error.rate{endpoint="/api/books/:id"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `overlay.load_time` | Elm Performance API | Histogram (ms) | Time from `BookClicked` msg to `BookLoaded (Ok _)` rendering complete | p50 < 300ms, p95 < 800ms |
| `cache.hit_rate{cache="BookDetailCache"}` | BookDetailCache | Gauge (%) | Ratio of cache hits to total lookups | > 70% (5-min TTL) |
| `overlay.time_to_interactive` | Elm Performance API | Histogram (ms) | Time from overlay open to all sections rendered (hero, about, shelf actions) | p50 < 400ms, p95 < 1000ms |
| `user.moves_per_session` | Elm event tracking | Counter per session | Increment on each `MoveCompleted (Ok _)` | Informational (engagement) |
| `user.removes_per_session` | Elm event tracking | Counter per session | Increment on each `RemoveCompleted (Ok _)` | Informational (engagement) |
| `user.edition_switches_per_session` | Elm event tracking | Counter per session | Increment on each `EditionSelected` msg | Informational (feature usage) |
| `user.format_toggles_per_session` | Elm event tracking | Counter per session | Increment on each `ToggleFormat` msg | Informational (feature usage) |
| `overlay.dismiss_method` | Elm event tracking | Counter per method | Count of `CloseOverlay` by trigger (X button, backdrop click, Escape key) | Informational (UX pattern) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of book detail overlay opens | Multiple queries per request: book detail, placement lookup, community read count, user writing. Cache hits reduce DB load. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Cache misses on book detail lookups | On cache miss: book + author + editions preload query. On every request: placement lookup, community read count (raw SQL to dbt mart), blog posts query. Total 3-4 queries per request. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | `wh.mart_community_read_count` reads | Raw SQL read from dbt mart on every book detail request. Lightweight indexed lookup. |
| R2 presigned URLs | Presigned URL generation | Cover image display | `edition.cover_image_url` is pre-stored; no runtime R2 presigned URL generation. However, if cover URLs point to R2, each browser fetch incurs R2 egress. |
| BookDetailCache (ETS) | Memory (bytes) | Cached book entries x TTL (5 min) | In-process ETS cache. No external cost, but consumes Fly.io instance memory. |

---

## 16. Cross-References

- **ADR**: [ADR-005 — Book Detail as Overlay, Not a Routed Page](../decisions/005-book-detail-overlay-not-route.md) — establishes the overlay pattern, dismissal contract (X / backdrop click / Escape via `keydown` subscription in `Main.elm`), and the explicit allowance for a coexisting `/books/:id` route.
- **Issue**: [#057a — Elm: Book Detail Overlay](../../issues/complete/057a-elm-book-detail-overlay.md) — the implementation issue that converted `Page.BookDetail` from a full page to a dismissable overlay.
- **Related stories**:
  - US-1.1.8 (multi-format merge) — the format selector / edition picker rendered inside the overlay reuses the per-edition format model defined here.
  - US-1.6.1 (move book) — `ConfirmMove` action from the overlay's shelf mover.
  - US-1.6.4 (remove book) — `ConfirmRemove` action from the overlay's danger zone.
  - US-19.1.1 (accessibility / focus trapping) — ARIA contract and focus-return behaviour referenced by ADR-005.
- **Elm modules**: `Page.BookDetail` (overlay view + update); `Main.elm` holds `Maybe BookDetailOverlay`, wires `OverlayBookDetailMsg`, and handles the Escape `keydown` subscription that fires `RequestCloseOverlay`.
