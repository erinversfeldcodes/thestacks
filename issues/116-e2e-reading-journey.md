# Issue #116: E2E Test Suite — Reading Journey

## Summary
Comprehensive end-to-end test coverage for the reading journey lifecycle: moving books between shelves, abandoning books, re-reading, removing from collection, and empty shelf states with per-shelf themed messages.

## User Stories Covered
- [US-1.6.1 — Move a Book Between Shelves](../docs/user_stories/US-1.6.1-move-book.md)
- [US-1.6.2 — Abandon a Book Back to AntiLibrary](../docs/user_stories/US-1.6.2-abandon-book.md)
- [US-1.6.3 — Record Multiple Reads](../docs/user_stories/US-1.6.3-record-reads.md)
- [US-1.6.4 — Remove a Book from the Collection](../docs/user_stories/US-1.6.4-remove-book.md)
- [US-1.6.5 — Empty Shelf States](../docs/user_stories/US-1.6.5-empty-shelf-states.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (BookshelfPlacementController, BookshelfController).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all reading journey).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Move Book Between Shelves (US-1.6.1)
- Open book detail overlay for a book on the WishList
- Click "Choose Bookshelf"; verify dropdown opens with 4 options (current shelf excluded)
- Verify options: Library, Antilibrary, Reading Pile, Looking for a Home (WishList excluded)
- Select "Antilibrary"; click "Move"
- Verify loading state during API call
- On success: verify "Moved successfully." message and `currentBookshelf` updates to "antilibrary"
- Verify shelf mover closes after successful move
- Navigate to AntiLibrary; verify the book now appears there
- Navigate to WishList; verify the book no longer appears

#### Full Reading Journey (WishList -> AntiLibrary -> Reading Pile -> Library)
- Seed a book on WishList
- Move to AntiLibrary; verify success
- Move to Reading Pile; verify success
- Move to Library; verify success
- Verify PlacementHistory tracks all transitions

#### Abandon Book (US-1.6.2)
- Seed a book on Reading Pile
- Open detail overlay; verify `currentBookshelf` shows "reading_pile"
- Move to Antilibrary
- Verify "Moved successfully." (generic message — abandon-specific messaging not yet implemented)
- Navigate to Reading Pile; verify book gone
- Navigate to AntiLibrary; verify book present

#### Re-Read a Book (US-1.6.3)
- Seed a book in the Library
- Move from Library to Reading Pile; verify success
- Move from Reading Pile back to Library; verify success
- Verify each round-trip creates additional PlacementHistory entries
- Note: "Read 3 times" indicator and enhanced wear not yet implemented in UI

#### `Shelving.reread_book/1` (if exposed via endpoint)
- Note: `reread_book/1` is not yet exposed via a controller endpoint
- When wired: verify new placement created (does not update existing), history entry with `placement.reread` event

#### Remove Book (US-1.6.4)
- Open book detail overlay for an owned book
- Scroll to danger zone; click "Remove from collection"
- Verify confirmation modal: "Are you sure you want to remove [Title] from your collection? This cannot be undone."
- Click "Keep It"; verify modal closes, overlay remains
- Click "Remove from collection" again; click "Remove"
- Verify loading state
- On success: verify overlay closes and navigates to previous route (shelf)
- Navigate to the shelf; verify book no longer appears
- Verify book record still exists in database (soft-delete, not hard delete)

#### Remove Sad Paths
- Mock `DELETE /api/placements/:id` to return 403; verify "Failed to remove book. Please try again."
- Mock to return 404; verify error display
- With no placement (`model.placement == Nothing`): `ConfirmRemove` is a no-op
- With no token: `ConfirmRemove` is a no-op

#### Empty Shelf States (US-1.6.5)
- After removing all books from Library: verify "Your library is waiting. Move a book here when you've finished reading it."
- After removing all books from AntiLibrary: verify "Books you own but haven't read yet. Upload a photo to start building your collection."
- After removing all books from WishList: verify "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
- After removing all books from Reading Pile: verify "Nothing on the pile right now. Move a book from your Antilibrary to start reading." with armchair scene
- After removing all books from Looking for Home: verify "Nothing here yet -- these are books looking for a new home."
- Verify empty bookshelves render inside a bookcase with empty shelf rows (Library, AntiLibrary, WishList)
- Verify Reading Pile empty state shows armchair scene

#### Move Sad Paths
- Mock `PUT /api/placements/:id/move` to return 403 (not owner); verify error
- Mock to return 422 (invalid shelf); verify error
- With `model.placement == Nothing`: `ConfirmMove` is a no-op
- With no token: `ConfirmMove` is a no-op

### 2. API Endpoint Tests

#### `PUT /api/placements/:id/move`
- Valid move (owner, valid shelf): returns 200
- Request body: `{ bookshelf: "target_name" }`
- All 5 shelf names accepted as targets: library, antilibrary, wishlist, reading_pile, looking_for_home
- Non-owner: returns 403
- Invalid shelf name: returns 422
- Non-existent placement: returns 404
- Unauthenticated: returns 401
- Move to same shelf (no-op or error): verify behaviour

#### `DELETE /api/placements/:id`
- Valid remove (owner): returns 200, soft-deletes (sets `removed_at`)
- Non-owner: returns 403
- Non-existent placement: returns 404
- Already-removed placement: verify behaviour (idempotent or error)
- Unauthenticated: returns 401

#### Ownership Verification
- `Shelving.move_book/3` verifies user owns the placement via bookshelf -> user_id
- `Shelving.remove_book/2` verifies ownership

### 3. Database Assertion Tests

#### Move: `op.bookshelf_placements`
- `bookshelf_id` updated to target bookshelf's ID
- `removed_at` remains NULL (move, not remove)

#### Move: `op.bookshelf_placement_history`
- New row INSERT with:
  - `from_bookshelf` = source bookshelf UUID
  - `to_bookshelf` = target bookshelf UUID
  - Timestamp recorded

#### Move: Ecto.Multi Transaction
- Placement update, history insert, event emit, audit log — all atomic
- If any step fails, entire transaction rolls back
- Verify no partial state on failure

#### Remove: `op.bookshelf_placements`
- `removed_at` TIMESTAMPTZ set to current time
- Record NOT deleted (soft-delete)
- Book record in `op.books` unaffected

#### Remove: Ecto.Multi Transaction
- Placement soft-delete + event emit + audit log — all atomic

#### Re-Read: `op.bookshelf_placement_history`
- Each Library -> Reading Pile -> Library round-trip creates 2 history entries
- Move count derivable from history count for a given book+user

#### Empty Shelf: `op.bookshelf_placements`
- Query with `removed_at IS NULL` returns empty list
- API returns `count: 0, placements: []`

### 4. Event Flow Tests

#### Move Events
- `placement.moved` emitted by `Shelving.move_book/3` via `Events.emit_safe/1`
- Payload: `%{from_bookshelf: uuid, to_bookshelf: uuid, placement_id: uuid}`
- Recorded in `event_log` with `aggregate_type: "placement"`, `event_type: "placement.moved"`

#### Move Event Handlers
- `Stacks.Feeds.Handlers.PlacementHandler` triggered -> activity feed updated
- `Stacks.Workers.DbtRefreshHandler` triggered -> dbt models refreshed

#### Remove Events
- `placement.removed` emitted by `Shelving.remove_book/2` via `Events.emit_safe/1`
- Payload: placement details
- Recorded in `event_log`

#### Remove Event Handlers
- `PlacementHandler` triggered -> feed updated
- `DbtRefreshHandler` triggered -> dbt models refreshed

#### Re-Read Events
- `placement.reread` emitted by `Shelving.reread_book/1`
- Recorded in `event_log`

#### Audit Log
- Move: audit log entry created with action, user, placement details
- Remove: audit log entry created

#### Event Sequence
- Move: `placement.moved` is the only event (no `placement.created` or `placement.removed`)
- Remove: `placement.removed` is the only event

### 5. Background Job Tests

#### Feed Regeneration
- `placement.moved` event triggers feed regeneration via `PlacementHandler`
- `placement.removed` event triggers feed regeneration
- Verify feed reflects the change after handler completes

#### dbt Refresh
- `DbtRefreshHandler` enqueues `DbtRefreshJob` on placement events
- Job runs on `:dbt_refresh` queue

### 6. External Service Tests

N/A — move/remove/re-read operations are entirely local. No external services called.

### 7. Storage Tests

N/A — no storage operations during reading journey actions.

### 8. Cache Tests

#### BookDetailCache Invalidation
- After move: `CacheInvalidationHandler` may invalidate cached book detail (if placement changes affect cached data)
- After remove: cache invalidated for affected book

### 9. dbt Model Tests

#### After Move
- `stg_bookshelf_placements`: reflects new `bookshelf_id` for the moved placement
- `stg_bookshelf_placement_history`: contains new history row with `from_bookshelf`, `to_bookshelf`
- `DbtRefreshHandler` triggered by `placement.moved` event

#### After Remove
- `stg_bookshelf_placements`: placement row has `removed_at` set (filtered out of active queries)
- `mart_community_read_count`: decremented for the affected book (if applicable)

#### After Re-Read
- `stg_bookshelf_placement_history`: additional entries for the round-trip
- Move count from history drives `Shelving.spine_data/1` wear level

### 10. Elm State Machine Tests

#### Move Flow (Page.BookDetail)
- `OpenBookshelfMover` -> `bookshelfMoverOpen = True`
- `SelectBookshelf shelfName` -> `selectedBookshelf = shelfName`
- `ConfirmMove` -> `moveState = Loading`, fires `Api.moveBook placement.id selectedBookshelf token MoveCompleted`
- `MoveCompleted (Ok _)` -> `moveState = Success ()`, `currentBookshelf = selectedBookshelf`, `bookshelfMoverOpen = False`
- `MoveCompleted (Err err)` -> `moveState = Failure err`
- With `model.placement == Nothing`: `ConfirmMove` is no-op
- With `maybeToken == Nothing`: `ConfirmMove` is no-op

#### Remove Flow (Page.BookDetail)
- `OpenRemoveModal` -> `removeModalOpen = True`
- `CloseRemoveModal` -> `removeModalOpen = False`
- `ConfirmRemove` -> `removeState = Loading`, `removeModalOpen = False`, fires `Api.removeBook placement.id token RemoveCompleted`
- `RemoveCompleted (Ok _)` -> `removeState = Success ()`, OutMsg `NavigateTo previousRoute`
- `RemoveCompleted (Err err)` -> `removeState = Failure err`
- With `model.placement == Nothing`: `ConfirmRemove` is no-op
- With `maybeToken == Nothing`: `ConfirmRemove` is no-op

#### Shelf Mover Component
- `Components.ShelfMover.shelfMover` renders dropdown of shelves excluding `currentBookshelf`
- All 5 shelf names available minus current

#### Remove Modal Component
- `Components.RemoveBookModal.removeBookModal` renders confirmation text with book title
- "Keep It" (secondary) and "Remove" (danger) buttons

### 11. Metrics & Telemetry Tests

#### HTTP Metrics
- Move endpoint (`PUT /api/placements/:id/move`): request count, latency (p95 < 100ms)
- Remove endpoint (`DELETE /api/placements/:id`): request count, latency (p95 < 100ms)
- Status code distribution for each endpoint

#### Event Metrics
- `event_emitted_count` incremented for `placement.moved`, `placement.removed`, `placement.reread`
- `event_handler_error_count` tracked for handler failures

#### Database Metrics
- `ecto_query_duration` for move/remove operations
- Transaction duration tracked

## Dependencies
- Seeded books with placements on various shelves
- Seeded placement history records
- Ecto.Multi testing infrastructure
- Playwright test harness with auth helpers
- `data-testid` attributes on overlay action elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/job tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
