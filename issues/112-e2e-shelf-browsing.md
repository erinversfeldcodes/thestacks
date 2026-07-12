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

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.2.1 — Browse the Library Shelf | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.2.2 — Browse the AntiLibrary Shelf | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.2.3 — Browse the WishList Shelf | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.2.4 — Browse the Reading Pile | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.2.5 — Shelf Transitions | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #112)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

This is a **pre-implementation baseline** for Issue #112: it records what
coverage exists *before* the issue's test suites are written. Many ❌
cells are expected — the punch list below is the issue's work queue.
Every ❌ is tagged either **[test missing, feature exists]** (the
route/module/function was verified in `apps/core/lib` or `frontend/src`)
or **[feature not implemented]**.

User stories audited:

- US-1.2.1 — Browse the Library bookshelf (`docs/user_stories/US-1.2.1-browse-library.md`)
- US-1.2.2 — Browse the AntiLibrary bookshelf
- US-1.2.3 — Browse the WishList bookshelf
- US-1.2.4 — Browse the Reading Pile
- US-1.2.5 — Bookshelf navigation transitions

(The issue also exercises the Looking for Home page and the per-shelf
empty states of US-1.6.5; those assertions are folded into the E2E
inventory below rather than given their own matrix columns.)

---

### Framework-layer summary

| Layer       | US-1.2.1 | US-1.2.2 | US-1.2.3 | US-1.2.4 | US-1.2.5 |
|-------------|----------|----------|----------|----------|----------|
| Elixir      | ✅       | ✅       | ✅       | ⚠️       | n/a      |
| Elm unit    | ✅       | ❌       | ❌       | ❌       | ⚠️       |
| Elm program | ✅       | ❌       | ❌       | ❌       | ⚠️       |
| Python      | n/a      | n/a      | n/a      | n/a      | n/a      |
| E2E         | ✅       | ⚠️       | ⚠️       | ⚠️       | ⚠️       |
| dbt         | ✅       | n/a      | n/a      | n/a      | n/a      |

- **Elixir** row: `GET /api/bookshelves/:bookshelf_name` is one shared
  controller; `bookshelf_controller_test.exs` covers library/wishlist
  deeply and all five names via "returns all valid bookshelf names".
  US-1.2.4 is ⚠️ because `reading_pile` is only touched by that
  name-loop (no per-shelf response-content assertion).
- **Python** row: n/a — no vision-service involvement in shelf browsing.
- **US-1.2.5** Elixir: n/a — transitions have no dedicated API call.

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **38** |
| ⚠️ shallow | **12** |
| ❌ missing | **26** |
| n/a (covered higher up / not applicable / by-design) | **54** |

130 matrix cells (13 layers × 5 US × happy/sad). Of the 26 ❌ cells,
**25 are [test missing, feature exists]** and **1 is [feature gap]**
(no `bookshelves_p95_ms` SLI in the SLO gate — see punch #24).

---

### Full audit tables

#### Layer 1: API Calls (`GET /api/bookshelves/:bookshelf_name` → `BookshelfController.show`)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.2.1 | ✅ bookshelf_controller_test.exs — "returns 200 with shelves when bookshelf has books" (asserts `bookshelf`, `count`, nested placements, `book.id`); serialization: "includes book editions in placement response", "includes primary_edition when book has editions", "includes author in book response", "returns placement fields: position, formats, personal_rating, notes" | STRONG | ✅ bookshelf_controller_test.exs — "returns 404 for invalid bookshelf name" + "returns 401 when not authenticated" | STRONG |
| 1.2.2 | ✅ bookshelf_controller_test.exs — "returns all valid bookshelf names" (loop asserts 200 + `bookshelf == "antilibrary"`); serialization tests above are shelf-name-agnostic | STRONG | ✅ Same shared endpoint sad-path tests ("returns 404 for invalid bookshelf name", "returns 401 when not authenticated") | STRONG |
| 1.2.3 | ✅ bookshelf_controller_test.exs — "returns 200 with empty shelves when bookshelf has no books" (wishlist; asserts `count == 0`, empty placements) | STRONG | ✅ Same shared endpoint sad-path tests | STRONG |
| 1.2.4 | ⚠️ bookshelf_controller_test.exs — "returns all valid bookshelf names" covers `reading_pile` name acceptance only; no test asserts a populated reading_pile response body | SHALLOW | ✅ Same shared endpoint sad-path tests | STRONG |
| 1.2.5 | n/a — no dedicated API for transitions; each destination's GET is covered by US-1.2.1–1.2.4 rows | — | n/a — same | — |

#### Layer 2: Auth & Middleware Guards (`:authenticated` pipeline + `ViewAsPlug`)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.2.1 | ✅ bookshelf_controller_test.exs — authenticated happy paths via `auth_conn(user)`; view_as: "returns 403 when non-owner requests view_as perspective on another user's bookshelf"; view_as_plug_test.exs — "parses unauthenticated"/"parses platform"/"parses user:<uuid>" + "resource owner can use unauthenticated on their own resource" | STRONG | ✅ bookshelf_controller_test.exs — "returns 401 when not authenticated"; unauthenticated_redirect_test.exs — "GET /api/bookshelves/library without auth returns 401"; view_as_plug_test.exs — "unknown perspective receives 422" | STRONG |
| 1.2.2 | ✅ Implicit via shared `:authenticated` pipeline tests above (single route, name is a path param) | STRONG | ✅ Same shared tests | STRONG |
| 1.2.3 | ✅ Same | STRONG | ✅ Same | STRONG |
| 1.2.4 | ✅ Same | STRONG | ✅ Same | STRONG |
| 1.2.5 | n/a — client-side route change only; no middleware involved | — | n/a | — |
| visibility (cross-US) | ✅ bookshelf_controller_test.exs — "owner sees their own bookshelf even with owner visibility" | STRONG | ✅ "returns 404 when requesting another user's owner-visibility bookshelf" + "filters out owner-visibility placements from platform-visibility bookshelf" + "does not return placements belonging to another user" | STRONG |

#### Layer 3: Database Interactions

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.2.1 | ✅ shelving_test.exs — "returns active placements on bookshelf" (`get_bookshelf_books/2`); shelving_shelf_test.exs — "returns shelves in ascending position order" (`list_shelves/1`, #151 shelf grouping) | ✅ shelving_test.exs — "excludes removed placements" + "returns empty list for bookshelf with no books"; bookshelf_controller_test.exs — "does not include removed placements" + "returns empty shelves list when bookshelf does not exist yet" |
| 1.2.2 | ✅ Same context functions (bookshelf-name-agnostic); factory-backed via `insert(:bookshelf, name: ...)` | ✅ Same |
| 1.2.3 | ✅ Same | ✅ Same |
| 1.2.4 | ✅ Same (`get_bookshelf_books/2` is shared) | ✅ Same |
| 1.2.5 | n/a — no DB interaction in transitions | n/a |
| indexes (cross-US) | ❌ **[test missing, feature exists]** — no test asserts the `(user_id, name)` unique-index lookup path or the partial index on `removed_at IS NULL` is used; indexes exist (`20260305000005_create_bookshelves.exs` — `create unique_index(:bookshelves, [:user_id, :name])`; `20260305000006_create_bookshelf_placements.exs` — partial unique index `WHERE removed_at IS NULL`) | ❌ **[test missing, feature exists]** — no N+1 / query-count assertion for placements-with-preloads (`book: [:author, :editions]`) |

#### Layer 4: Event Flow & Lifecycle

All cells `n/a — shelf browsing is read-only; no events are emitted during
browse` (per Issue #112 §4). Placement mutation events (`placement.created`,
`placement.moved`, `placement.removed`) are covered by shelving_test.exs
("emits placement.created event", "emits placement.moved event", "emits
placement.removed event") but belong to US-1.6.x, not browsing.

#### Layer 5: Background Jobs (Oban)

All cells `n/a — no background jobs are triggered by browsing a shelf`
(per Issue #112 §5).

#### Layer 6: External Service Calls

All cells `n/a — no external services are called during shelf browsing`
(per Issue #112 §6).

#### Layer 7: Storage (R2 / Local)

All cells `n/a — cover images are pre-stored URLs in
edition.cover_image_url; no storage operations occur during browse`
(per Issue #112 §7).

#### Layer 8: Cache Interactions

All cells `n/a — bookshelf listings are not cached by design; each browse
hits the database. BookDetailCache only serves individual book detail
lookups` (per Issue #112 §8).

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.2.1 | ✅ dbt/models/staging/schema.yml — `stg_bookshelves`: `not_null`+`unique` on `id`, `not_null` on `created_at`/`updated_at`; `stg_bookshelf_placements`: `not_null`+`unique` on `id`, `accepted_values` on `reading_status`; marts/schema.yml — `mart_community_read_count.book_id`: `not_null` + `relationships` to `ref('stg_books')` + `unique` | ❌ **[test missing, feature exists]** — no `relationships` test on `stg_bookshelf_placements.bookshelf_id` → `stg_bookshelves.id` nor on `.book_id` → `stg_books.id` (columns exist in schema.yml with no tests; schema.yml is proto-generated, so the fix goes through the generator or a singular test) |
| 1.2.2 | n/a — same proto-generated staging models; per-shelf-name repetition adds no guarantee | n/a — same |
| 1.2.3 | n/a — same | n/a — same |
| 1.2.4 | n/a — same (`reading_status` `accepted_values` already covers pile semantics) | n/a — same |
| 1.2.5 | n/a — transitions never touch dbt | n/a |
| refresh triggers (cross-US) | ✅ upload_dbt_test.exs — "placement.created event triggers dbt refresh after real placement" + "placement.moved enqueues community read count refresh" | ✅ upload_dbt_test.exs — "book.created + placement.created sequence enqueues exactly one dbt job" (dedup) |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.2.1 | ✅ Page/BookshelfProgramTest.elm — "bookshelf_loading_state: before HTTP response arrives, empty bookcase is shown" + "bookshelf_renders_placements: successful response with placements renders spine elements"; Page/LibraryProgramTest.elm — "page renders wallpaper with damask pattern", "page renders .shelf-label with Library text", "books render inside .bookcase structure with side panels", "clicking a book spine triggers BookClicked"; UpdateTest.elm — "ShelvesLoaded Ok sets showAgeGate = False and shelves = Success"; ShelfDecoderTest.elm — "decodes_nested_placements: decodes placements nested within shelves"; Page/BookshelfShelvesTest.elm — "shelves_rendered_in_order: API response with two shelves renders books from shelf-1 before shelf-2" + "each_shelf_is_distinct_row: each server shelf renders as a separate bookcase__shelf element"; BookcaseHelpersTest.elm — "many books split across multiple rows" (groupIntoRows) | ✅ Page/BookshelfProgramTest.elm — "bookshelf_error_state: HTTP error response shows error message" + "bookshelf_age_gate: 403 response triggers age gate, dismiss hides it"; Page/LibraryProgramTest.elm — "HTTP error response shows error message" + "403 response triggers age gate component"; UpdateTest.elm — "ShelvesLoaded 403 sets showAgeGate = True and shelves = Failure", "ShelvesLoaded NetworkError sets showAgeGate = False and shelves = Failure", "VerifyAge produces NavigateTo SettingsAgeVerification", "DismissAgeGate sets showAgeGate = False"; ShelfDecoderTest.elm — "fails_on_missing_shelves: returns error when shelves key is missing"; empty state: Page/BookshelfProgramTest.elm — "bookshelf_empty_state: successful response with empty list shows empty bookshelf message" |
| 1.2.2 | ❌ **[test missing, feature exists]** — no Elm test instantiates `antiLibraryConfig` (`Page/Bookshelf.elm:63`); all program tests use `libraryConfig` only. Theme/wallpaper/label for antilibrary asserted only at E2E | ❌ **[test missing, feature exists]** — no antilibrary-config error/403 test (shared `update` makes this low-risk, but config wiring — apiName "antilibrary" — is unasserted in Elm) |
| 1.2.3 | ❌ **[test missing, feature exists]** — same for `wishListConfig` (`Page/Bookshelf.elm:74`) | ❌ **[test missing, feature exists]** — same |
| 1.2.4 | ❌ **[test missing, feature exists]** — zero tests for `Page.Bookshelf.ReadingPile` (module exists at `frontend/src/Page/Bookshelf/ReadingPile.elm`: `BookHovered`, `Deselect`, `book-pile__book--selected`, second-click → `NavigateTo (BookDetail id)`). Only RouteTest.elm — "ReadingPile" (route parse) and SwipeTest.elm — "WishList -> ReadingPile" touch it | ❌ **[test missing, feature exists]** — no ReadingPile 403/error/empty-state Elm test |
| 1.2.5 | ⚠️ NavigationProgramTest.elm — "navigate_to_library: /library URL maps to Library route and renders library page content" proves route-driven page swap, but no test asserts `transitionClass` output (`Main.elm:1464`) or `Animation.RoomTransition`/`Animation.SlideTransition` class selection | ❌ **[test missing, feature exists]** — no test that navigating away mid-Loading discards the old model safely (US-1.2.5 sad path) |
| NotAsked / no token (cross-US) | ❌ **[test missing, feature exists]** — no test that `init` with `Nothing` token fires no API call and renders the empty bookcase | — |
| view mode / sort / RSS (cross-US) | ❌ **[test missing, feature exists]** — `ViewModeChanged`, `SortColumnClicked` (`Page/Bookshelf.elm:202-207`), `BookList.view` list-view columns, and `RSSLink.view` (renders only when `visibility == "platform"`, `Components/RSSLink.elm:33`) have zero tests. UpdateTest.elm only *initialises* `viewMode = SpineView` / `sortState` as model fixture | ❌ **[test missing, feature exists]** — no test that RSS link is hidden for non-platform visibility |
| row grouping constants (cross-US) | ⚠️ BookcaseHelpersTest.elm — "single book fits in one row" / "many books split across multiple rows" test `groupIntoRows` with `maxWidth=80`, not the production `990`; `minShelfRows 4` padding is untested | — |

#### E2E (Playwright) assertion inventory

The issue's Playwright section is the primary deliverable; verdicts
against `e2e/tests/`:

| Issue assertion | Verdict |
|-----------------|---------|
| Library `/library` + `shelf-library` + `wallpaper--damask` | ✅ bookshelf.spec.ts — "Library page has shelf-library class and damask wallpaper" |
| `lighting` element present | ❌ **[test missing, feature exists]** (`Page/Bookshelf.elm:234` — `div [ class "lighting" ]`) |
| `shelf-label` contains "Library" | ✅ bookshelf.spec.ts — "Shelf labels have aria-label attribute" (asserts `aria-label` /Library/) |
| Bookcase ≥ 4 `shelf-row` elements | ❌ **[test missing, feature exists]** (`minShelfRows` in `Page/Bookshelf/Helpers.elm`) |
| No `shelf-row__books` exceeds 990px | ❌ **[test missing, feature exists]** (`groupIntoRows 990` in `Page/Bookshelf.elm`) |
| Book spine clickable + ARIA | ✅ bookshelf.spec.ts — "Library books have role=listitem"; book-interaction.spec.ts — "book exists on the shelf and is wrapped in a clickable button" |
| Spine click opens detail overlay | ✅ book-interaction.spec.ts — "clicking a book opens the book detail overlay" |
| `bookcase__side` / `bookcase__inner` | ❌ at E2E **[test missing, feature exists]** — covered at Elm level by LibraryProgramTest.elm "books render inside .bookcase structure with side panels" |
| AntiLibrary theme/wallpaper | ✅ bookshelf.spec.ts — "AntiLibrary page has shelf-antilibrary class and botanical wallpaper" |
| AntiLibrary label "Antilibrary" + ≥4 rows | ❌ **[test missing, feature exists]** |
| WishList theme/wallpaper | ✅ bookshelf.spec.ts — "WishList page has shelf-wishlist class and floral wallpaper" |
| WishList label "Wish List" + ≥4 rows | ❌ **[test missing, feature exists]** |
| Reading Pile pile layout (not bookcase) | ⚠️ reading-pile.spec.ts — "book pile renders with role=list" is guarded by `if ((await pile.count()) > 0)` — silently passes when no books seeded |
| Armchair renders regardless of book count | ✅ bookshelf.spec.ts — "Reading Pile decorative armchair has aria-hidden" (unconditional) + "Reading Pile decorative floor has aria-hidden" |
| Stagger offsets on pile books | ❌ **[test missing, feature exists]** |
| Hover selects; click selected opens overlay | ⚠️ reading-pile.spec.ts — "clicking a book in the pile opens detail" is `if`-guarded; reading-pile-hover.spec.ts — "screenshot hover sequence using mouse move" is a diagnostic with no assertions |
| `Softened` wear on pile spines | ❌ **[test missing, feature exists]** |
| Looking for Home page + empty state | ⚠️ looking-for-home.spec.ts — "page loads with correct theme class" / "page title is visible" ✅, but "page renders content (pile view or empty state)" doesn't assert the themed empty message text |
| Loading skeleton before API response | ❌ at E2E **[test missing, feature exists]** — covered at Elm level by "bookshelf_loading_state: before HTTP response arrives, empty bookcase is shown" |
| Empty-state wording per shelf (US-1.6.5) | ⚠️ bookshelf.spec.ts — "Library/AntiLibrary/WishList/Reading Pile empty state matches US-1.6.5 wording" all wrap the assertion in `if ((await emptyText.count()) > 0)` — never fails when the element is absent |
| Shelf transitions: slide + fade classes | ❌ **[test missing, feature exists]** (`transitionClass` `Main.elm:1464`, `Animation.SlideTransition`, `Animation.RoomTransition`); navigation.spec.ts — "navigating between all shelves preserves auth state" covers navigation but not transition classes |
| View mode toggle → list view, columns, sort | ❌ **[test missing, feature exists]** (`ViewModeToggle.view` + `BookList.view` wired in `Page/Bookshelf.elm:238,300`) |
| RSS link visible on platform-visibility shelf, hidden on private | ❌ **[test missing, feature exists]** (`Components/RSSLink.elm:33`) |
| Mock 500 → "Could not load your library." | ❌ **[test missing, feature exists]** — no `page.route` mocking in any bookshelf spec (only upload-pipeline.spec.ts uses route mocking); Elm-level error message covered by "bookshelf_error_state" |
| Mock 403 → age gate Verify/Dismiss | ❌ at E2E **[test missing, feature exists]** — age-gate.spec.ts — "age-gated book shows age gate for non-verified users" covers the book-detail 403 only; shelf-level 403 covered at Elm level by "bookshelf_age_gate: 403 response triggers age gate, dismiss hides it" |

#### Layer 11: Operational Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| all | ✅ route_group_test.exs — "tags /api/bookshelves/library as :bookshelves" + "tags /api/bookshelves/<name>/placements as :bookshelves" (router-dispatch tagging mechanism); upload_telemetry_test.exs Suite 11 — "422 for invalid bookshelf name emits telemetry" (POST placements route, same tagging path) | ❌ **[feature gap]** — `scripts/check-slo-gate.sh` gates p95 only for `auth`, `catalogue`, `upload` route groups; the `:bookshelves` group (which this endpoint is tagged into) has **no p95 SLI**, so "n/a — covered by SLO gate" does not currently hold for shelf browsing. Also no telemetry-firing test for **GET** /api/bookshelves/:name (Suite 11 covers POST placements only) — **[test missing, feature exists]** |

Per-US repetition is n/a — the route group is shared across all five
bookshelf names; one gate/one firing test covers them all.

#### Layer 12: Performance & Usability Metrics

All cells `n/a — covered by SLO gate, not unit tests`. In-test SLA bounds
(p50 < 400ms page load, `groupIntoRows` p95 < 100ms for 200 books) are an
anti-pattern under variable CI timing — same rationale as the upload
audit. Note the Layer-11 caveat: until `bookshelves_p95_ms` exists in
`check-slo-gate.sh`, the "covered by SLO gate" delegation is aspirational
for this route group (punch #24).

#### Layer 13: Cost Tracking

All cells `n/a — shelf browsing makes no external paid calls (no vision,
no Modal, no upstream ISBN lookups); nothing to record in BudgetTracker`.

---

### Punch list (baseline — work queue for Issue #112)

Every ❌/⚠️ cell, numbered. Suites: **E2E** = `e2e/tests/`, **Elm** =
`frontend/tests/`, **Ex** = `apps/core/test/`, **dbt** = `dbt/`.

| # | Cell | Test needed | Suite / file |
|--:|------|-------------|--------------|
| 1 | L1 US-1.2.4 happy (⚠️) | Populated `reading_pile` response test: seed placements, assert count + nested placement/book fields | Ex — `stacks_web/bookshelf_controller_test.exs` |
| 2 | L3 cross-US happy (❌) | Query-plan / index sanity: bookshelf lookup by `(user_id, name)` and active-placement filter hit their indexes (or an EXPLAIN-based singular check) | Ex — new `stacks/shelving_query_test.exs` |
| 3 | L3 cross-US sad (❌) | N+1 guard: `get_bookshelf_books/2` with `book: [:author, :editions]` preloads runs a bounded query count (ecto telemetry counter) | Ex — same file as #2 |
| 4 | L9 US-1.2.1 sad (❌) | `relationships` tests: `stg_bookshelf_placements.bookshelf_id` → `stg_bookshelves.id` and `.book_id` → `stg_books.id`. schema.yml is proto-generated — add via `mix proto.sync` generator or a singular test | dbt — `dbt/tests/singular/` (or proto manifest) |
| 5 | L10 US-1.2.2 happy+sad (❌) | Program test instantiating `antiLibraryConfig`: apiName "antilibrary" fires correct GET; theme/wallpaper/label classes; 403 + error paths | Elm — `Page/BookshelfProgramTest.elm` |
| 6 | L10 US-1.2.3 happy+sad (❌) | Same for `wishListConfig` | Elm — `Page/BookshelfProgramTest.elm` |
| 7 | L10 US-1.2.4 happy (❌) | `Page.Bookshelf.ReadingPile` tests: init fires `GET /api/bookshelves/reading_pile`; `BooksLoaded Ok` concat-maps shelves→placements; `BookHovered` sets `book-pile__book--selected`; second click emits `NavigateTo (BookDetail id)`; `Deselect` clears | Elm — new `Page/ReadingPileProgramTest.elm` |
| 8 | L10 US-1.2.4 sad (❌) | ReadingPile 403 → age gate, error → "Could not load your reading pile.", empty → "Nothing on the pile right now" | Elm — same file as #7 |
| 9 | L10 US-1.2.5 happy (⚠️) | Unit test for `transitionClass from to`: adjacent shelves → slide class, Library→ReadingPile → room-fade class (expose or extract from `Main.elm:1464`) | Elm — new `TransitionTest.elm` |
| 10 | L10 US-1.2.5 sad (❌) | Navigate away mid-Loading: program test asserting no crash and new page's own Loading state | Elm — `NavigationProgramTest.elm` |
| 11 | L10 cross-US (❌) | `init` with `Nothing` token: no HTTP request fired, empty bookcase renders | Elm — `Page/BookshelfProgramTest.elm` |
| 12 | L10 cross-US (❌) | `ViewModeChanged ListView` swaps to `BookList.view` (columns Title/Author/Pages/Date Added/Formats); `SortColumnClicked` toggles Asc/Desc on same column, resets Asc on new column | Elm — `Page/BookshelfProgramTest.elm` or new `BookListTest.elm` |
| 13 | L10 cross-US (❌) | `RSSLink.view` renders `.rss-link` when `visibility == "platform"`, renders nothing otherwise | Elm — new `RSSLinkTest.elm` |
| 14 | L10 cross-US (⚠️) | `groupIntoRows 990` with realistic spine widths + `minShelfRows 4` pads short shelves | Elm — `BookcaseHelpersTest.elm` |
| 15 | E2E US-1.2.1 (❌) | Library: `lighting` element, ≥4 `shelf-row`, no `shelf-row__books` wider than 990px, `bookcase__side--left/right` + `bookcase__inner` | E2E — `bookshelf.spec.ts` |
| 16 | E2E US-1.2.2 (❌) | AntiLibrary: label "Antilibrary", ≥4 rows | E2E — `bookshelf.spec.ts` |
| 17 | E2E US-1.2.3 (❌) | WishList: label "Wish List", ≥4 rows | E2E — `bookshelf.spec.ts` |
| 18 | E2E US-1.2.4 (⚠️→✅) | Seed reading-pile placements so "book pile renders with role=list" and "clicking a book in the pile opens detail" run unconditionally (remove `if count > 0` guards); add stagger-offset and `Softened` wear assertions; replace assertion-free reading-pile-hover.spec.ts diagnostic with a real hover-select test | E2E — `reading-pile.spec.ts` |
| 19 | E2E empty states (⚠️→✅) | Deterministic empty-state tests: fresh user (or API cleanup) per shelf, assert exact US-1.6.5 wording unconditionally (Library/AntiLibrary/WishList/Reading Pile/Looking for Home) | E2E — `bookshelf.spec.ts`, `looking-for-home.spec.ts` |
| 20 | E2E loading state (❌) | Delay `GET /api/bookshelves/*` via `page.route`; assert empty 4-row bookcase skeleton and no error text before fulfil | E2E — `bookshelf.spec.ts` |
| 21 | E2E US-1.2.5 (❌) | Transition classes: Library→AntiLibrary applies slide class, Library→Reading Pile applies fade-through-darkness class; nav bar stays fixed | E2E — `navigation.spec.ts` or new `transitions.spec.ts` |
| 22 | E2E view mode + RSS (❌) | `view-mode-toggle` present; toggle → list view with sortable columns; RSS link visible on platform-visibility shelf, hidden on private | E2E — `bookshelf.spec.ts` |
| 23 | E2E error + age gate (❌) | `page.route` mock 500 → "Could not load your library. Please try again."; mock 403 → age gate with Verify (→ `/settings/age-verification`) and Dismiss | E2E — `bookshelf.spec.ts` |
| 24 | L11 (❌, feature gap) | Add `bookshelves_p95_ms` SLI (route group `bookshelves`) to `scripts/check-slo-gate.sh`; per scope-lock this is likely a **new issue**, not #112 scope | scripts — `check-slo-gate.sh` (+ new issue) |
| 25 | L11 (❌) | Telemetry-firing test for `GET /api/bookshelves/:name` router-dispatch (`route_group: :bookshelves`), mirroring upload_telemetry_test Suite 11 | Ex — `stacks/upload_telemetry_test.exs` pattern, new `bookshelf_telemetry_test.exs` |

---

### Verdict

**Baseline recorded — not resolved.** The Elixir API/auth/DB layers and
the library-config Elm path are genuinely strong (38 ✅ cells, backed by
`bookshelf_controller_test.exs`, `shelving_test.exs`,
`shelving_shelf_test.exs`, `BookshelfProgramTest.elm`,
`LibraryProgramTest.elm`, `UpdateTest.elm`, `ShelfDecoderTest.elm`).
The dominant gaps, in order of risk:

1. **Reading Pile is nearly untested** — zero Elm tests for
   `Page.Bookshelf.ReadingPile` (hover-select/deselect/navigate state
   machine), only `if`-guarded E2E assertions, and no populated-response
   API test (punch #1, #7, #8, #18).
2. **Conditional E2E assertions** — the empty-state and pile tests wrap
   their expectations in `if (count > 0)`, so they can never fail
   (punch #18, #19).
3. **US-1.2.5 transitions, view-mode/list-view, and RSS visibility have
   no tests at any layer** despite the features existing in
   `Main.elm`/`Page/Bookshelf.elm`/`Components/RSSLink.elm`
   (punch #9, #10, #12, #13, #21, #22).
4. **SLO gate does not cover the `:bookshelves` route group** — the
   Layer 11/12 "covered by SLO gate" delegation is currently unbacked
   for this endpoint (punch #24, scope-lock candidate for a new issue).

Regenerate this audit after the punch list lands; done when 0 ❌ / 0 ⚠️.
## Definition of Done
- [ ] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] `just verify` passes

## Dependencies
- Seeded bookshelf data with placements and books
- Playwright test harness with auth helpers
- `data-testid` attributes on shelf UI elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
