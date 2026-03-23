# US-1.2.2 — Browse the AntiLibrary Shelf

## 1. User Story

> **As a** user, **I want to** browse my AntiLibrary shelf **so that** I can see all the books I own but haven't yet read, displayed as a collection of anticipation.

**What the user wants to accomplish:** View their unread-but-owned books in an environment that evokes the promise of future reading.

**How they accomplish it:**
1. The user clicks "AntiLibrary" in the top navigation.
2. The page transitions in with a horizontal slide.

**What they see on the page:**
- **Wallpaper:** Cream wallpaper with botanical prints -- delicate ferns, pressed flowers, and leaf illustrations in muted greens and browns.
- **Shelving:** Lighter oak shelving -- honey-toned, clean grain, less imposing than the Library's walnut.
- **Lighting:** Afternoon sunlight -- a warm, diffuse glow suggesting a sun-filled room. Soft highlights on the top edges of book spines.
- **Shelf label:** "Antilibrary" in the same serif typeface and brass plate style as other shelves.
- **Books:** Spines have a softened wear state -- slight softening of edges but still relatively fresh. The promise of reading, not yet begun.

Note: The codebase uses `wearLevel = Pristine` for AntiLibrary (not `Softened`), matching the "not yet read" concept rather than the "softened" description in the user story.

**Acceptance Criteria:**
- AntiLibrary shelf loads with all unread-but-owned books displayed as spines.
- Bookcase renders with at least 4 shelf rows.
- Books grouped into rows by accumulated spine width (max 990px per row).
- Spine view and list view are toggleable.
- Empty state shows encouraging message with "Add a Book" guidance.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/antilibrary`.
2. `Main.elm` matches `AntiLibrary` route -> `Page.Bookshelf.init antiLibraryConfig maybeToken userId`.
3. Model initialises with `books = Loading`; API request fires to `GET /api/bookshelves/antilibrary`.
4. Empty bookcase with 4 shelf rows renders immediately during loading.
5. On success, placements grouped into rows via `groupIntoRows 990` and rendered as clickable spines.
6. User clicks a spine -> `BookClicked book` -> overlay opens.

### Sad Paths
- **API error**: Error message: "Could not load your antilibrary. Please try again."
- **403 Forbidden**: Age gate UI renders.
- **No token**: No API call; empty bookcase in Loading state.

### Elm State Machine
- **Page module**: `Page.Bookshelf` (shared module, configured via `antiLibraryConfig`)
- **Model fields involved**: Same as US-1.2.1 -- `books`, `showAgeGate`, `config`, `userId`, `visibility`, `rssLink`, `viewMode`, `sortState`
- **Msg flow**: Identical to US-1.2.1 but with `apiName = "antilibrary"`
- **RemoteData states**: `NotAsked` -> `Loading` -> `Success` / `Failure`
- **OutMsg pattern**: `NavigateTo (BookDetail bookId)` or `NoOut`

---

## 3. API Calls

### `GET /api/bookshelves/antilibrary`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:view_as`
- **Controller**: `StacksWeb.BookshelfController.show/2`
- **Request body**: N/A
- **Response (success)**: `{ bookshelf: "antilibrary", count: N, placements: [...] }` -- HTTP 200
- **Response (error)**: `{ error: "invalid bookshelf name" }` -- HTTP 404
- **FallbackController handling**: Same as US-1.2.1

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` -> `ViewAsPlug`
- **Visibility checks**: Same as US-1.2.1 -- bookshelf-level and placement-level visibility filtering.
- **Age gate**: Not enforced at bookshelf list level.
- **Ownership checks**: `ViewAsPlug.authorize_view_as(conn, user.id)`

---

## 5. Database Interactions

### Read: Load bookshelf metadata
- **Table(s)**: `op.bookshelves`
- **Query**: `WHERE user_id = $1 AND name = 'antilibrary'`
- **Indexes used**: Unique index on `(user_id, name)`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Load active placements
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: Same structure as US-1.2.1 with `name = 'antilibrary'`; `is_nil(removed_at)`; ordered by `[position, placed_at]`; preloads `book: [:author, :editions]`
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

N/A -- bookshelf listings are not cached.

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements`, `stg_bookshelves`
- **Trigger**: `placement.created` and `placement.moved` events trigger `DbtRefreshHandler`
- **Materialisation**: view
- **Consumer**: Feeds into downstream aggregates.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.AntiLibrary`
- **URL**: `/antilibrary`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: `AntiLibrary` route -> `Page.Bookshelf.init antiLibraryConfig maybeToken userId`
- **API calls on init**: `Api.getBookshelf "antilibrary" token BooksLoaded`
- **Initial model state**: Same structure as Library, with `config = antiLibraryConfig`

### Config (AntiLibrary-specific)
```elm
antiLibraryConfig =
    { apiName = "antilibrary"
    , label = "Antilibrary"
    , themeClass = "shelf-antilibrary"
    , wallpaperClass = "wallpaper--botanical"
    , wearLevel = Pristine
    , emptyMessage = "Books you own but haven't read yet. Upload a photo to start building your collection."
    }
```

### Key differences from Library config
| Field | Library | AntiLibrary |
|-------|---------|-------------|
| `apiName` | `"library"` | `"antilibrary"` |
| `label` | `"Library"` | `"Antilibrary"` |
| `themeClass` | `"shelf-library"` | `"shelf-antilibrary"` |
| `wallpaperClass` | `"wallpaper--damask"` | `"wallpaper--botanical"` |
| `wearLevel` | `Softened` | `Pristine` |
| `emptyMessage` | "Your library is waiting..." | "Books you own but haven't read yet..." |

### Update cycle
Identical to US-1.2.1. All `Msg` variants behave the same way regardless of config.

### View
- **Key elements**: Same structure as Library -- bookcase with shelf rows, view mode toggle, RSS link.
- **ARIA attributes**: Same pattern -- `aria-live="polite"`, `role="list"`, `role="listitem"`
- **CSS classes**: `page page--shelf shelf-antilibrary`, `wallpaper wallpaper--botanical`, plus all shared bookcase classes.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/antilibrary", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/bookshelves/antilibrary", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/bookshelves/antilibrary", status=403}` | Phoenix.Telemetry | Counter | Increment per 403 response | Informational |
| `http.response.status{endpoint="/api/bookshelves/antilibrary", status=404}` | Phoenix.Telemetry | Counter | Increment per 404 response | < 1% of requests |
| `db.query.count{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Counter | Increment per placements query | 1 per request (no N+1) |
| `db.query.duration{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure query execution time | p95 < 50ms |
| `db.query.count{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Counter | Increment per bookshelf lookup | 1 per request |
| `db.query.duration{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure bookshelf lookup time | p95 < 10ms |
| `error.rate{endpoint="/api/bookshelves/antilibrary"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `page.load_time{route="/antilibrary"}` | Elm Performance API | Histogram (ms) | Time from navigation to `BooksLoaded (Ok _)` rendering complete | p50 < 400ms, p95 < 1200ms |
| `shelf.render_time{shelf="antilibrary"}` | Elm Performance API | Histogram (ms) | Time to run `groupIntoRows 990` and render all shelf rows | p95 < 100ms for 200 books |
| `shelf.book_count{shelf="antilibrary"}` | API response | Gauge | `count` field in API response | Informational (capacity planning) |
| `user.books_clicked_per_session{shelf="antilibrary"}` | Elm event tracking | Counter per session | Increment on each `BookClicked` msg | Informational (engagement) |
| `user.view_mode_toggles_per_session` | Elm event tracking | Counter per session | Increment on each `ViewModeChanged` msg | Informational (feature usage) |
| `user.sort_changes_per_session` | Elm event tracking | Counter per session | Increment on each `SortColumnClicked` msg | Informational (feature usage) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of AntiLibrary page loads | Read-heavy; single GET request per page load. Minimal CPU -- mostly DB I/O wait. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Placements query with JOINs and preloads | Two queries per load: bookshelf lookup (indexed, fast) + placements with book/author/edition preloads. Cost scales with number of placements. |
| Neon DB (storage) | GiB stored | N/A (read-only) | No writes during browse. Storage cost is amortised across all operations. |
| R2 presigned URLs | N/A | N/A | Cover image URLs are pre-stored in `edition.cover_image_url`; no runtime R2 operations during browse. |
