# US-1.2.1 — Browse the Library Shelf

## 1. User Story

> **As a** user, **I want to** browse my Library shelf **so that** I can see all the books I've read, displayed as an earned collection.

**What the user wants to accomplish:** View their read books on a shelf that feels like a personal, well-worn library.

**How they accomplish it:**
1. The user clicks "Library" in the top navigation.
2. The page transitions in (horizontal slide if coming from an adjacent shelf, or a fade through darkness if coming from the Reading Pile or Third Spaces).
3. The Library shelf loads with all read books displayed as spines on floor-to-ceiling shelving.

**What they see on the page:**
- **Wallpaper:** Deep green damask wallpaper with a subtle repeating pattern.
- **Shelving:** Dark walnut panelling -- rich, aged wood grain. Floor-to-ceiling bookshelves spanning the full width of the page.
- **Lighting:** Warm lamplight -- a golden glow cast from the upper-left, as if from a desk lamp just out of frame. Soft shadows beneath each shelf.
- **Shelf label:** "Library" in an elegant serif typeface, centred at the top, styled as if embossed into a brass plate mounted on the wood.
- **Books:** Spines rendered vertically. Well-read and well-loved wear states dominate -- rounded corners, muted colours, creased spines. Books with user writing show bookmarks/tabs poking out the top.
- The overall feeling is of a room you've earned -- every spine a testament to time spent reading.

**Acceptance Criteria:**
- Library shelf loads with all read books displayed as spines.
- Bookcase renders with at least 4 shelf rows (empty rows padded).
- Books grouped into rows by accumulated spine width (max 990px per row).
- Spine view and list view are toggleable.
- Empty state shows encouraging message.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/library` (clicks "Library" nav item).
2. `Main.elm` matches the `Library` route and calls `Page.Bookshelf.init libraryConfig maybeToken userId`.
3. Model initialises with `books = Loading`; an API request fires to `GET /api/bookshelves/library`.
4. While loading, an empty bookcase with 4 shelf rows renders immediately (loading skeleton).
5. On `BooksLoaded (Ok placements)`, model updates to `books = Success placements`.
6. Placements are grouped into rows via `groupIntoRows 990`, each row rendered as a `shelf-row` with clickable spines.
7. User clicks a spine -> `BookClicked book` fires -> `OutMsg NavigateTo (BookDetail book.id)` -> book detail overlay opens.

### Sad Paths
- **API error**: `BooksLoaded (Err err)` -> model sets `books = Failure err` -> error message: "Could not load your library. Please try again."
- **403 Forbidden (age-gated)**: `BooksLoaded (Err (Http.BadStatus 403))` -> `showAgeGate = True` -> age gate UI renders with Verify/Dismiss buttons.
- **No token**: No API call fires; empty bookcase renders in Loading state.

### Elm State Machine
- **Page module**: `Page.Bookshelf` (shared module, configured via `libraryConfig`)
- **Model fields involved**: `books : RemoteData Http.Error (List Placement)`, `showAgeGate : Bool`, `config : Config`, `userId : String`, `visibility : String`, `rssLink : RSSLink.Model`, `viewMode : ShelfViewMode`, `sortState : BookList.SortState`
- **Msg flow**: `init` fires `Api.getBookshelf "library" token BooksLoaded` -> `BooksLoaded (Ok placements)` -> `Success placements` -> view renders
- **RemoteData states**: `NotAsked` (no token) -> `Loading` (API in flight) -> `Success placements` / `Failure err`
- **OutMsg pattern**: `NavigateTo (BookDetail bookId)` propagates to Main for overlay display; `NoOut` for all other messages.

---

## 3. API Calls

### `GET /api/bookshelves/library`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:view_as`
- **Controller**: `StacksWeb.BookshelfController.show/2`
- **Request body**: N/A (GET request)
- **Response (success)**: `{ bookshelf: "library", count: N, placements: [{ id, position, placed_at, formats, personal_rating, notes, book: { id, title, description, visibility_tier, author: { id, name, bio }, editions: [...], edition_count, primary_edition: {...} } }] }` -- HTTP 200
- **Response (error)**: `{ error: "invalid bookshelf name" }` -- HTTP 404 (if name not in valid set)
- **FallbackController handling**: 404 for invalid bookshelf name; 403 if age-gated; visibility filtering applied to each placement.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` -> `ViewAsPlug`
- **Visibility checks**: `Visibility.resolve_visibility(bookshelf, viewer)` checks bookshelf-level visibility; each placement is filtered via `Visibility.resolve_visibility(placement, viewer) == :visible`
- **Age gate**: `AgeGate` is not enforced at the bookshelf list level (only at book detail level); however, a 403 from the API triggers the client-side age gate UI.
- **Ownership checks**: `ViewAsPlug.authorize_view_as(conn, user.id)` validates the view-as context; `Guardian.Plug.current_resource(conn)` provides the authenticated user.

---

## 5. Database Interactions

### Read: Load bookshelf metadata
- **Table(s)**: `op.bookshelves`
- **Query**: `SELECT * FROM op.bookshelves WHERE user_id = $1 AND name = 'library'` with `:user` preloaded
- **Indexes used**: Unique index on `(user_id, name)`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Load active placements
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Placement |> join(:inner, [p], bs in Bookshelf, on: p.bookshelf_id == bs.id and bs.user_id == $1 and bs.name == 'library') |> where([p], is_nil(p.removed_at)) |> order_by([p], [p.position, p.placed_at]) |> preload(book: [:author, :editions])`
- **Indexes used**: FK index on `bookshelf_id`, partial index on `removed_at IS NULL`
- **Schema module**: `Stacks.Shelving.Placement`

---

## 6. Event Flow & Lifecycle

### Events Emitted
No events are emitted during a browse operation (read-only).

### Event Handlers Triggered
N/A -- browse is a read-only operation.

---

## 7. Background Jobs (Oban)

N/A -- no background jobs are triggered by browsing a shelf.

---

## 8. External Service Calls

N/A -- no external services are called during shelf browsing.

---

## 9. Storage (R2 / Local)

N/A -- cover images referenced in `edition.cover_image_url` are pre-stored URLs; no storage operations occur during browse.

---

## 10. Cache Interactions

N/A -- bookshelf listing is not cached (BookDetailCache is only used for individual book detail lookups). Each bookshelf browse hits the database directly.

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements`, `stg_bookshelves`
- **Trigger**: `placement.created` and `placement.moved` events trigger `DbtRefreshHandler`
- **Materialisation**: view (staging models)
- **Consumer**: Not directly consumed by this endpoint, but placement data feeds into `mart_community_read_count` and other aggregates.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Library`
- **URL**: `/library`
- **Public or authenticated**: Authenticated (`:authenticated` pipeline)

### Init
- **`initPage` branch**: `Library` route -> `Page.Bookshelf.init libraryConfig maybeToken userId`
- **API calls on init**: `Api.getBookshelf "library" token BooksLoaded`
- **Initial model state**: `{ books = Loading, showAgeGate = False, config = libraryConfig, userId = userId, visibility = "platform", rssLink = RSSLink.init, viewMode = SpineView, sortState = { column = Title, direction = Asc } }`

### Config (Library-specific)
```elm
libraryConfig =
    { apiName = "library"
    , label = "Library"
    , themeClass = "shelf-library"
    , wallpaperClass = "wallpaper--damask"
    , wearLevel = Softened
    , emptyMessage = "Your library is waiting. Move a book here when you've finished reading it."
    }
```

### Update cycle
- **Msg `BooksLoaded (Ok placements)`**: `books` -> `Success placements`; no Cmd; `NoOut`
- **Msg `BooksLoaded (Err (Http.BadStatus 403))`**: `books` -> `Failure`; `showAgeGate` -> `True`; `NoOut`
- **Msg `BookClicked book`**: no model change; `NavigateTo (BookDetail book.id)`
- **Msg `ViewModeChanged mode`**: `viewMode` -> `mode` (switches between `SpineView` and `ListView`)
- **Msg `SortColumnClicked column`**: toggles `sortState.direction` if same column, otherwise sets `Asc` on new column
- **Msg `VerifyAge`**: `NavigateTo SettingsAgeVerification`
- **Msg `DismissAgeGate`**: `showAgeGate` -> `False`

### View
- **Key elements**:
  - `Loading`/`NotAsked`: empty bookcase with 4 shelf rows (via `minShelfRows 4 []`)
  - `Success placements` (non-empty): `viewBookcase (minShelfRows 4 shelfViews)` where `shelfViews` are rows of clickable spines grouped by `groupIntoRows 990`
  - `Success []` (empty): `viewEmptyShelfMessage` with Library-specific message
  - `Failure _`: error paragraph with "Could not load your library. Please try again."
  - `showAgeGate = True`: `Components.AgeGate.ageGate` renders with Verify/Dismiss actions
  - `ListView`: `BookList.view` renders sortable table with Title, Author, Pages, Date Added, Formats columns
- **ARIA attributes**: `aria-live="polite"` on content area; `role="list"` on `shelf-row__books`; `role="listitem"` on each spine button; `aria-label` on shelf label
- **CSS classes**: `page page--shelf shelf-library`, `wallpaper wallpaper--damask`, `lighting`, `shelf-room`, `shelf-room__header`, `shelf-label`, `bookcase`, `bookcase__side`, `bookcase__inner`, `shelf-row`, `shelf-row__back`, `shelf-row__books`, `shelf-row__plank`, `shelf-row__lip`, `book-button`, `book`, `book__face`, `book__spine`, `book__top`, `book__cover`, `view-mode-toggle`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/library", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/bookshelves/library", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/bookshelves/library", status=403}` | Phoenix.Telemetry | Counter | Increment per 403 response | Informational |
| `http.response.status{endpoint="/api/bookshelves/library", status=404}` | Phoenix.Telemetry | Counter | Increment per 404 response | < 1% of requests |
| `db.query.count{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Counter | Increment per placements query | 1 per request (no N+1) |
| `db.query.duration{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure query execution time | p95 < 50ms |
| `db.query.count{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Counter | Increment per bookshelf lookup | 1 per request |
| `db.query.duration{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure bookshelf lookup time | p95 < 10ms |
| `error.rate{endpoint="/api/bookshelves/library"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `page.load_time{route="/library"}` | Elm Performance API | Histogram (ms) | Time from navigation to `BooksLoaded (Ok _)` rendering complete | p50 < 400ms, p95 < 1200ms |
| `shelf.render_time{shelf="library"}` | Elm Performance API | Histogram (ms) | Time to run `groupIntoRows 990` and render all shelf rows | p95 < 100ms for 200 books |
| `shelf.book_count{shelf="library"}` | API response | Gauge | `count` field in API response | Informational (capacity planning) |
| `user.books_clicked_per_session{shelf="library"}` | Elm event tracking | Counter per session | Increment on each `BookClicked` msg | Informational (engagement) |
| `user.view_mode_toggles_per_session` | Elm event tracking | Counter per session | Increment on each `ViewModeChanged` msg | Informational (feature usage) |
| `user.sort_changes_per_session` | Elm event tracking | Counter per session | Increment on each `SortColumnClicked` msg | Informational (feature usage) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of Library page loads | Read-heavy; single GET request per page load. Minimal CPU -- mostly DB I/O wait. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Placements query with JOINs and preloads | Two queries per load: bookshelf lookup (indexed, fast) + placements with book/author/edition preloads. Cost scales with number of placements. |
| Neon DB (storage) | GiB stored | N/A (read-only) | No writes during browse. Storage cost is amortised across all operations. |
| R2 presigned URLs | N/A | N/A | Cover image URLs are pre-stored in `edition.cover_image_url`; no runtime R2 operations during browse. |
