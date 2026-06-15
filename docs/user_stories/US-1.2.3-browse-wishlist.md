# US-1.2.3 — Browse the WishList Bookshelf

## 1. User Story

> **As a** user, **I want to** browse my WishList bookshelf **so that** I can see all the books I aspire to own and read.

**What the user wants to accomplish:** View their desired books in a dreamy, aspirational setting.

**How they accomplish it:**
1. The user clicks "WishList" in the top navigation.
2. The page transitions in with a horizontal slide.

**What they see on the page:**
- **Wallpaper:** Watercolour floral wallpaper -- soft washes of lavender, blush, sage, and cream. Loose, painterly blooms.
- **Walls:** Soft blue-grey walls visible above and below the shelving.
- **Lighting:** Morning light -- cool and gentle, as if the curtains have just been drawn.
- **Bookshelf label:** "Wish List" on the brass plate.
- **Books:** Spines are pristine -- sharp edges, clean texture, bright colours. These books are idealised; you haven't touched them yet.

**Acceptance Criteria:**
- WishList bookshelf loads with all wishlist books displayed as spines.
- Bookcase renders with at least 4 shelf rows.
- Spine view and list view toggleable.
- Empty state shows aspirational message.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/wishlist`.
2. `Main.elm` matches `WishList` route -> `Page.Bookshelf.init wishListConfig maybeToken userId`.
3. Model initialises with `shelves = Loading`; API request fires to `GET /api/bookshelves/wishlist`.
4. Empty bookcase renders during loading.
5. On success, each returned shelf renders its `placements` as clickable spines.
6. Clicking a spine opens the book detail overlay.

### Sad Paths
- **API error**: "Could not load your wish list. Please try again."
- **403 Forbidden**: Age gate UI renders.
- **No token**: No API call; empty bookcase.

### Elm State Machine
- **Page module**: `Page.Bookshelf` (shared module, configured via `wishListConfig`)
- **Model fields involved**: Same as US-1.2.1
- **Msg flow**: Identical to US-1.2.1 but with `apiName = "wishlist"`
- **RemoteData states**: `NotAsked` -> `Loading` -> `Success` / `Failure`
- **OutMsg pattern**: `NavigateTo (BookDetail bookId)` or `NoOut`

---

## 3. API Calls

### `GET /api/bookshelves/wishlist`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api` -> `:authenticated` -> `:view_as`
- **Controller**: `StacksWeb.BookshelfController.show/2`
- **Request body**: N/A
- **Response (success)**: `{ bookshelf: "wishlist", count: N, shelves: [{id, position, placements: [...]}, ...] }` -- HTTP 200
- **Response (error)**: `{ error: "invalid bookshelf name" }` -- HTTP 404
- **FallbackController handling**: Same as US-1.2.1

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` -> `ViewAsPlug`
- **Visibility checks**: Bookshelf-level and placement-level visibility filtering.
- **Age gate**: Not enforced at bookshelf list level.
- **Ownership checks**: `ViewAsPlug.authorize_view_as(conn, user.id)`

---

## 5. Database Interactions

### Read: Load bookshelf metadata
- **Table(s)**: `op.bookshelves`
- **Query**: `WHERE user_id = $1 AND name = 'wishlist'`
- **Indexes used**: Unique index on `(user_id, name)`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Load active placements
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: Same structure as US-1.2.1 with `name = 'wishlist'`
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
- **Route variant**: `Route.WishList`
- **URL**: `/wishlist`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: `WishList` route -> `Page.Bookshelf.init wishListConfig maybeToken userId`
- **API calls on init**: `Api.getBookshelf "wishlist" token ShelvesLoaded`
- **Initial model state**: Same structure as Library, with `config = wishListConfig`

### Config (WishList-specific)
```elm
wishListConfig =
    { apiName = "wishlist"
    , label = "Wish List"
    , themeClass = "shelf-wishlist"
    , wallpaperClass = "wallpaper--floral"
    , wearLevel = Pristine
    , emptyMessage = "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
    }
```

### Key differences from Library/AntiLibrary config
| Field | Library | AntiLibrary | WishList |
|-------|---------|-------------|----------|
| `apiName` | `"library"` | `"antilibrary"` | `"wishlist"` |
| `label` | `"Library"` | `"Antilibrary"` | `"Wish List"` |
| `themeClass` | `"shelf-library"` | `"shelf-antilibrary"` | `"shelf-wishlist"` |
| `wallpaperClass` | `"wallpaper--damask"` | `"wallpaper--botanical"` | `"wallpaper--floral"` |
| `wearLevel` | `Softened` | `Pristine` | `Pristine` |
| `emptyMessage` | "Your library is waiting..." | "Books you own but haven't read yet..." | "Books you're dreaming about..." |

### Update cycle
Identical to US-1.2.1. All `Msg` variants behave the same way regardless of config.

### View
- **Key elements**: Same bookcase structure as Library and AntiLibrary.
- **ARIA attributes**: Same pattern.
- **CSS classes**: `page page--shelf shelf-wishlist`, `wallpaper wallpaper--floral`, plus all shared bookcase/shelf-row classes.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/wishlist", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/bookshelves/wishlist", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/bookshelves/wishlist", status=403}` | Phoenix.Telemetry | Counter | Increment per 403 response | Informational |
| `http.response.status{endpoint="/api/bookshelves/wishlist", status=404}` | Phoenix.Telemetry | Counter | Increment per 404 response | < 1% of requests |
| `db.query.count{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Counter | Increment per placements query | 1 per request (no N+1) |
| `db.query.duration{table="op.bookshelf_placements", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure query execution time | p95 < 50ms |
| `db.query.count{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Counter | Increment per bookshelf lookup | 1 per request |
| `db.query.duration{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Histogram (ms) | Measure bookshelf lookup time | p95 < 10ms |
| `error.rate{endpoint="/api/bookshelves/wishlist"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `page.load_time{route="/wishlist"}` | Elm Performance API | Histogram (ms) | Time from navigation to `ShelvesLoaded (Ok _)` rendering complete | p50 < 400ms, p95 < 1200ms |
| `shelf.render_time{shelf="wishlist"}` | Elm Performance API | Histogram (ms) | Time to render all shelf rows from the nested shelves response | p95 < 100ms for 200 books |
| `shelf.book_count{shelf="wishlist"}` | API response | Gauge | `count` field in API response | Informational (capacity planning) |
| `user.books_clicked_per_session{shelf="wishlist"}` | Elm event tracking | Counter per session | Increment on each `BookClicked` msg | Informational (engagement) |
| `user.view_mode_toggles_per_session` | Elm event tracking | Counter per session | Increment on each `ViewModeChanged` msg | Informational (feature usage) |
| `user.sort_changes_per_session` | Elm event tracking | Counter per session | Increment on each `SortColumnClicked` msg | Informational (feature usage) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of WishList page loads | Read-heavy; single GET request per page load. Minimal CPU -- mostly DB I/O wait. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Placements query with JOINs and preloads | Two queries per load: bookshelf lookup (indexed, fast) + placements with book/author/edition preloads. Cost scales with number of placements. |
| Neon DB (storage) | GiB stored | N/A (read-only) | No writes during browse. Storage cost is amortised across all operations. |
| R2 presigned URLs | N/A | N/A | Cover image URLs are pre-stored in `edition.cover_image_url`; no runtime R2 operations during browse. |
