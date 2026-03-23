# Issue #127: E2E Test Suite — Community Shelf & Accessibility

## Summary
Comprehensive E2E test coverage for the Looking for a Home shelf with marketplace exception (US-18.1.1), ARIA label coverage (US-19.1.1), keyboard navigation (US-19.1.2), and list view toggle (US-19.2.1).

## User Stories
US-18.1.1 (Browse the Looking for a Home Shelf), US-19.1.1 (ARIA Labels for Visual Elements), US-19.1.2 (Keyboard Navigation), US-19.2.1 (List View Toggle)

## Goal
Validate the Looking for a Home shelf rendering and marketplace integration, comprehensive ARIA label audit across all components, keyboard navigation with skip link and focus management, and the list view toggle with sortable columns.

## Scope Check
- Does this issue touch more than 3 controllers? No (BookshelfController for LFH; rest is frontend-only).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (LFH is the community shelf; accessibility applies to it and all other pages).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **LFH shelf render**: Navigate to `/looking-for-home` -> books displayed in `div.pile-view` with cover cards
- **LFH empty state**: No placements -> "Nothing here yet — these are books looking for a new home."
- **LFH age gate**: 403 response -> age gate overlay with "Verify Age" and "Dismiss" buttons
- **LFH loading state**: "Loading your books looking for a home..." message during load
- **LFH in nav**: "Looking for a Home" nav item between Reading Pile and Catalogue
- **LFH swipe**: Part of swipe navigation sequence (5th/last shelf)
- **Skip link**: Focus on page -> Tab -> skip link becomes visible at top
- **Skip link activation**: Tab to skip link -> Enter -> focus moves to `#main-content`
- **Focus indicators**: All focusable elements show amber outline on `focus-visible`
- **Book detail overlay focus**: Open overlay -> focus on close button; close -> focus returns to triggering spine
- **Escape key on overlay**: Overlay closes, focus returns to spine
- **Escape key on menu**: User menu closes
- **List view toggle**: Click "List view" button -> table renders with Title, Author, Pages, Date Added, Formats columns
- **Spine view toggle**: Click "Spine view" button -> visual spine bookshelf renders
- **Column sort**: Click column header -> sort ascending; click again -> descending
- **Sort indicators**: "^" for ascending, "v" for descending in header
- **Row click**: Click table row -> book detail overlay opens
- **Toggle keyboard**: Tab + Enter/Space activates view mode toggle

### 2. Playwright Navigation & Visual Tests
- **LFH auth guard**: Unauthenticated user at `/looking-for-home` sees login page
- **Toggle active state**: Active toggle button gets `view-mode-toggle__btn--active` class
- **Format badges**: Physical, eBook, Audiobook badges render in list view

### 3. API Endpoint Tests
- `GET /api/bookshelves/looking_for_home` — 200 with placements
- `GET /api/bookshelves/looking_for_home` — 401 without auth
- `GET /api/bookshelves/looking_for_home` — 403 for age-gated content
- `GET /api/bookshelves/looking_for_home` — supports `?view_as=<perspective>` query param
- N/A for ARIA, keyboard, list view (all frontend-only)

### 4. Database Assertion Tests
- LFH query: `bookshelf_placements` joined with `bookshelves` where `name == "looking_for_home"` and `removed_at IS NULL`
- Preloads: book data (title, author, page count, editions, subjects)
- N/A for ARIA, keyboard, list view

### 5. Event Flow Tests
- N/A — browsing LFH does not emit events
- N/A for ARIA, keyboard, list view

### 6. Background Job Tests
- N/A

### 7. External Service Tests
- N/A

### 8. Storage Tests
- N/A
- List view: view preference not currently persisted (resets on navigation)

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- `stg_bookshelf_placements` and `stg_bookshelves` staging models consume LFH data

### 11. Elm State Machine Tests
- **LFH**: `LookingForHome.init maybeToken` -> `{ books = Loading, showAgeGate = False }`, fires `Api.getBookshelf "looking_for_home"`
- `BooksLoaded (Ok placements)` -> `books = Success placements`
- `BooksLoaded (Err (Http.BadStatus 403))` -> `showAgeGate = True`
- `VerifyAge` -> OutMsg `NavigateTo SettingsAgeVerification`
- `DismissAgeGate` -> `showAgeGate = False`

**ARIA audit (existing implementations)**:
- `Components.Spine`: `aria-label` = `"Book: {title} by {author}, {pages} pages{wearSuffix}"`
- `Page.Login`: `role="tablist"`, `role="tab"`, `aria-selected`, `aria-required="true"`, `aria-live="polite"`
- `Components.UserMenu`: `aria-label="User menu"`, `aria-expanded`, `aria-haspopup="true"`
- `Components.OnboardingOverlay`: `role="dialog"`, `aria-modal="true"`, `aria-label="Welcome to The Stacks"`
- `Main.elm` nav: `aria-label="Main navigation"`
- `Main.elm` skip link: `a.skip-link[href="#main-content"]`
- `Page.Bookshelf`: `aria-live="polite"` on content wrapper
- `Components.BookList`: `role="table"`, `scope="col"`, `aria-sort`, `role="row"`
- `Components.ViewModeToggle`: `role="group"`, `aria-label="View mode"`, `aria-pressed`, `aria-label="Spine view"/"List view"`

**Keyboard navigation**:
- Global `onKeyDown` subscription for Escape key
- `EscapePressed` with overlay: close overlay, `Browser.Dom.focus ("spine-" ++ bookId)`
- `EscapePressed` without overlay: close user menu
- `openOverlay`: sets `triggerSpineId`, calls `Browser.Dom.focus "book-overlay-close"`
- `FocusResult` msg: no-op handler for focus result
- Focus indicators: `*:focus-visible { outline: 2px solid #d4a029 }`

**List view**:
- `ShelfViewMode = SpineView | ListView`
- `ViewModeToggle.view` renders two buttons with `aria-pressed`
- `BookList` sort: `SortState = { column : SortColumn, direction : SortDirection }`
- `SortColumn = Title | Author | PageCount | DateAdded | Formats`
- `sortPlacements` sorts by active column, reverses for Desc
- Default sort: Title ascending
- Click header: cycles sort direction
- Click row: fires `onBookClicked` handler
- Fallback: "Unknown Title" / "Unknown Author" for missing book data

### 12. Metrics & Telemetry Tests
- LFH page load rate, API success rate, age gate trigger rate
- Empty shelf rate, placement count distribution
- ARIA attribute coverage: automated axe-core/Lighthouse audit
- Missing ARIA label count target: zero
- Focus management success rate for overlay open/close
- Skip link usage rate
- Escape key event rate by context
- View mode distribution (Spine vs List)
- Toggle switch rate, sort usage rate
- Sort column distribution, sort direction preference
- List view book click rate
- Keyboard-only session rate (proxy metric)

## Reviewer Context
- LFH marketplace exception: placements with `listing_status: "active"` on `looking_for_home` shelf bypass visibility checks (they must be discoverable for marketplace).
- Spine ARIA labels only cover `Pristine` and `Softened` wear states — other wear states are missing.
- Focus trapping in overlays is NOT yet implemented — focus can Tab outside the overlay.
- Arrow key navigation within bookshelves is NOT implemented (spec gap).
- List view preference does NOT persist across navigation — resets to spine view.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Automated accessibility audit (axe-core) passes with zero critical violations
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires LookingForHome page, BookshelfController, ARIA implementations across all components, SwipeNavigation module, BookList/ViewModeToggle components.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
