# Issue #114: E2E Test Suite — Book Detail Overlay

## Summary
Comprehensive end-to-end test coverage for the book detail overlay, including opening/closing behaviour, focus trapping, all detail sections (hero, about, reviews, prices, author, writing, shelf actions), move/remove actions, age gate enforcement, and visibility filtering.

## User Stories Covered
- [US-1.4.1 — Open a Book's Detail Overlay](../docs/user_stories/US-1.4.1-book-detail-overlay.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (BookController, BookshelfPlacementController).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all book detail overlay).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Opening the Overlay
- Click a book spine on any shelf; verify overlay opens on top of current page
- Verify URL does NOT change (overlay is UI state, not a route)
- Verify backdrop renders with blur (`backdrop-filter: blur(4px)`, `rgba(10, 8, 6, 0.75)`)
- Verify overlay card: `max-width: 900px`, `width: 90vw`, `max-height: 90vh`, `overflow-y: auto`
- Verify underlying shelf page remains visible (blurred) behind overlay
- Verify entry animation active on open

#### Closing the Overlay
- Click X button in top-right corner; verify overlay closes, shelf visible
- Click outside overlay (backdrop click); verify overlay closes
- Press Escape key; verify overlay closes
- Verify focus returns to the triggering spine button after close

#### Focus Trapping
- With overlay open, press Tab repeatedly; verify focus cycles within overlay (does not escape to shelf behind)
- Verify first focusable element receives focus on open
- Verify Shift+Tab cycles in reverse

#### Detail Sections — All Present
- Verify hero section renders (book cover image or placeholder, title, author)
- Verify "About" section with book description
- Verify "What People Think" reviews section (Components.ReviewSummary)
- Verify "Where to Buy (ZAR)" prices section (Components.PriceInfo)
- Verify "The Author" section (Components.AuthorCard)
- Verify "My Writing" section (user's blog posts about this book)
- Verify "Shelf Actions" section

#### Shelf Actions — Authenticated Owner
- Verify "Choose Bookshelf" button to open shelf mover
- Verify shelf mover dropdown lists all 5 bookshelves except current
- Verify format toggles visible for owned books
- Verify "Remove from collection" button in danger zone

#### Shelf Actions — Authenticated Non-Owner
- View another user's public book; verify "Add to Collection" action shown
- Verify no Move or Remove actions

#### Shelf Actions — Unauthenticated
- View a public book without auth; verify "Sign In or Register" prompt shown
- Verify no Move, Remove, or Add actions

#### Move Action (within overlay)
- Click "Choose Bookshelf"; verify dropdown opens
- Select target shelf; click "Move"; verify loading state
- Mock API success; verify "Moved successfully." message and `currentBookshelf` updates
- Mock API failure (403); verify "Failed to move book. Please try again."
- Mock API failure (422 invalid shelf); verify error display

#### Remove Action (within overlay)
- Click "Remove from collection"; verify confirmation modal opens on top of overlay
- Verify "Are you sure you want to remove [Title]?" text
- Click "Keep It"; verify modal closes, overlay remains
- Click "Remove"; mock API success; verify overlay closes and navigates to previous route
- Click "Remove"; mock API failure; verify "Failed to remove book. Please try again."

#### Age Gate Enforcement (US-1.1.4 overlap)
- Mock `GET /api/books/:id` to return 403 for age-gated book
- Verify age gate UI renders within the overlay (`showAgeGate = True`)
- Click Verify; verify navigation to age verification settings
- Click Dismiss; verify age gate dismissed but book detail not shown

#### Visibility Filtering
- Request a hidden book (`visibility_tier` hidden); verify 404 response and "Could not load this book"

#### Error States
- Mock `GET /api/books/:id` to return 404; verify "Could not load this book. Please try again."
- Mock `GET /api/books/:id` to return 500; verify error message

#### Loading State
- Before API response, verify loading spinner/skeleton within overlay

### 2. API Endpoint Tests

#### `GET /api/books/:id`
- Valid book ID: returns 200 with `{ book: { id, title, description, author, editions, edition_count, primary_edition, ... }, placement, my_writing }`
- Non-existent book: returns 404
- Age-gated book without verification: returns 403
- Age-gated book with verification: returns 200
- Hidden book (visibility_tier): returns 404
- Optional auth: works without token (public books)
- With token: includes `placement` and `my_writing` data

#### `PUT /api/placements/:id/move`
- Valid move: returns 200 with updated placement
- Invalid target shelf: returns 422
- Non-owner: returns 403
- Non-existent placement: returns 404
- Unauthenticated: returns 401

#### `DELETE /api/placements/:id`
- Valid remove: returns 200 (soft-delete, sets `removed_at`)
- Non-owner: returns 403
- Non-existent placement: returns 404
- Unauthenticated: returns 401

#### `PUT /api/placements/:id/formats`
- Valid format update: returns 200
- Invalid format: returns 422
- Non-owner: returns 403

### 3. Database Assertion Tests

#### `op.books`
- Book detail query: verify correct book loaded by ID
- Visibility check: `Visibility.resolve_visibility/2` returns `:hidden` for invisible books

#### `op.bookshelf_placements`
- Move: verify `bookshelf_id` changes to target bookshelf
- Remove (soft-delete): verify `removed_at` timestamp set, record still exists
- Format update: verify `formats` array updated

#### `op.bookshelf_placement_history`
- On move: new row with `from_bookshelf` and `to_bookshelf` UUIDs
- On remove: history preserved (not deleted)

#### `op.book_editions`
- Editions preloaded correctly: all editions for the book returned
- Primary edition identified correctly

#### Ecto.Multi Transactions
- Move: placement update + history insert + event emit — all atomic
- Remove: placement soft-delete + event emit + audit log — all atomic

### 4. Event Flow Tests

#### Move Events
- `placement.moved` emitted by `Shelving.move_book/3` with `%{from_bookshelf, to_bookshelf}`
- `placement.moved` triggers `PlacementHandler` (feed update) and `DbtRefreshHandler`

#### Remove Events
- `placement.removed` emitted by `Shelving.remove_book/2`
- `placement.removed` triggers `PlacementHandler` (feed update) and `DbtRefreshHandler`

#### Audit Log
- Move creates audit log entry
- Remove creates audit log entry

#### No Events on Read
- `GET /api/books/:id` emits no events (read-only)

### 5. Background Job Tests

N/A — no background jobs triggered directly by overlay interactions. (Move/remove are synchronous API calls.)

### 6. External Service Tests

N/A — book detail overlay reads from local database. No external service calls during overlay display.

### 7. Storage Tests

N/A — cover images are pre-stored URLs in `edition.cover_image_url`. No runtime storage operations.

### 8. Cache Tests

#### BookDetailCache
- First book detail fetch: cache miss, data fetched from DB, cached
- Second fetch for same book: cache hit, no DB query
- After book modification (move/remove): cache invalidated via `CacheInvalidationHandler`
- After cache invalidation: next fetch is cache miss

### 9. dbt Model Tests

#### After Move
- `stg_bookshelf_placements` reflects new `bookshelf_id`
- `stg_bookshelf_placement_history` contains new history row
- `DbtRefreshHandler` triggered by `placement.moved`

#### After Remove
- `stg_bookshelf_placements` reflects `removed_at` set
- `DbtRefreshHandler` triggered by `placement.removed`

### 10. Elm State Machine Tests

#### Page.BookDetail Init
- `init bookId maybeToken maybePreviousRoute`: `book = Loading`, `entryAnimationActive = True`
- API call: `Api.getBook bookId maybeToken BookLoaded`

#### Update Cycle
- `BookLoaded (Ok response)` -> `book = Success response.book`, `placement = response.placement`
- `BookLoaded (Err (Http.BadStatus 404))` -> `book = Failure`
- `BookLoaded (Err (Http.BadStatus 403))` -> `showAgeGate = True`
- `CloseOverlay` -> OutMsg `RequestCloseOverlay`
- `OpenBookshelfMover` -> `bookshelfMoverOpen = True`
- `SelectBookshelf shelfName` -> `selectedBookshelf = shelfName`
- `ConfirmMove` -> `moveState = Loading`, calls `Api.moveBook`
- `MoveCompleted (Ok _)` -> `moveState = Success ()`, `currentBookshelf = selectedBookshelf`, shelf mover closes
- `MoveCompleted (Err err)` -> `moveState = Failure err`
- `OpenRemoveModal` -> `removeModalOpen = True`
- `CloseRemoveModal` -> `removeModalOpen = False`
- `ConfirmRemove` -> `removeState = Loading`, calls `Api.removeBook`
- `RemoveCompleted (Ok _)` -> OutMsg `NavigateTo previousRoute`
- `RemoveCompleted (Err err)` -> `removeState = Failure err`

#### Model Fields
- `bookshelfMoverOpen`, `removeModalOpen`, `formatPickerOpen`: Boolean toggles
- `currentBookshelf`, `selectedBookshelf`: String shelf names
- `moveState`, `removeState`: `RemoteData Http.Error ()`
- `isAuthenticated`: Boolean
- `previousRoute`: `Maybe Route` (for navigation on close/remove)

#### OutMsg
- `RequestCloseOverlay` on dismiss (X, Escape, backdrop)
- `NavigateTo previousRoute` on remove success
- `NoOut` for all other messages

### 11. Metrics & Telemetry Tests

#### HTTP Metrics
- `book_detail_request_count` incremented on `GET /api/books/:id` (labels: status 200, 403, 404)
- Book detail fetch latency: p50 < 50ms, p95 < 150ms

#### BookDetailCache Metrics
- Cache hit/miss ratio (not yet instrumented — verify events exist when added)
- Target: > 80% hit rate for repeat views

#### Move/Remove Metrics
- Move endpoint latency: p95 < 100ms
- Remove endpoint latency: p95 < 100ms
- Event handler execution times for `placement.moved` and `placement.removed`

## Dependencies
- Seeded books with full metadata (editions, authors, reviews, prices)
- Seeded placements on various shelves
- BookDetailCache infrastructure
- Playwright test harness with auth helpers
- `data-testid` attributes on overlay elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/cache tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
