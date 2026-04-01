# US-1.2.4 — Browse the Reading Pile

## 1. User Story

> **As a** user, **I want to** see my currently-reading books **so that** I can feel the cosy intimacy of being mid-read.

**What the user wants to accomplish:** View the books they're actively reading in a warm, inviting setting that is distinct from the shelf metaphor.

**How they accomplish it:**
1. The user clicks "Reading Pile" in the top navigation.
2. The page transitions with a fade through darkness -- a room transition, because this is a different spatial metaphor entirely.

**What they see on the page:**
- **Not a shelf.** This is a pile of books on a small side table next to an armchair.
- **Setting:** An intimate reading nook with an armchair, floor, and atmospheric lighting.
- **Books:** Displayed as spines in a casual, slightly haphazard pile -- rotated 90 degrees, stacked horizontally with slight random offsets.
- **Spine wear:** Uses `Softened` wear level in the current implementation.
- **Shelf label:** "Reading Pile" as text within the scene.

**Acceptance Criteria:**
- Reading Pile loads with currently-reading books in a pile layout (not shelf rows).
- Books rendered horizontally with stagger offsets.
- Hover selects a book; click on selected book opens detail overlay.
- Empty state shows "Nothing on the pile right now" message.
- Armchair renders as a CSS-only element regardless of book count.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/reading-pile`.
2. `Main.elm` matches `ReadingPile` route -> `Page.Bookshelf.ReadingPile.init maybeToken`.
3. Model initialises with `books = Loading`, `selectedBookId = Nothing`; API request fires to `GET /api/bookshelves/reading_pile`.
4. Loading message appears: "Loading your reading pile..."
5. On success, `viewBookPile` renders up to 50 books as horizontally-stacked spines.
6. User hovers over a book -> `BookHovered bookId` -> that book gains `book-pile__book--selected` class.
7. User clicks a hovered/selected book -> first click selects if not already selected, second click fires `NavigateTo (BookDetail book.id)`.
8. Clicking the background fires `Deselect`, clearing selection.

### Sad Paths
- **API error**: "Could not load your reading pile. Please try again."
- **403 Forbidden**: Age gate UI renders.
- **No token**: No API call fires.

### Elm State Machine
- **Page module**: `Page.Bookshelf.ReadingPile` (separate module, NOT using shared `Page.Bookshelf`)
- **Model fields involved**: `books : RemoteData Http.Error (List Placement)`, `showAgeGate : Bool`, `selectedBookId : Maybe String`
- **Msg flow**: `init` fires `Api.getBookshelf "reading_pile" token BooksLoaded` -> `BooksLoaded (Ok placements)` -> `Success placements` -> pile renders
- **RemoteData states**: `NotAsked` -> `Loading` -> `Success` / `Failure`
- **OutMsg pattern**: `NavigateTo (BookDetail bookId)` on second click of selected book; `NoOut` otherwise

---

## 3. API Calls

### `GET /api/bookshelves/reading_pile`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:view_as`
- **Controller**: `StacksWeb.BookshelfController.show/2`
- **Request body**: N/A
- **Response (success)**: `{ bookshelf: "reading_pile", count: N, placements: [...] }` -- HTTP 200
- **Response (error)**: Same as other bookshelves
- **FallbackController handling**: Same as US-1.2.1

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` -> `ViewAsPlug`
- **Visibility checks**: Same bookshelf-level and placement-level filtering as other shelves.
- **Age gate**: Client-side age gate on 403.
- **Ownership checks**: `ViewAsPlug.authorize_view_as(conn, user.id)`

---

## 5. Database Interactions

### Read: Load bookshelf metadata
- **Table(s)**: `op.bookshelves`
- **Query**: `WHERE user_id = $1 AND name = 'reading_pile'`
- **Indexes used**: Unique index on `(user_id, name)`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Load active placements
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: Same structure as other bookshelves with `name = 'reading_pile'`
- **Indexes used**: FK index on `bookshelf_id`, partial index on `removed_at IS NULL`
- **Schema module**: `Stacks.Shelving.Placement`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- read-only operation.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements`, `stg_bookshelves`
- **Trigger**: `placement.created` and `placement.moved` events trigger `DbtRefreshHandler`
- **Materialisation**: view
- **Consumer**: Feeds into downstream aggregates.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.ReadingPile`
- **URL**: `/reading-pile`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: `ReadingPile` route -> `Page.Bookshelf.ReadingPile.init maybeToken`
- **API calls on init**: `Api.getBookshelf "reading_pile" token BooksLoaded`
- **Initial model state**: `{ books = Loading, showAgeGate = False, selectedBookId = Nothing }`

### Key architectural differences from shelf bookshelves (Library/AntiLibrary/WishList)
- **Separate module**: `Page.Bookshelf.ReadingPile` is NOT a config variant of `Page.Bookshelf` -- it is its own module with a different Model, Msg type, and view.
- **No ViewModeToggle**: Reading Pile has no list view option.
- **No RSS link**: No RSS feed support in this view.
- **Selection model**: Two-step interaction -- hover to select (`BookHovered`), click selected to navigate (`BookClicked`). If clicking an unselected book, it selects first.
- **Deselect on background click**: `onClick Deselect` on the page container clears selection; `stopPropagationOn "click"` on each book prevents deselection when clicking a book.

### Update cycle
- **Msg `BooksLoaded (Ok placements)`**: `books` -> `Success placements`
- **Msg `BookHovered bookId`**: `selectedBookId` -> `Just bookId`
- **Msg `BookClicked book`**: If `selectedBookId == Just book.id`, fires `NavigateTo (BookDetail book.id)`; otherwise sets `selectedBookId = Just book.id`
- **Msg `Deselect`**: `selectedBookId` -> `Nothing`
- **Msg `VerifyAge`**: `NavigateTo SettingsAgeVerification`
- **Msg `DismissAgeGate`**: `showAgeGate` -> `False`

### View
- **Key elements**:
  - `Loading`: "Loading your reading pile..." message
  - `Success []` (empty): "Nothing on the pile right now. Move a book from your Antilibrary to start reading."
  - `Success placements`: `viewBookPile` renders `List.take 50 placements` as horizontally-stacked books
  - Each book: `button.book-pile__book` with dimensions swapped (width = spineHeight, height = spineWidth), random offset via `(modBy 5 (index * 3 + 2) - 2) * 3` pixels
  - Armchair: CSS-only element with `.armchair`, `.armchair__back`, `.armchair__seat`, `.armchair__arm--left/right`, `.armchair__leg--fl/fr/bl/br`
- **ARIA attributes**: `role="list"` on `book-pile`; `role="listitem"` on each book button; `aria-hidden="true"` on floor and armchair (decorative)
- **CSS classes**: `page page--shelf shelf-reading-pile`, `wallpaper wallpaper--dragons`, `lighting`, `reading-pile`, `reading-pile__label`, `reading-pile__scene`, `reading-pile__floor`, `reading-pile__chair-area`, `book-pile`, `book-pile__book`, `book-pile__book--selected`, `book-pile__rotated-book`, `armchair`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/reading_pile", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/bookshelves/reading_pile", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/bookshelves/reading_pile", status=403}` | Phoenix.Telemetry | Counter | Increment per 403 response | Informational |
| `db.query.count{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Counter | Increment per placements query | 1 per request (no N+1) |
| `db.query.duration{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure query execution time | p95 < 50ms |
| `db.query.count{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Counter | Increment per bookshelf lookup | 1 per request |
| `db.query.duration{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure bookshelf lookup time | p95 < 10ms |
| `error.rate{endpoint="/api/bookshelves/reading_pile"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `page.load_time{route="/reading-pile"}` | Elm Performance API | Histogram (ms) | Time from navigation to `BooksLoaded (Ok _)` rendering complete | p50 < 400ms, p95 < 1200ms |
| `pile.render_time` | Elm Performance API | Histogram (ms) | Time to render `viewBookPile` with up to 50 stacked books (offset calculations + DOM) | p95 < 80ms for 50 books |
| `pile.book_count` | API response | Gauge | `count` field in API response | Informational; display capped at 50 books via `List.take 50` |
| `user.books_hovered_per_session{shelf="reading_pile"}` | Elm event tracking | Counter per session | Increment on each `BookHovered` msg | Informational (engagement) |
| `user.books_clicked_per_session{shelf="reading_pile"}` | Elm event tracking | Counter per session | Increment on each `BookClicked` msg (second click = navigate) | Informational (engagement) |
| `user.deselect_count_per_session` | Elm event tracking | Counter per session | Increment on each `Deselect` msg | Informational (interaction pattern) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of Reading Pile page loads | Read-heavy; single GET request per page load. Minimal CPU -- mostly DB I/O wait. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Placements query with JOINs and preloads | Two queries per load: bookshelf lookup + placements with book/author/edition preloads. Reading Pile typically has fewer books than other shelves. |
| Neon DB (storage) | GiB stored | N/A (read-only) | No writes during browse. Storage cost is amortised across all operations. |
| R2 presigned URLs | N/A | N/A | Cover image URLs are pre-stored in `edition.cover_image_url`; no runtime R2 operations during browse. |
