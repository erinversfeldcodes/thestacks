# Issue #113: E2E Test Suite — Spine Rendering

## Summary
Comprehensive end-to-end test coverage for book spine rendering, including thickness calculation from page count, wear level application per shelf context, 3D structure, textures, and accessibility attributes.

## User Stories Covered
- [US-1.3.1 — Spine Thickness by Page Count](../docs/user_stories/US-1.3.1-spine-thickness.md)
- [US-1.3.2 — Spine Wear by Engagement](../docs/user_stories/US-1.3.2-spine-wear.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (test-only, no controllers).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all spine rendering).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Spine Width by Page Count (US-1.3.1)
- Seed books with varying page counts: 100, 200, 300, 420, 600, 660, 800
- Navigate to a shelf containing these books
- Verify spine widths match formula `max(35, min(55, round(pageCount / 12)))`:
  - 100 pages -> 35px (minimum)
  - 200 pages -> 35px (round(200/12) = 17, clamped to min 35)
  - 300 pages -> 35px (round(300/12) = 25, clamped to min 35)
  - 420 pages -> 35px (round(420/12) = 35)
  - 600 pages -> 50px (round(600/12) = 50)
  - 660 pages -> 55px (round(660/12) = 55, clamped to max 55)
  - 800 pages -> 55px (maximum)
- Verify width varies continuously — a 480-page book (40px) is visibly thinner than a 540-page book (45px)

#### Missing Page Count Default (US-1.3.1)
- Seed a book with no `page_count` on primary edition
- Verify spine renders at default width: `spineWidth 200 = 35px` (minimum)

#### 3D Spine Structure
- Verify each book element has three visible faces:
  - `book__spine` (the front-facing spine with title text)
  - `book__top` (the top edge)
  - `book__cover` (the partial cover face visible at an angle)
- Verify `book__face` class applied to structural elements

#### Spine Textures
- Verify spine texture classes applied correctly per book
- Verify texture varies between books (not all identical)

#### Wear Level by Shelf (US-1.3.2)
- Navigate to WishList: verify spines render with `Pristine` wear (sharp edges, clean texture, vibrant colours)
- Navigate to AntiLibrary: verify spines render with `Pristine` wear (per codebase — `wearLevel = Pristine`)
- Navigate to Reading Pile: verify spines render with `Softened` wear
- Navigate to Library: verify spines render with `Softened` wear
- Verify visual distinction between Pristine and Softened wear states is present

#### ARIA Labels (US-1.3.1, US-1.3.2)
- Verify each spine button has an `aria-label` attribute
- Verify `aria-label` includes the book title
- Verify `aria-label` includes page count (e.g., "420 pages")
- Verify `aria-label` includes wear state suffix (e.g., ", well-loved" for Softened)
- Verify `role="listitem"` on each spine button
- Verify `role="list"` on `shelf-row__books` container

#### Books with User Writing (US-1.3.2)
- Seed a book that has associated user writing (blog post)
- Verify bookmark ribbon or coloured tabs visible on the spine

### 2. API Endpoint Tests

#### Spine Data via Bookshelf API
- `GET /api/bookshelves/:name` returns placements with `book.primary_edition.page_count`
- Page count is an integer or null
- Verify `page_count` propagates correctly through the JSON response

#### `GET /api/spine_data/:placement_id` (server-side wear calculation)
- Returns wear level based on `PlacementHistory` move count
- move_count 0: `:pristine`
- move_count 1: `:softened`
- move_count 2+: `:well_loved`
- Verify `Shelving.spine_data/1` function returns correct structure

### 3. Database Assertion Tests

#### `op.book_editions`
- Verify `page_count` column exists and accepts integer values
- Verify NULL `page_count` is handled (no crash, defaults applied at render time)

#### `op.bookshelf_placement_history`
- Move count calculation: `COUNT(*)` from `placement_history` for a given book+user
- Used by `Shelving.spine_data/1` for server-side wear level

### 4. Event Flow Tests

N/A — spine rendering is purely presentational, driven by existing data. No events emitted.

### 5. Background Job Tests

N/A — no background jobs involved in spine rendering.

### 6. External Service Tests

N/A — no external services called during spine rendering.

### 7. Storage Tests

N/A — no storage operations during spine rendering.

### 8. Cache Tests

N/A — spine data is not cached independently.

### 9. dbt Model Tests

N/A — spine rendering reads from existing staging models (`stg_bookshelf_placements`, `stg_book_editions`). No specific dbt validation needed beyond what Issue #112 covers.

### 10. Elm State Machine Tests

#### `Components.Spine.spineWidth` (pure function)
- `spineWidth 100 = 35` (below minimum)
- `spineWidth 200 = 35` (round(200/12)=17, clamped)
- `spineWidth 420 = 35` (round(420/12)=35)
- `spineWidth 480 = 40` (round(480/12)=40)
- `spineWidth 540 = 45` (round(540/12)=45)
- `spineWidth 600 = 50` (round(600/12)=50)
- `spineWidth 660 = 55` (round(660/12)=55, at maximum)
- `spineWidth 1000 = 55` (above maximum, clamped)
- `spineWidth 0 = 35` (edge case, minimum)

#### `bookPageCount` helper
- Returns `Just pageCount` when `primary_edition.page_count` is present
- Returns `Nothing` when `page_count` is null or edition missing
- Default of 200 applied when `Nothing`

#### Wear Level Rendering
- `Components.Spine.book` with `wearLevel = Pristine`: renders pristine CSS classes
- `Components.Spine.book` with `wearLevel = Softened`: renders softened CSS classes
- Wear level sourced from `Page.Bookshelf.config.wearLevel` (not computed per book on frontend)

#### Shelf Config Wear Levels
- `libraryConfig.wearLevel = Softened`
- `antilibraryConfig.wearLevel = Pristine`
- `wishlistConfig.wearLevel = Pristine`
- `ReadingPile` hardcodes `Softened`

### 11. Metrics & Telemetry Tests

N/A — spine rendering is purely client-side. No server telemetry emitted for rendering. Performance metrics (shelf render time) are covered in Issue #112.

## Dependencies
- Seeded books with varying page counts and editions
- Seeded placements on multiple shelves
- Seeded placement history records for wear level testing
- `data-testid` attributes on spine elements (Issue #108)

## Agent Assignment
`elm-agent` for state machine / pure function tests, `playwright-agent` for visual rendering tests.

## Progress Notes
[Updated by agents during execution.]
