# Issue #116: E2E Test Suite — Reading Journey

## Summary
Comprehensive end-to-end test coverage for the reading journey lifecycle: moving books between shelves, abandoning books, re-reading, removing from collection, empty shelf states with per-shelf themed messages, and tracking reading progress through a book. US-1.6.6 (reading progress) was added to scope 2026-07 as the sixth story in the US-1.6 reading-journey family; its feature is currently **partial** (backend built, frontend UI orphaned) — see the Feature-Completeness Pre-Check.

## User Stories Covered
- [US-1.6.1 — Move a Book Between Shelves](../docs/user_stories/US-1.6.1-move-book.md)
- [US-1.6.2 — Abandon a Book Back to AntiLibrary](../docs/user_stories/US-1.6.2-abandon-book.md)
- [US-1.6.3 — Record Multiple Reads](../docs/user_stories/US-1.6.3-record-reads.md)
- [US-1.6.4 — Remove a Book from the Collection](../docs/user_stories/US-1.6.4-remove-book.md)
- [US-1.6.5 — Empty Shelf States](../docs/user_stories/US-1.6.5-empty-shelf-states.md)
- [US-1.6.6 — Track Reading Progress](../docs/user_stories/US-1.6.6-reading-progress.md) — *added to scope 2026-07; feature partial (see Pre-Check)*

## Scope Check
- Does this issue touch more than 3 controllers? No (BookshelfPlacementController, BookshelfController).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all reading journey).

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
| US-1.6.1 — Move a Book Between Shelves | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.6.2 — Abandon a Book Back to AntiLibrary | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.6.3 — Record Multiple Reads | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.6.4 — Remove a Book from the Collection | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.6.5 — Empty Shelf States | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.6.6 — Track Reading Progress | `PUT /placements/:id/progress` → `update_progress` + `Shelving.update_reading_progress/3` built; `reading_status`/`current_page` cols exist. **Frontend orphaned**: `Components.PlacementCard` mounted nowhere, no `Api.updateProgress`; `placement.reading_started/completed` unregistered in `Events.Registry`; no page-count ceiling | ❌ not driven (no UI wired) | 🟡 partial | **build in-scope**: mount progress UI in ReadingPile/BookDetail + wire `Api.updateProgress`, register events, add page ≤ total guard (see US-1.6.6 Implementation Status). Do NOT E2E-green until built. |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #116)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #116 covers the reading-journey lifecycle — five user
stories (US-1.6.1 move a book, US-1.6.2 abandon, US-1.6.3 record re-reads,
US-1.6.4 remove, US-1.6.5 empty bookshelf states,
`docs/user_stories/US-1.6.*.md`) — so the matrix is 13 layers × 5 US, with
happy/sad columns per cell. The assertion inventory for each layer is taken
from each user story's §3–§13 and Issue #116's "Test Suites" section.

**Feature status:** the reading-journey feature IS implemented server-side.
The `Stacks.Shelving` context (`apps/core/lib/stacks/shelving.ex`) exposes
`move_book/3`, `remove_book/2`, `reread_book/1`, `abandon_book/2`,
`place_book/3` and `spine_data/1`, all using `Ecto.Multi` with an
`:emit_event` step (`Events.emit_safe/1`) and an `:audit` step.
`StacksWeb.BookshelfPlacementController` wires `PUT /api/placements/:id/move`
(param `bookshelf`) and `DELETE /api/placements/:id`; there is **no** `reread`
or `abandon` endpoint (`reread_book/1` and `abandon_book/2` are context-only).
Events route via `Stacks.Events.Registry` to `PlacementHandler` (RSS feeds)
and `DbtRefreshHandler`. Elm surface is `Page.BookDetail` (shelf mover +
remove modal) and the `Page.Bookshelf*` family for empty states. The audit
therefore baselines real coverage rather than marking blanket "not
implemented"; the two genuine code gaps found are flagged inline (reread
ownership, transaction-rollback tests).

---

### Framework-layer summary

Each cell is the **weaker of the happy/sad verdicts** for that framework ×
US (conservative). Full happy/sad detail is in the per-layer tables below.

| Framework    | US-1.6.1 (move) | US-1.6.2 (abandon) | US-1.6.3 (reread) | US-1.6.4 (remove) | US-1.6.5 (empty) |
|--------------|-----------------|--------------------|-------------------|-------------------|------------------|
| Elixir       | ⚠️ (context+controller strong; payload/audit/rollback gaps) | ⚠️ (abandon_book tested; no antilibrary API/payload) | ⚠️ (reread_book tested; **no ownership check**, no payload) | ⚠️ (controller 204/403/404/401 ✅; payload/audit/rollback gaps) | ✅ (empty count=0 + nonexistent covered) |
| Elm unit     | ❌ (no move update tests in UpdateTest.elm) | ❌ | n/a (no reread UI) | ❌ (no remove update tests) | ✅ (BookshelfShelvesTest empty state) |
| Elm program  | ⚠️ (shelf mover open/cancel + current bookshelf only) | ⚠️ (shared move path) | n/a | ⚠️ (remove modal open/cancel only) | ✅ (BookshelfProgramTest + LibraryProgramTest) |
| Python       | n/a — vision service not involved | n/a | n/a | n/a | n/a |
| E2E          | ✅ (move library→wishlist overlay flow) | ❌ (no reading_pile→antilibrary abandon test) | ❌ (no reread round-trip test) | ✅ (remove modal confirm flow) | ⚠️ (conditional `if count>0` guards; LookingForHome wording untested) |
| dbt          | ⚠️ (proto models present; no FK/relationships on history) | ⚠️ | ⚠️ | ⚠️ (removed_at untested; not registered w/ dbt refresh) | n/a (US §11 N/A) |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/shelving_test.exs` — `move_book/3` (3), `remove_book/2` (3 + 1 unauthorized), `reread_book/1` (4), `abandon_book/2` (2), `spine_data/1`, plus `place_book/3` and reading-progress describes
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — `move` (4: 200/403/422-missing/401), `delete` (4: 204/403/404/401), `mine` (4)
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — empty/nonexistent bookshelf (count=0) + visibility
- `apps/core/test/stacks/feeds/handlers/placement_handler_test.exs` — placement.created / .moved (both keys, dedup) / .removed (nil-name no job) / catch-all / missing-placement
- `apps/core/test/stacks/workers/dbt_refresh_job_test.exs` — placement.created → 2 marts, placement.moved → mart_community_read_count
- `frontend/tests/Page/BookDetailProgramTest.elm` — shelf_mover_flow (open+cancel), remove_modal_flow (open+Keep It), placement_loaded
- `frontend/tests/UpdateTest.elm` — BookDetail describe (age-gate + BookLoaded only; **no move/remove**)
- `frontend/tests/Page/BookshelfProgramTest.elm`, `LibraryProgramTest.elm`, `BookshelfShelvesTest.elm` — empty-state rendering
- `e2e/tests/shelf-actions.spec.ts` (move + remove), `bookshelf.spec.ts` + `reading-pile.spec.ts` + `looking-for-home.spec.ts` (empty states)
- `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (reading_status accepted_values, id/timestamps not_null) + `stg_bookshelf_placement_history` (id not_null/unique only)

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **22** |
| ⚠️ shallow | **18** |
| ❌ missing | **11** |
| n/a (covered higher up / not applicable / by-design) | **79** |

130 cells total (13 layers × 5 US × happy/sad). This is the
pre-implementation baseline; Issue #116's DoD requires regenerating this
audit to 0 ❌ / 0 ⚠️ after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ bookshelf_placement_controller_test.exs — "returns 200 when user moves own placement" (`PUT /api/placements/:id/move`, param `bookshelf`) | ✅ | ⚠️ bookshelf_placement_controller_test.exs — "returns 403 when user moves another user's placement" + "returns 422 when bookshelf parameter is missing". BUT no 404 for a nonexistent placement id, no 422 for an invalid bookshelf name, no "all 5 shelf names accepted", and no move-to-same-shelf behaviour test (Issue §2 enumerates all four). | ⚠️ |
| 1.6.2 | ⚠️ Abandon has no dedicated endpoint — it reuses `PUT /api/placements/:id/move` with `{bookshelf: "antilibrary"}`. No API test drives a reading_pile→antilibrary move; the only move-endpoint test targets `wishlist`. `Shelving.abandon_book/2` (→ looking_for_home) is context-only. | ⚠️ | ⚠️ Same move endpoint; sad paths inherited from 1.6.1 (403/422-missing only). | ⚠️ |
| 1.6.3 | ⚠️ Re-read has no endpoint. Current path = two sequential `move` calls (Library→Reading Pile→Library); no test drives the sequence. `reread_book/1` is not wired to a controller. | ⚠️ | n/a — `reread_book/1` unexposed; the "placement not found ⇒ Repo.get! raises" path is a context concern (see L3). |
| 1.6.4 | ✅ bookshelf_placement_controller_test.exs — "returns 204 when user deletes own placement" (`DELETE /api/placements/:id`) | ✅ | ⚠️ bookshelf_placement_controller_test.exs — "returns 403 when user deletes another user's placement" + "returns 404 when placement does not exist" + "returns 401 when not authenticated". BUT already-removed-placement idempotency (Issue §2) is untested. | ⚠️ |
| 1.6.5 | ✅ bookshelf_controller_test.exs — "returns 200 with empty shelves when bookshelf has no books" (count==0, []) + "returns empty shelves list when bookshelf does not exist yet" | ✅ | n/a — empty state is the happy path for a new user (US-1.6.5 §2). |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ bookshelf_placement_controller_test.exs — move uses `auth_conn(user)` (authenticated `:api`→`:authenticated` pipeline) | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 403 when user moves another user's placement" + "returns 401 when not authenticated" | ✅ |
| 1.6.2 | ✅ Same move pipeline as 1.6.1; ownership path also exercised by shelving_test.exs abandon_book "returns :unauthorized when user does not own the placement" | ✅ | ✅ shelving_test.exs — abandon_book "returns :unauthorized when user does not own the placement" (delegates to `move_book/3`) + move 403/401 | ✅ |
| 1.6.3 | ⚠️ Ownership for the move-based reread inherits 1.6.1. But the dedicated `reread_book/1` path has no auth surface. | ⚠️ | ❌ **Code gap:** `Shelving.reread_book/1` takes only `placement_id` — it performs **no ownership verification** (no `user_id` argument, no `bookshelf.user_id` check). Any caller could re-read another user's placement. US-1.6.3 §4 claims ownership is verified; the code does not. No test exists (feature must be fixed before a test can assert it). | ❌ |
| 1.6.4 | ✅ Delete uses `auth_conn(user)` authenticated pipeline | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 403 when user deletes another user's placement" + "returns 401" + shelving_test.exs remove_book "returns :unauthorized when user does not own the placement" | ✅ |
| 1.6.5 | ✅ bookshelf_controller_test.exs — "returns 401 when not authenticated" on the bookshelf read | ✅ | n/a — empty state is a read; auth failure is the browse story's concern, covered above. |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ shelving_test.exs — "moves placement to new bookshelf and writes history" (asserts `moved_placement.bookshelf.name` + `history.from_bookshelf == bookshelf.id`) + "creates history record in PlacementHistory table" | ✅ | ❌ No Ecto.Multi rollback/atomicity test (Issue §5: "if any step fails, entire transaction rolls back / no partial state"). `to_bookshelf` on the history row is also never asserted for a move (only for reread). | ❌ |
| 1.6.2 | ✅ shelving_test.exs — abandon_book "moves placement to looking_for_home bookshelf" (asserts `moved.bookshelf.name == "looking_for_home"`) | ✅ | ❌ No rollback/atomicity test (same Multi as move). | ❌ |
| 1.6.3 | ✅ shelving_test.exs — reread_book "creates a new placement on the library bookshelf" + "new placement is separate from the original" + "writes a PlacementHistory record from the original bookshelf to library" (asserts `from_bookshelf` AND `to_bookshelf`) | ✅ | ⚠️ Missing-placement path (`Repo.get!` raises → would 500) is documented in US-1.6.3 §2 as "should be handled gracefully" but is neither handled nor tested. | ⚠️ |
| 1.6.4 | ✅ shelving_test.exs — remove_book "sets removed_at on the placement" + "placement no longer appears in bookshelf listing after removal" (soft-delete via `is_nil(removed_at)` filter) | ✅ | ❌ No rollback/atomicity test; and the acceptance criterion "book record not deleted (only placement soft-deleted)" (US-1.6.4 §5/§9) is never asserted. | ❌ |
| 1.6.5 | ✅ shelving_test.exs — get_bookshelf_books "returns empty list for bookshelf with no books" + bookshelf_controller "returns empty shelves list when bookshelf does not exist yet" (nil bookshelf ⇒ immediate `count:0`) | ✅ | n/a — no sad DB path for an empty read. |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ⚠️ shelving_test.exs — "emits placement.moved event" asserts the `event_count("placement.moved")` delta ONLY. The payload `%{from_bookshelf, to_bookshelf}` (US-1.6.1 §6) is never asserted, and the `:audit` Multi step (`AuditLog` entry) has **zero** assertions anywhere. | ⚠️ | ❌ No negative-emission test (no `placement.moved` row after a rolled-back Multi) and no event-sequence isolation test (Issue §4: move emits `placement.moved` and *only* that — not `placement.created`/`placement.removed`). | ❌ |
| 1.6.2 | ⚠️ Abandon reuses `move_book/3`; covered by the same count-only emission. Payload `to_bookshelf: "antilibrary"` and audit entry unasserted. | ⚠️ | ❌ Same rollback/isolation gap as 1.6.1. | ❌ |
| 1.6.3 | ⚠️ shelving_test.exs — reread_book "emits placement.reread event" asserts count delta only. Payload `%{book_id, to_bookshelf: "library"}` unasserted; `placement.reread` is **not registered** in `Stacks.Events.Registry` (no handlers subscribe) — untested and by-design-orphaned. | ⚠️ | n/a — reread emission has no failure branch distinct from the L3 Multi rollback (itself untested). |
| 1.6.4 | ⚠️ shelving_test.exs — remove_book "emits placement.removed event" asserts count delta only. Payload `%{book_id}` and the `:audit` entry unasserted. | ⚠️ | ❌ No negative-emission (rollback) / no event-sequence isolation test. | ❌ |
| 1.6.5 | n/a — empty state is a read-only view; emits nothing (US-1.6.5 §6). | n/a | n/a |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ dbt_refresh_job_test.exs — "maps placement.moved to correct models" (`[mart_community_read_count]`) + placement_handler_test.exs — "enqueues jobs for both source and destination bookshelves" (string+atom keys) + "deduplicates when source and destination are the same" | ✅ | n/a — dedup/no-op branches are covered on the happy side; no distinct failure job path. |
| 1.6.2 | ✅ Same `placement.moved` → DbtRefreshHandler + PlacementHandler path as 1.6.1. | ✅ | n/a |
| 1.6.3 | n/a — `placement.reread` is not in the registry, so no handler/Oban job is triggered (by design, per US-1.6.3 §6). | n/a | n/a |
| 1.6.4 | ✅ placement_handler_test.exs — "handles nil bookshelf name gracefully (no job enqueued)" asserts `placement.removed` enqueues no feed job (`extract_bookshelf_name/2` returns nil), and the registry shows `placement.removed` is **not** wired to DbtRefreshHandler — matching US-1.6.4 §7 (no background job). | ✅ | n/a |
| 1.6.5 | n/a — empty read triggers no jobs. | n/a | n/a |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — move/abandon/reread/remove/empty are entirely local (each US §8): no vision, ISBN, scraper, or other external calls. | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — no storage operations in the reading journey (each US §9); book records and cover images are untouched by placement transitions. | n/a — same. |

#### Layer 8: Cache Interactions

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — bookshelf listings are not cached (each US §10); no cache handler subscribes to `placement.*` events in `Stacks.Events.Registry` (handlers are PlacementHandler + DbtRefreshHandler only). Issue §8's "may invalidate BookDetailCache" is speculative and not wired. | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (proto-generated, not_null/unique on id, reading_status accepted_values) + `stg_bookshelf_placement_history` (proto-generated, not_null/unique on id); refresh wiring proven at L5 (placement.moved → mart_community_read_count). | ✅ | ⚠️ `stg_bookshelf_placement_history` has **no** `relationships` tests on `from_bookshelf`/`to_bookshelf` → `stg_bookshelves.id` or `book_id` → `stg_books.id`, and no `accepted_values`/singular tests. schema.yml is proto-generated, so fixes go via the manifest/`mix proto.sync` generator or a singular test. | ⚠️ |
| 1.6.2 | ✅ Same history + placements models as 1.6.1. | ✅ | ⚠️ Same missing-relationships gap. | ⚠️ |
| 1.6.3 | ✅ `stg_bookshelf_placement_history` is the model that feeds `mart_community_read_count` / `spine_data/1` wear counts. | ✅ | ⚠️ Same missing-relationships gap; no test that reread history rows accumulate correctly downstream. | ⚠️ |
| 1.6.4 | ⚠️ `stg_bookshelf_placements.removed_at` column exists but has no dbt test; and `placement.removed` is **not** registered with DbtRefreshHandler, so removals are not reflected until a scheduled/manual refresh (US-1.6.4 §11 flags this as a potential gap). | ⚠️ | ❌ No test that a soft-deleted (removed_at set) placement is excluded from downstream marts. | ❌ |
| 1.6.5 | n/a — empty state has no dbt dependency (US-1.6.5 §11 N/A). | n/a | n/a |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ⚠️ BookDetailProgramTest.elm — "shelf_mover_flow" (Choose Bookshelf → `.shelf-mover` visible → Cancel closes) + "placement_loaded" (shelf actions show correct current bookshelf). BUT the confirm path is untested: no test drives `SelectBookshelf` → `ConfirmMove` → `MoveCompleted (Ok _)` → `currentBookshelf` update / mover closes. `UpdateTest.elm`'s BookDetail describe only covers age-gate + BookLoaded. (TestHelpers.elm wires the `ConfirmMove` SimulatedEffect but no test exercises it.) | ⚠️ | ❌ No `MoveCompleted (Err _)` failure-message test and no no-op-guard tests (`placement == Nothing`, `maybeToken == Nothing` ⇒ `ConfirmMove` no-op) — US-1.6.1 §2/§12. | ❌ |
| 1.6.2 | ⚠️ Same `Page.BookDetail` move path as 1.6.1 (abandon is not a separate Elm code path); no antilibrary-target test. | ⚠️ | ❌ Same missing failure/no-op coverage as 1.6.1. | ❌ |
| 1.6.3 | n/a — no re-read Msg or UI element exists (US-1.6.3 §12: re-reads are two manual moves); nothing distinct to test. | n/a | n/a |
| 1.6.4 | ⚠️ BookDetailProgramTest.elm — "remove_modal_flow" (Remove from collection → "Are you sure you want to remove" text → Keep It closes). BUT the confirm path is untested: no test drives `ConfirmRemove` → `RemoveCompleted (Ok _)` → OutMsg `NavigateTo previousRoute`. | ⚠️ | ❌ No `RemoveCompleted (Err _)` failure-message test and no no-op-guard tests (`placement == Nothing` / no token ⇒ `ConfirmRemove` no-op) — US-1.6.4 §2/§12. | ❌ |
| 1.6.5 | ✅ BookshelfProgramTest.elm — "bookshelf_empty_state: successful response with empty list shows empty bookshelf message" (`.shelf-row--empty` + "Your library is waiting") + BookshelfShelvesTest.elm — "empty_shelves_show_empty_state" + LibraryProgramTest.elm — "empty shelf shows .empty-msg". | ✅ | n/a — empty is the happy path; other-bookshelf wording (AntiLibrary/WishList/ReadingPile/LookingForHome) is config-driven from the single tested branch (see E2E for per-shelf wording, punch #16). |

#### Layer 11: Operational Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — per-route latency and Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint + Oban telemetry. No move/remove-specific SLI is defined in the gate; the per-US metric tables (each US §13) are dashboard/gate concerns, not unit tests. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a — same. |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — covered by SLO gate, not unit tests; in-test SLA bounds (each US §14 targets like move p95 < 500ms) are an anti-pattern under variable CI timing. Journey/engagement funnels are dashboard concerns derived from `event_log` + placement-history marts. | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.5 | n/a — no external API costs: the reading journey is entirely local (each US §15 — Fly/Neon/Oban compute only). There is no per-call spend to record in `BudgetTracker`; compute is covered by the cost dashboard at deploy time. | n/a — same. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Items #5 and #8
are **partially blocked on feature code** — the behaviour they would assert
does not yet exist correctly.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-1.6.1 sad | `PUT /api/placements/:id/move`: 404 for nonexistent placement, 422 for an invalid bookshelf name, "all 5 shelf names accepted as targets", and move-to-same-shelf behaviour (Issue §2) | `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` |
| 2 | L1 US-1.6.2 happy/sad | API test for the abandon transition: `move` with `{bookshelf: "antilibrary"}` from a reading_pile placement returns 200 and lands the book on antilibrary | `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` |
| 3 | L1 US-1.6.3 happy | Decide + cover the re-read path: either a sequence test (Library→Reading Pile→Library via two `move` calls asserting 2 history rows) or expose `reread_book/1` via `POST /api/placements/:id/reread` and test it | `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` (+ router if endpoint added) |
| 4 | L1 US-1.6.4 sad | `DELETE /api/placements/:id` on an already-removed placement — assert idempotency (204 no-op) or a defined error (Issue §2) | `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` |
| 5 | L2 US-1.6.3 sad | **Code gap:** `Shelving.reread_book/1` performs no ownership verification. Add a `user_id` argument (`reread_book/2`) with a `bookshelf.user_id` check returning `{:error, :unauthorized}`, then add the "returns :unauthorized when user does not own the placement" test. **Blocked on the code fix.** | `apps/core/lib/stacks/shelving.ex` + `apps/core/test/stacks/shelving_test.exs` |
| 6 | L3 US-1.6.1 sad | Ecto.Multi rollback/atomicity test for `move_book/3`: force a step failure and assert no partial state (placement unchanged, no history row, no event). Also assert `history.to_bookshelf` on the happy path. | `apps/core/test/stacks/shelving_test.exs` |
| 7 | L3 US-1.6.2 / US-1.6.4 sad | Rollback/atomicity tests for `abandon_book/2` and `remove_book/2` (same pattern as #6); for remove, also assert the `op.books` record survives the soft-delete | `apps/core/test/stacks/shelving_test.exs` |
| 8 | L3 US-1.6.3 sad | **Code + test:** `reread_book/1` calls `Repo.get!` and raises on a missing placement (US-1.6.3 §2 says "should be handled gracefully"). Return `{:error, :not_found}` and test it. **Partially blocked on the code fix.** | `apps/core/lib/stacks/shelving.ex` + `apps/core/test/stacks/shelving_test.exs` |
| 9 | L4 US-1.6.1 happy | Extend "emits placement.moved event" to assert the payload `%{from_bookshelf, to_bookshelf}` AND that the `:audit` Multi step wrote an audit-log entry | `apps/core/test/stacks/shelving_test.exs` |
| 10 | L4 US-1.6.1 / US-1.6.4 sad | Negative-emission + event-isolation tests: no `placement.moved`/`placement.removed` row after a rolled-back Multi; move emits `placement.moved` and *only* that (not created/removed); remove emits `placement.removed` only | `apps/core/test/stacks/shelving_test.exs` |
| 11 | L4 US-1.6.3 happy | Extend "emits placement.reread event" to assert payload `%{book_id, to_bookshelf: "library"}` + audit entry; document/decide the unregistered `placement.reread` (no handlers) — register or leave orphaned intentionally | `apps/core/test/stacks/shelving_test.exs` |
| 12 | L4 US-1.6.4 happy | Extend "emits placement.removed event" to assert payload `%{book_id}` + audit-log entry | `apps/core/test/stacks/shelving_test.exs` |
| 13 | L9 US-1.6.1/2/3 sad | `relationships` tests on `stg_bookshelf_placement_history`: `from_bookshelf`/`to_bookshelf` → `stg_bookshelves.id`, `book_id` → `stg_books.id` — via the proto manifest/`mix proto.sync` generator or a singular test (schema.yml is proto-generated; hand edits are overwritten) | `dbt/tests/singular/` or proto-sync generator |
| 14 | L9 US-1.6.4 happy/sad | dbt coverage for removals: assert a soft-deleted (`removed_at` set) placement is excluded from downstream marts; decide whether `placement.removed` should trigger DbtRefreshHandler (currently unregistered) or stays scheduled-only | `dbt/tests/singular/` + possibly `apps/core/lib/stacks/events/registry.ex` |
| 15 | L10 US-1.6.1/2/4 happy | Elm state-machine tests for the confirm path: `SelectBookshelf` → `ConfirmMove` → `MoveCompleted (Ok _)` updates `currentBookshelf` + closes mover; `ConfirmRemove` → `RemoveCompleted (Ok _)` emits OutMsg `NavigateTo previousRoute` | `frontend/tests/UpdateTest.elm` (BookDetail describe) and/or `frontend/tests/Page/BookDetailProgramTest.elm` |
| 16 | L10 US-1.6.1/2/4 sad | Elm failure/no-op tests: `MoveCompleted (Err _)` + `RemoveCompleted (Err _)` show the error message; `ConfirmMove`/`ConfirmRemove` are no-ops when `placement == Nothing` or `maybeToken == Nothing` | same files as #15 |
| 17 | E2E US-1.6.2 / US-1.6.3 | Playwright: (a) abandon reading_pile→antilibrary via the overlay (Issue §1 "Abandon Book"); (b) full reading journey WishList→AntiLibrary→Reading Pile→Library asserting PlacementHistory; (c) Library→Reading Pile→Library re-read round-trip | `e2e/tests/shelf-actions.spec.ts` |
| 18 | E2E US-1.6.5 | Harden empty-state assertions: the `bookshelf.spec.ts` tests are wrapped in `if (count > 0)` guards, so they pass vacuously when a book is present — seed an empty user so the assertions actually fire; add LookingForHome wording ("Nothing here yet…") which is currently untested | `e2e/tests/bookshelf.spec.ts`, `looking-for-home.spec.ts` |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 5-US matrix (130 cells):

- **22 ✅ STRONG** — concentrated in the Elixir context/controller happy
  paths (move/remove/reread/abandon DB effects, auth guards, empty-state
  API) and the Oban event-fanout (placement.moved → feed + dbt).
- **18 ⚠️ shallow** — the move/remove server core is solid but undermined by
  specific enumerated gaps: event **payloads and audit-log entries are never
  asserted** (only event *counts*), move-endpoint sad paths are partial
  (no 404/invalid-name), dbt history models lack FK/relationships tests, and
  the Elm shelf-mover/remove-modal tests cover open/cancel but never the
  confirm→success/failure transitions.
- **11 ❌ missing** — Ecto.Multi rollback/atomicity (move + abandon + remove),
  negative-event-emission + event isolation, dbt removal reflection, the
  reread ownership check, and all Elm move/remove sad-path/confirm coverage.
- **79 n/a** — external services, storage, cache (no `placement.*` cache
  handler), operational/performance metrics (SLO gate), and cost tracking
  (no external spend) — each carries an inline rationale.

**Headline findings:**
1. **`Shelving.reread_book/1` has no ownership check** (punch #5) — it takes
   only a `placement_id`, so nothing stops a re-read of another user's
   placement. It is not yet exposed via a controller, which contains the
   blast radius, but the function must be fixed before US-1.6.3 §4's stated
   ownership guarantee is true. `reread_book/1` also raises (`Repo.get!`) on
   a missing placement (punch #8).
2. **Events are emission-tested by count only** — `placement.moved`,
   `.removed`, and `.reread` all assert a `+1` delta but never the payload
   shape, and the `:audit` Multi step (which writes an `AuditLog` row for
   every transition) has **zero** assertions anywhere. Rollback
   non-emission and single-event isolation are also untested (punch #9–#12).
3. **No transaction-rollback tests** exist for any of the three `Ecto.Multi`
   operations, despite the acceptance criteria and Issue §5 calling for
   "no partial state on failure" (punch #6–#7).
4. **The Elm reading-journey UI is only half-tested** — the shelf mover and
   remove modal have open/cancel coverage, but the actual move-confirm
   (currentBookshelf update) and remove-confirm (NavigateTo) transitions,
   their error states, and their no-op guards are untested; `UpdateTest.elm`
   has no move/remove cases at all (punch #15–#16).
5. **E2E empty-state assertions pass vacuously** — the `bookshelf.spec.ts`
   wording checks are guarded by `if (count > 0)` and never fire when the
   seeded user has books; abandon and reread journeys have no E2E at all
   (punch #17–#18).

**Test runner totals at baseline (reading-journey-related):** Elixir ~24
tests across `shelving_test.exs` + the two placement/bookshelf controller
tests + placement_handler + dbt_refresh_job; Elm 3 BookDetail program tests
+ 3 empty-state tests (no move/remove unit tests); Playwright ~3 shelf-action
tests + ~5 empty-state tests. Punch list: **18 items**, of which 2 (#5, #8)
are partially blocked on feature-code fixes.
## Definition of Done
- [ ] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] `just verify` passes

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
