# Issue #112: E2E Test Suite — Shelf Browsing

## Summary
Comprehensive end-to-end test coverage for browsing all five bookshelves (Library, AntiLibrary, WishList, Reading Pile, Looking for Home), including theme rendering, API data loading, empty states, transitions, and view mode toggling.

## User Stories Covered
- [US-1.2.1 — Browse the Library Shelf](../docs/user_stories/US-1.2.1-browse-library.md)
- [US-1.2.2 — Browse the AntiLibrary Shelf](../docs/user_stories/US-1.2.2-browse-antilibrary.md)
- [US-1.2.3 — Browse the WishList Shelf](../docs/user_stories/US-1.2.3-browse-wishlist.md)
- [US-1.2.4 — Browse the Reading Pile](../docs/user_stories/US-1.2.4-browse-reading-pile.md)
- [US-1.2.5 — Shelf Transitions](../docs/user_stories/US-1.2.5-shelf-transitions.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (BookshelfController only).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all shelf browsing).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Library Shelf (US-1.2.1)
- Navigate to `/library` while authenticated
- Verify `page--shelf shelf-library` class on page container
- Verify `wallpaper wallpaper--damask` class renders the deep green damask wallpaper
- Verify `lighting` element present for warm lamplight effect
- Verify `shelf-label` contains "Library" text
- Verify bookcase renders with at least 4 shelf rows (`shelf-row` elements >= 4)
- Verify books grouped into rows — no `shelf-row__books` exceeds 990px width
- Verify each book spine is a clickable button (`book-button`) with correct ARIA label
- Verify spine click opens book detail overlay
- Verify `bookcase__side` elements (left/right) present for 3D bookcase frame
- Verify `bookcase__inner` contains all shelf rows

#### AntiLibrary Shelf (US-1.2.2)
- Navigate to `/antilibrary` while authenticated
- Verify `shelf-antilibrary` theme class
- Verify `wallpaper--botanical` wallpaper class for cream botanical prints
- Verify shelf label shows "Antilibrary"
- Verify bookcase with at least 4 rows

#### WishList Shelf (US-1.2.3)
- Navigate to `/wishlist` while authenticated
- Verify `shelf-wishlist` theme class
- Verify `wallpaper--floral` wallpaper class for watercolour floral
- Verify shelf label shows "Wish List"
- Verify bookcase with at least 4 rows

#### Reading Pile (US-1.2.4)
- Navigate to `/reading-pile` while authenticated
- Verify pile layout (NOT bookcase layout) — books rendered horizontally
- Verify armchair CSS element renders regardless of book count
- Verify books have stagger offsets (slight random rotation/positioning)
- Verify hover selects a book; click on selected book opens detail overlay
- Verify `Softened` wear level on pile spines

#### Looking for Home
- Navigate to `/looking-for-home` while authenticated
- Verify `Components.EmptyBookshelf` renders when no books
- Verify correct themed empty state message

#### Loading State (all shelves)
- Navigate to any shelf; before API response arrives, verify empty bookcase with 4 shelf rows renders as loading skeleton
- Verify no error message during loading

#### Empty States (per shelf, US-1.6.5 validated here)
- Library empty: "Your library is waiting. Move a book here when you've finished reading it."
- AntiLibrary empty: "Books you own but haven't read yet. Upload a photo to start building your collection."
- WishList empty: "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
- Reading Pile empty: "Nothing on the pile right now. Move a book from your Antilibrary to start reading." with armchair scene
- Looking for Home empty: "Nothing here yet -- these are books looking for a new home."

#### Shelf Transitions (US-1.2.5)
- Navigate from Library to AntiLibrary (adjacent shelf): verify horizontal slide CSS transition
- Navigate from Library to Reading Pile: verify fade-through-darkness transition (room transition)
- Verify correct transition CSS classes applied during animation

#### View Mode Toggle
- On any bookcase shelf, verify `view-mode-toggle` button present
- Click toggle: verify switch from `SpineView` (bookcase) to `ListView` (sortable table)
- In list view, verify columns: Title, Author, Pages, Date Added, Formats
- Verify sort by clicking column headers (toggles Asc/Desc)

#### RSS Link Visibility
- On a shelf with visibility set to allow RSS: verify RSS link is visible
- On a private shelf: verify RSS link is hidden

#### Error State
- Mock `GET /api/bookshelves/library` to return 500
- Verify error message: "Could not load your library. Please try again."

#### Age Gate (403)
- Mock API to return 403 for an age-gated shelf context
- Verify `Components.AgeGate.ageGate` renders with Verify/Dismiss buttons
- Click Dismiss: verify age gate dismissed (`showAgeGate = False`)
- Click Verify: verify navigation to `/settings/age-verification`

### 2. API Endpoint Tests

#### `GET /api/bookshelves/:bookshelf_name`
- Valid bookshelf name ("library"): returns 200 with `{ bookshelf, count, placements: [...] }`
- Each placement includes: `id`, `position`, `placed_at`, `formats`, `book: { id, title, author, editions, edition_count, primary_edition }`
- Invalid bookshelf name: returns 404 with `{ error: "invalid bookshelf name" }`
- Unauthenticated: returns 401
- Empty bookshelf: returns 200 with `{ count: 0, placements: [] }`
- Visibility filtering: placements with `:hidden` visibility excluded from response
- All five bookshelf names accepted: library, antilibrary, wishlist, reading_pile, looking_for_home

#### ViewAsPlug
- With `view_as` parameter: `ViewAsPlug.authorize_view_as/2` validates context
- `Guardian.Plug.current_resource(conn)` provides authenticated user

### 3. Database Assertion Tests

#### `op.bookshelves`
- Query by `(user_id, name)` uses unique index
- All five bookshelf names queryable per user

#### `op.bookshelf_placements`
- Placements query: JOIN on `bookshelf_id`, filtered by `removed_at IS NULL`
- Order by `position`, `placed_at`
- Preloads: `book: [:author, :editions]`
- FK index on `bookshelf_id` used
- Partial index on `removed_at IS NULL` used

#### Query Performance
- Bookshelf lookup: single query (no N+1)
- Placements with preloads: predictable query count

### 4. Event Flow Tests

N/A — shelf browsing is a read-only operation. No events are emitted during browse.

### 5. Background Job Tests

N/A — no background jobs are triggered by browsing a shelf.

### 6. External Service Tests

N/A — no external services are called during shelf browsing.

### 7. Storage Tests

N/A — cover images referenced in `edition.cover_image_url` are pre-stored URLs. No storage operations during browse.

### 8. Cache Tests

N/A — bookshelf listings are not cached. Each browse hits the database directly. (BookDetailCache is only for individual book detail lookups.)

### 9. dbt Model Tests

#### Staging Models
- `stg_bookshelves` reflects current bookshelf data
- `stg_bookshelf_placements` reflects active placements (where `removed_at IS NULL`)
- Placement data feeds into `mart_community_read_count` and other aggregates

#### Refresh Triggers
- `placement.created` and `placement.moved` events trigger `DbtRefreshHandler`

### 10. Elm State Machine Tests

#### Page.Bookshelf (shared module) — Library Config
- `init libraryConfig maybeToken userId` fires `Api.getBookshelf "library" token BooksLoaded`
- Initial model: `books = Loading`, `showAgeGate = False`, `viewMode = SpineView`, `sortState = { column = Title, direction = Asc }`
- `BooksLoaded (Ok placements)` -> `books = Success placements`
- `BooksLoaded (Err (Http.BadStatus 403))` -> `books = Failure`, `showAgeGate = True`
- `BooksLoaded (Err err)` -> `books = Failure err`
- `BookClicked book` -> OutMsg `NavigateTo (BookDetail book.id)`
- `ViewModeChanged mode` -> `viewMode = mode`
- `SortColumnClicked column` -> toggles direction if same column, sets Asc on new column
- `VerifyAge` -> OutMsg `NavigateTo SettingsAgeVerification`
- `DismissAgeGate` -> `showAgeGate = False`

#### Config Variants
- `libraryConfig`: `apiName = "library"`, `themeClass = "shelf-library"`, `wallpaperClass = "wallpaper--damask"`, `wearLevel = Softened`
- `antilibraryConfig`: `apiName = "antilibrary"`, `themeClass = "shelf-antilibrary"`, `wallpaperClass = "wallpaper--botanical"`, `wearLevel = Pristine`
- `wishlistConfig`: `apiName = "wishlist"`, `themeClass = "shelf-wishlist"`, `wallpaperClass = "wallpaper--floral"`, `wearLevel = Pristine`

#### Row Grouping
- `groupIntoRows 990` fills rows to max 990px width
- `minShelfRows 4` pads to at least 4 rows

#### NotAsked State (no token)
- No API call fired; empty bookcase renders in Loading state

### 11. Metrics & Telemetry Tests

#### HTTP Metrics
- `http.request.count{endpoint="/api/bookshelves/library"}` incremented per request
- `http.response.status{status=200}` >= 99% of requests
- `http.response.status{status=404}` < 1% of requests

#### Database Metrics
- `db.query.count{table="op.bookshelf_placements", op="select"}`: 1 per request (no N+1)
- `db.query.duration{table="op.bookshelf_placements"}`: p95 < 50ms
- `db.query.count{table="op.bookshelves", op="select"}`: 1 per request
- `db.query.duration{table="op.bookshelves"}`: p95 < 10ms

#### Error Rate
- `error.rate{endpoint="/api/bookshelves/*"}` < 0.1%

#### Performance
- Page load time (navigation to `BooksLoaded`): p50 < 400ms, p95 < 1200ms
- Shelf render time (`groupIntoRows` + render): p95 < 100ms for 200 books

## Dependencies
- Seeded bookshelf data with placements and books
- Playwright test harness with auth helpers
- `data-testid` attributes on shelf UI elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
