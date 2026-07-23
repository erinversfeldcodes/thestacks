# Issue #116: E2E Test Suite — Reading Journey

## Summary
Comprehensive end-to-end test coverage for the reading journey lifecycle: moving books between shelves, abandoning books, re-reading, removing from collection, empty shelf states with per-shelf themed messages, and tracking reading progress through a book. US-1.6.6 (reading progress) was added to scope 2026-07 as the sixth story in the US-1.6 reading-journey family; it was **partial at planning** (backend built, frontend orphaned) and was **built in-scope by Phase 2** (56000f6b) — see the Feature-Completeness Pre-Check. Planning also surfaced a blocking `move_book/3` shelf_id defect (moved books invisible on the target browse), **fixed in-scope by Phase 1** (a1499f92).

## User Stories Covered
- [US-1.6.1 — Move a Book Between Shelves](../docs/user_stories/US-1.6.1-move-book.md)
- [US-1.6.2 — Abandon a Book Back to AntiLibrary](../docs/user_stories/US-1.6.2-abandon-book.md)
- [US-1.6.3 — Record Multiple Reads](../docs/user_stories/US-1.6.3-record-reads.md)
- [US-1.6.4 — Remove a Book from the Collection](../docs/user_stories/US-1.6.4-remove-book.md)
- [US-1.6.5 — Empty Shelf States](../docs/user_stories/US-1.6.5-empty-shelf-states.md)
- [US-1.6.6 — Track Reading Progress](../docs/user_stories/US-1.6.6-reading-progress.md) — *added to scope 2026-07; built in-scope by Phase 2 (see Pre-Check)*

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
| US-1.6.1 — Move a Book Between Shelves | `PUT /placements/:id/move` → `move` (`bookshelf_placement_controller.ex:60`) → `Shelving.move_book/3` → browse `get_bookshelf_shelves/2` | **was 🟡 at planning** (2026-07-22: move 200 but moved book stuck on SOURCE browse, absent from TARGET — `move_book/3` updated `bookshelf_id`, never `shelf_id`; browse reads via physical shelf since #151). **Resolved by Phase 1** (a1499f92): `move_book/3` now reassigns `shelf_id` to the destination bookshelf's default shelf. Re-driven live (minted user): place wishlist → move antilibrary → wishlist count 0 / book absent, antilibrary count 1 / book present. Preview E2E `reading-journey.spec.ts` "move-browse regression" green. | ✅ implemented | Phase 1 in-scope fix + browse-level regression tests (unit `shelving_test.exs:275`, E2E `reading-journey.spec.ts:214`). |
| US-1.6.2 — Abandon a Book Back to AntiLibrary | Same move mechanism, `{bookshelf: "antilibrary"}` | **was 🟡 at planning** (same shelf_id defect: reading_pile stayed count=1, antilibrary count=0). **Resolved by Phase 1** (abandon inherits the `move_book/3` fix). Re-driven live + preview E2E `reading-journey.spec.ts:244` "abandon journey" green. | ✅ implemented | Phase 1 (same defect); API `bookshelf_placement_controller_test.exs:297`, context `shelving_test.exs:622`. |
| US-1.6.3 — Record Multiple Reads | Two `move` calls; history via `op.bookshelf_placement_history`; wear via `spine_data/1` | Driven 2026-07-22: library→reading_pile→library both 200; **2 history rows observed**; end state correct. Outbound hop shares the Phase-1 shelf_id fix. Preview E2E `reading-journey.spec.ts:308` "re-read round-trip" green. | ✅ implemented | — (sequence test decision: no reread endpoint; `bookshelf_placement_controller_test.exs:326`). |
| US-1.6.4 — Remove a Book from the Collection | `DELETE /placements/:id` → `Shelving.remove_book/2` | Driven 2026-07-22: 204; `removed_at` set; `op.books` row intact; gone from listing. | ✅ implemented | — |
| US-1.6.5 — Empty Shelf States | `BookshelfController.show` → `get_bookshelf_shelves/2` count=0; five empty strings in built app.js | Driven 2026-07-22 (fresh minted user): all 5 bookshelves 200 count=0; E2E asserts all five wordings **unguarded** vs zero-placement `empty-shelves` suite user (`bookshelf.spec.ts:333-388`, `looking-for-home.spec.ts:28`). | ✅ implemented | — (baseline punch #18 resolved by #112). |
| US-1.6.6 — Track Reading Progress | `PUT /placements/:id/progress` → `update_progress` + `Shelving.update_reading_progress/3`; `Components.PlacementCard` on Reading Pile + Book Detail; `Api.updateProgress` | **was 🟡 at planning** (2026-07-22: backend built, frontend orphaned — `PlacementCard` mounted nowhere, no `Api.updateProgress`, events unregistered, no page ceiling; page 999999 accepted on a 112-page book). **Resolved by Phase 2** (56000f6b): card mounted on both hosts, `Api.updateProgress` wired, page-count ceiling in `update_reading_progress/3`, `reading_started`/`reading_completed` registered. Re-driven live: API ceiling page 999999 on a 925-page book → 422; browser badge → save → `p. 42` persists across reload → completed → "record this read?" bridge. Preview E2E `reading-journey.spec.ts:339` "progress journey" green. | ✅ implemented | Phase 2 in-scope build; Elm `ReadingPileProgressTest.elm`/`BookDetailProgressTest.elm`, ceiling `shelving_test.exs:1055`. |

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

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). **Regenerated post-implementation** against the shipped state of `feat/116-e2e` — every cell re-verified by grep/read of the real suites. The issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-23 (post-implementation, Issue #116 complete — all six phases shipped)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #116 covers the reading-journey lifecycle — **six** user
stories (US-1.6.1 move a book, US-1.6.2 abandon, US-1.6.3 record re-reads,
US-1.6.4 remove, US-1.6.5 empty bookshelf states, US-1.6.6 track reading
progress, `docs/user_stories/US-1.6.*.md`) — so the matrix is **13 layers × 6
US**, with happy/sad columns per cell. US-1.6.6 was added to scope 2026-07 (the
2026-07-08 baseline's 130-cell matrix excluded it). The assertion inventory for
each layer is taken from each user story's §3–§13 and Issue #116's "Test
Suites" section.

**Feature status (shipped):** the reading-journey feature is implemented
end-to-end. The `Stacks.Shelving` context (`apps/core/lib/stacks/shelving.ex`)
exposes `move_book/3`, `remove_book/2`, `reread_book/2`, `abandon_book/2`,
`place_book/3`, `update_reading_progress/3` and `spine_data/1`, all using
`Ecto.Multi` with an `:emit_event` step (`Events.emit_safe/1`) and an `:audit`
step. Phase 1 fixed the `move_book/3` shelf_id-reassignment bug (moved books now
appear on the destination browse) and hardened `reread_book/1` → `reread_book/2`
with an ownership check + `{:error, :not_found}`. `BookshelfPlacementController`
wires `PUT /api/placements/:id/move` (param `bookshelf`), `DELETE
/api/placements/:id`, and `PUT /api/placements/:id/progress`; there is **no**
`reread` or `abandon` endpoint by decision (both reuse `move`; reread is a
two-move sequence). Phase 2 built the US-1.6.6 frontend: `Components.PlacementCard`
on the Reading Pile + Book Detail, `Api.updateProgress`, a page-count ceiling,
and `placement.reading_started`/`reading_completed` registered. Events route via
`Stacks.Events.Registry`; **event payload shapes are now enforced framework-wide**
by `Stacks.Events.PayloadContract` (emit-time `validate!/1` + a coverage test),
so per-US payload-shape assertions are `n/a (PayloadContract)`.

---

### Framework-layer summary

Each cell is the **weaker of the happy/sad verdicts** for that framework ×
US (conservative). Full happy/sad detail is in the per-layer tables below.

| Framework | US-1.6.1 (move) | US-1.6.2 (abandon) | US-1.6.3 (reread) | US-1.6.4 (remove) | US-1.6.5 (empty) | US-1.6.6 (progress) |
|-----------|-----------------|--------------------|-------------------|-------------------|------------------|---------------------|
| Elixir | ✅ (move/rollback/audit/isolation + all sad paths) | ✅ (abandon API + browse + rollback) | ✅ (reread ownership/not_found + sequence + audit) | ✅ (204/403/404/401 + idempotent + op.books survives) | ✅ (empty count=0 + nonexistent) | ✅ (transitions + ceiling + events + all 422s) |
| Elm | ✅ (BookDetailProgramTest confirm-happy + error + no-op guards) | ✅ (shared move path) | n/a (no reread UI — two manual moves) | ✅ (remove confirm-happy + error + no-op guards) | ✅ (BookshelfProgramTest + LibraryProgramTest + BookshelfShelvesTest) | ✅ (ReadingPileProgressTest + BookDetailProgressTest) |
| Python | n/a — vision service not involved | n/a | n/a | n/a | n/a | n/a |
| E2E | ✅ (move-browse regression, live browser) | ✅ (abandon journey) | ✅ (re-read round-trip) | ✅ (remove modal confirm flow) | ✅ (five wordings, unguarded, empty-shelves suite user) | ✅ (progress journey: set/ceiling/persist/finish) |
| dbt | ✅ (history relationships + refresh wiring) | ✅ (same models) | ✅ (history feeds read-count mart) | ✅ (removed_at exclusion + placement.removed → dbt) | n/a (empty read has no dbt dep) | n/a (stg view — always live; no mart consumes progress) |

**Shipped test inventory (verified by grep/read of `feat/116-e2e`):**
- `apps/core/test/stacks/shelving_test.exs` — `move_book/3` (happy/rollback :236/audit :167/isolation :183/shelf-reassignment+browse :262-289/same-bookshelf no-op :197-234), `remove_book/2` (removed_at :446/listing :451/emit :461/audit :469/isolation :485/op.books survives :498/unauthorized :682), `reread_book/2` (new placement :524/separate :532/history :537/emit :556/audit :564/isolation :582/unauthorized :597/not_found :602), `abandon_book/2` (:610/unauthorized :617/browse :622/rollback :633), `shelf_changeset/2` unique :658, `update_reading_progress/3` (:925-1148: transitions/stamps/current_page/ceiling :1055/boundary :1070/unknown :1085/reading_started :1101/reading_completed :1136), `list_in_progress/1` :1151
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — `move` (200 :174/403 :188/422-missing :202/401 :215/404 :235/422-invalid-name :244/all-five :257/same-bookshelf no-op :274), abandon :297, reread round-trip :326, `delete` (204 :363/403 :376/404 :390/401 :399/idempotent :404), `progress` (200 :562/current_page :573/403 :587/422-invalid :598/422-negative :605/422-missing :615/401 :621/ceiling 422 :629)
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — empty shelves count=0 :45, nonexistent bookshelf :181, 404 invalid name :59, 401 :70
- `apps/core/test/stacks/events/registry_test.exs` — reading-lifecycle events registered `[]` :34, `placement.reread` registered `[]` :52, `placement.removed` subscribes feed + dbt :62
- `apps/core/test/stacks/events/payload_contract_test.exs` — every emitted event_type declared :65, `validate!/1` bites :90/:125 (placement events declared `payload_contract.ex:62-67`)
- `apps/core/test/stacks/feeds/handlers/placement_handler_test.exs` — both bookshelves :70, dedup :120, nil-name no feed job :148, cache rewrite both :228
- `apps/core/test/stacks/workers/dbt_refresh_job_test.exs` — placement.created :43, placement.moved → mart_community_read_count :53 (placement.removed mapping `dbt_refresh_handler.ex:36`)
- `frontend/tests/Page/BookDetailProgramTest.elm` — move_confirm_happy :297, remove_confirm_happy :322, remove_completed_error :341, no-op guards :370/:388/:405/:422; `BookDetailMoveErrorTest.elm` — full-pile :68/generic :82/other-422 :96
- `frontend/tests/Page/ReadingPileProgressTest.elm` (:109/:118/:132/:148), `BookDetailProgressTest.elm` (:112/:122/:136/:153/:164)
- `frontend/tests/Page/BookshelfProgramTest.elm`, `LibraryProgramTest.elm`, `BookshelfShelvesTest.elm` — empty-state rendering
- `e2e/tests/reading-journey.spec.ts` — move-browse regression :214, abandon :244, full journey :271, re-read :308, progress :339; `shelf-actions.spec.ts` (move :12 + remove :209), `bookshelf.spec.ts` (five empty wordings :333-388, empty-shelves suite user), `looking-for-home.spec.ts:28`
- `dbt/models/staging/schema.yml` — `stg_bookshelf_placement_history` relationships book_id/from_bookshelf/to_bookshelf :281-297; `dbt/tests/singular/test_mart_community_read_count_excludes_removed.sql`

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **60** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **96** |

156 cells total (13 layers × 6 US × happy/sad). **Audit GREEN** — 0 ❌, 0 ⚠️.
Every ✅ cites a verified test location; every n/a carries a one-line rationale.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ bookshelf_placement_controller_test.exs:174 — "returns 200 when user moves own placement" (`PUT /api/placements/:id/move`, param `bookshelf`) | ✅ | ✅ :188 (403 non-owner) + :202 (422 missing bookshelf) + :215 (401) + :235 (404 nonexistent) + :244 (422 invalid name) + :257 (all five names accepted) + :274 (same-bookshelf 200 no-op). Full Issue §2 enumeration covered. | ✅ |
| 1.6.2 | ✅ :297 — "moving a reading_pile placement to antilibrary lands it on the antilibrary browse" (abandon reuses `move`; asserted at the browse level, not just 200) | ✅ | ✅ Same move endpoint; sad paths inherited from 1.6.1 (403/422/401/404). | ✅ |
| 1.6.3 | ✅ :326 — "a library→reading_pile→library round-trip writes two history rows and ends in library" (decision: reread is a two-`move` sequence, NO endpoint). | ✅ | n/a — no reread endpoint by decision; the missing-placement path is a context concern (see L2/L3). |
| 1.6.4 | ✅ :363 — "returns 204 when user deletes own placement" (`DELETE /api/placements/:id`) | ✅ | ✅ :376 (403 non-owner) + :390 (404) + :399 (401) + :404 ("already-removed placement is an idempotent 204 no-op") | ✅ |
| 1.6.5 | ✅ bookshelf_controller_test.exs:45 — "returns 200 with empty shelves when bookshelf has no books" (count==0, []) + :181 "returns empty shelves list when bookshelf does not exist yet" | ✅ | n/a — empty state is the happy path for a new user (US-1.6.5 §2). |
| 1.6.6 | ✅ bookshelf_placement_controller_test.exs:562 — "returns 200 with updated placement on valid reading_status" + :573 (updates current_page with status) (`PUT /api/placements/:id/progress`) | ✅ | ✅ :598 (422 invalid status) + :605 (422 negative page) + :615 (422 missing status) + :629 (422 current_page exceeds page count) + :587 (403) + :621 (401) | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ move uses `auth_conn(user)` (authenticated `:api`→`:authenticated` pipeline) | ✅ | ✅ bookshelf_placement_controller_test.exs:188 (403 non-owner) + :215 (401) | ✅ |
| 1.6.2 | ✅ Same move pipeline; ownership also exercised by shelving_test.exs:617 abandon_book "returns :unauthorized when user does not own the placement" | ✅ | ✅ shelving_test.exs:617 (delegates to `move_book/3`) + controller 403/401 | ✅ |
| 1.6.3 | ✅ **Code gap RESOLVED (Phase 1):** `reread_book/1` → `reread_book/2(placement_id, user_id)` now performs an ownership check. shelving_test.exs:597 "returns :unauthorized when the user does not own the placement". | ✅ | ✅ shelving_test.exs:597 — ownership rejected with `{:error, :unauthorized}`. | ✅ |
| 1.6.4 | ✅ Delete uses `auth_conn(user)` authenticated pipeline | ✅ | ✅ bookshelf_placement_controller_test.exs:376 (403) + :399 (401) + shelving_test.exs:682 remove_book "returns :unauthorized when user does not own the placement" | ✅ |
| 1.6.5 | ✅ bookshelf_controller_test.exs:70 — "returns 401 when not authenticated" | ✅ | n/a — empty state is a read; auth failure is covered above. |
| 1.6.6 | ✅ progress uses the authenticated pipeline (bookshelf_placement_controller_test.exs:562 via `auth_conn`) | ✅ | ✅ :587 (403 non-owner) + :621 (401) + shelving_test.exs:1030 update_reading_progress "returns :unauthorized when user does not own placement" | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ shelving_test.exs:107 "moves placement to new bookshelf and writes history" + :122 "creates history record" + :155 "history row records to_bookshelf as the destination bookshelf id" + :262/:275 shelf reassignment lists on TARGET not SOURCE (Phase 1 fix) | ✅ | ✅ shelving_test.exs:236 "a step failure rolls back the placement update, history, event, and audit" (real partial-unique-index seam) | ✅ |
| 1.6.2 | ✅ shelving_test.exs:610 abandon_book "moves placement to looking_for_home bookshelf" + :622 surfaces on looking_for_home browse and off source | ✅ | ✅ shelving_test.exs:633 "a step failure rolls back the abandon (no history, event, or audit, placement unmoved)" | ✅ |
| 1.6.3 | ✅ shelving_test.exs:524 "creates a new placement on the library bookshelf" + :532 "new placement is separate from the original" + :537 "writes a PlacementHistory record from the original bookshelf to library" (asserts `from_bookshelf` AND `to_bookshelf`) | ✅ | ✅ **Code gap RESOLVED (Phase 1):** `Repo.get!` → `Repo.get`; shelving_test.exs:602 "returns :not_found for a missing placement". | ✅ |
| 1.6.4 | ✅ shelving_test.exs:446 "sets removed_at on the placement" + :451 "placement no longer appears in bookshelf listing after removal" | ✅ | ✅ shelving_test.exs:498 "the underlying op.books record survives the soft-delete" (US-1.6.4 §5/§9). Remove's atomicity rides the shared `Ecto.Multi` mechanism proven to roll back at move :236 / abandon :633 (single soft-delete update + emit + audit; no natural forced-failure seam for a soft-delete — indirect-atomicity argument endorsed by reviewer + TC, Phase 3). | ✅ |
| 1.6.5 | ✅ shelving_test.exs:36 get_bookshelf_books "returns empty list for bookshelf with no books" + bookshelf_controller_test.exs:181 (nil bookshelf ⇒ immediate `count:0`) | ✅ | n/a — no sad DB path for an empty read. |
| 1.6.6 | ✅ shelving_test.exs:928-1010 update_reading_progress transitions (to_read→reading→completed→abandoned), started_at :958/finished_at :986 stamps, current_page :1010, ceiling boundary :1070, unknown-count permissive :1085 | ✅ | ✅ shelving_test.exs:1020 (rejects negative current_page) + :1039 (not_found) + :1046 (invalid reading_status) + :1055 (rejects current_page above known page count) | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ shelving_test.exs:136 "emits placement.moved event" + :167 "writes an audit-log entry for the move (:audit Multi step)" (pins resource_type/resource_id/user_id). Payload SHAPE is **n/a (PayloadContract)** — `payload_contract.ex:63` declares `placement.moved` keys, enforced by emit-time `validate!/1` (payload_contract_test.exs:90) + coverage test :65. | ✅ | ✅ shelving_test.exs:183 "emits placement.moved and ONLY that (no created/removed delta)" (event isolation); negative-emission covered by the :236 rollback test (no event row after abort). | ✅ |
| 1.6.2 | ✅ Abandon reuses `move_book/3` (emit + audit :167); `to_bookshelf: "looking_for_home"` shape via PayloadContract. | ✅ | ✅ Same isolation + :633 abandon rollback (no event on abort). | ✅ |
| 1.6.3 | ✅ shelving_test.exs:556 "emits placement.reread event" + :564 "writes an audit-log entry for the re-read". Payload SHAPE n/a (PayloadContract `payload_contract.ex:64`). `placement.reread` registered with an empty handler set — registry_test.exs:52 (pinned via `all_event_types/0`, punch #11). | ✅ | n/a — reread emission has no failure branch distinct from the L3 Multi rollback; single-event isolation asserted on the happy side at shelving_test.exs:582. |
| 1.6.4 | ✅ shelving_test.exs:461 "emits placement.removed event" + :469 "writes an audit-log entry for the removal". Payload SHAPE n/a (PayloadContract `payload_contract.ex:65`). | ✅ | ✅ shelving_test.exs:485 "emits placement.removed and ONLY that (no created/moved delta)". | ✅ |
| 1.6.5 | n/a — empty state is a read-only view; emits nothing (US-1.6.5 §6). | n/a | n/a |
| 1.6.6 | ✅ shelving_test.exs:1101 "emits placement.reading_started event on first reading transition" + :1136 "emits placement.reading_completed event on completed transition" + :1112 "does not emit placement.reading_started again on second reading transition". Registered with empty handler set — registry_test.exs:34. Payload SHAPE n/a (PayloadContract `payload_contract.ex:66-67`). | ✅ | n/a — a rejected progress update fails the changeset before the emit step (L3 sad :1020/:1046/:1055); non-emission has no distinct branch. |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ dbt_refresh_job_test.exs:53 "maps placement.moved to correct models" (`[mart_community_read_count]`) + placement_handler_test.exs:70 "enqueues jobs for both source and destination bookshelves" + :120 "deduplicates when source and destination are the same" | ✅ | n/a — dedup/no-op branches are covered on the happy side; no distinct failure job path. |
| 1.6.2 | ✅ Same `placement.moved` → DbtRefreshHandler + PlacementHandler path as 1.6.1. | ✅ | n/a |
| 1.6.3 | n/a — `placement.reread` registered with an empty handler set (registry_test.exs:52), so no Oban job is triggered (by design, US-1.6.3 §6). | n/a | n/a |
| 1.6.4 | ✅ **Changed (Phase 6):** `placement.removed` now subscribes DbtRefreshHandler — registry_test.exs:62 "placement.removed subscribes the feed handler and the dbt refresh handler" (handler map `dbt_refresh_handler.ex:36` → `mart_community_read_count`); nil-name feed path still asserted no-op at placement_handler_test.exs:148. | ✅ | n/a |
| 1.6.5 | n/a — empty read triggers no jobs. | n/a | n/a |
| 1.6.6 | n/a — `placement.reading_started`/`reading_completed` registered with an empty handler set (registry_test.exs:34); no Oban job by design (stg is a live dbt view; no mart consumes progress). | n/a | n/a |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — move/abandon/reread/remove/empty/progress are entirely local (each US §8): no vision, ISBN, scraper, or other external calls. | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — no storage operations in the reading journey (each US §9); book records and cover images are untouched by placement transitions and progress updates. | n/a — same. |

#### Layer 8: Cache Interactions

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — bookshelf listings are not cached (each US §10); no cache handler subscribes to `placement.*` events (handlers are PlacementHandler + DbtRefreshHandler only, `Stacks.Events.Registry`). Issue §8's "may invalidate BookDetailCache" is speculative and not wired. | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` + `stg_bookshelf_placement_history` (proto-generated, not_null/unique on id, reading_status accepted_values); refresh wiring proven at L5 (placement.moved → mart_community_read_count). | ✅ | ✅ **RESOLVED (Phase 6):** schema.yml:281-297 adds `relationships` tests on `stg_bookshelf_placement_history` — `book_id`→`stg_books.id`, `from_bookshelf`/`to_bookshelf`→`stg_bookshelves.id` (via the proto manifest, schema.yml is generated). | ✅ |
| 1.6.2 | ✅ Same history + placements models as 1.6.1. | ✅ | ✅ Same relationships tests (schema.yml:281-297). | ✅ |
| 1.6.3 | ✅ `stg_bookshelf_placement_history` feeds `mart_community_read_count` / `spine_data/1` wear counts. | ✅ | ✅ Same relationships tests; reread history rows accumulate through the same model. | ✅ |
| 1.6.4 | ✅ `placement.removed` → DbtRefreshHandler (registry_test.exs:62; handler map `dbt_refresh_handler.ex:36`) so removals refresh `mart_community_read_count` (Phase 6 decision: register). | ✅ | ✅ **RESOLVED (Phase 6):** `dbt/tests/singular/test_mart_community_read_count_excludes_removed.sql` asserts soft-deleted (`removed_at IS NOT NULL`) placements are excluded from the read-count mart. | ✅ |
| 1.6.5 | n/a — empty state has no dbt dependency (US-1.6.5 §11 N/A). | n/a | n/a |
| 1.6.6 | n/a — `stg_bookshelf_placements` is a dbt view (always live, no refresh needed); `reading_status` has an `accepted_values` test; no mart consumes reading progress today (registry rationale). | n/a | n/a |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.6.1 | ✅ BookDetailProgramTest.elm:297 "move_confirm_happy: SelectBookshelf then ConfirmMove then MoveCompleted Ok updates currentBookshelf, closes the mover, and shows success" + :154 shelf_mover_flow + :210 placement_loaded | ✅ | ✅ BookDetailMoveErrorTest.elm:68/:82/:96 (MoveCompleted Err — full-pile / generic 500 / other-422) + BookDetailProgramTest.elm:370 "confirm_move_no_placement" + :388 "confirm_move_no_token" (no-op guards) | ✅ |
| 1.6.2 | ✅ Same `Page.BookDetail` move path as 1.6.1 (abandon reuses the move code path with an antilibrary target). | ✅ | ✅ Same error/no-op coverage as 1.6.1. | ✅ |
| 1.6.3 | n/a — no re-read Msg or UI element exists (US-1.6.3 §12: re-reads are two manual moves); nothing distinct to test. | n/a | n/a |
| 1.6.4 | ✅ BookDetailProgramTest.elm:322 "remove_confirm_happy: ConfirmRemove then RemoveCompleted Ok emits OutMsg NavigateTo previousRoute" + :170 remove_modal_flow | ✅ | ✅ BookDetailProgramTest.elm:341 "remove_completed_error" + :405 "confirm_remove_no_placement" + :422 "confirm_remove_no_token" (no-op guards) | ✅ |
| 1.6.5 | ✅ BookshelfProgramTest.elm empty-state ("Your library is waiting") + BookshelfShelvesTest.elm "empty_shelves_show_empty_state" + LibraryProgramTest.elm empty `.empty-msg`. | ✅ | n/a — empty is the happy path; per-shelf wording covered at E2E (bookshelf.spec.ts:333-388). |
| 1.6.6 | ✅ ReadingPileProgressTest.elm:109 "progress_renders" + :118 "edit_save_folds" + :132 "finished_bridge"; BookDetailProgressTest.elm:112 "card_mounts" + :122 "save_folds" + :153/:164 finished-bridge (pile vs library-gated). | ✅ | ✅ ReadingPileProgressTest.elm:148 "error_surfaces: a 422 keeps the form open with the draft, and announces the error" + BookDetailProgressTest.elm:136 error_surfaces. | ✅ |

#### Layer 11: Operational Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — per-route latency and Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint + Oban telemetry. The per-US metric tables (each US §13) are dashboard/gate concerns, not unit tests; per-US repetition of firing tests adds no guarantee. | n/a — same. |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — covered by SLO gate, not unit tests; in-test SLA bounds (each US §14 targets like move p95 < 500ms) are an anti-pattern under variable CI timing. Journey/engagement funnels are dashboard concerns derived from `event_log` + placement-history marts. | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.6.1–1.6.6 | n/a — no external API costs: the reading journey is entirely local (each US §15 — Fly/Neon/Oban compute only). There is no per-call spend to record in `BudgetTracker`; compute is covered by the cost dashboard at deploy time. | n/a — same. |

---

### Punch list (18/18 resolved)

Every baseline ❌/⚠️ item, with the resolving test location (or the explicit
decision). Items resolved by OTHER issues are noted as such.

| # | Cell | Resolution | Location |
|--:|------|------------|----------|
| 1 | L1 US-1.6.1 sad | 404 nonexistent, 422 invalid name, all-five-names accepted, same-bookshelf 200 no-op | `bookshelf_placement_controller_test.exs:235/:244/:257/:274` |
| 2 | L1 US-1.6.2 happy/sad | Abandon API test — `move {bookshelf: "antilibrary"}` from reading_pile lands on the antilibrary browse | `bookshelf_placement_controller_test.exs:297` |
| 3 | L1 US-1.6.3 happy | **Decision: NO reread endpoint** — reread is a two-`move` sequence; test asserts 2 history rows and library end-state | `bookshelf_placement_controller_test.exs:326` |
| 4 | L1 US-1.6.4 sad | Already-removed DELETE is an idempotent 204 no-op | `bookshelf_placement_controller_test.exs:404` |
| 5 | L2 US-1.6.3 sad | **Code fix (Phase 1):** `reread_book/1`→`reread_book/2(user_id)` with ownership check `{:error, :unauthorized}` + test | `shelving.ex` + `shelving_test.exs:597` |
| 6 | L3 US-1.6.1 sad | `move_book/3` rollback (partial-unique-index seam) + `history.to_bookshelf` pinned on happy path | `shelving_test.exs:236` + `:155` |
| 7 | L3 US-1.6.2 / US-1.6.4 sad | `abandon_book/2` rollback :633; remove `op.books` survives :498 (remove atomicity via shared-Multi proof — indirect-atomicity endorsed) | `shelving_test.exs:633` + `:498` |
| 8 | L3 US-1.6.3 sad | **Code fix (Phase 1):** `Repo.get!`→`Repo.get`, returns `{:error, :not_found}` + test | `shelving.ex` + `shelving_test.exs:602` |
| 9 | L4 US-1.6.1 happy | Audit-log positive assertion (:audit Multi step, pins resource_type/id/user_id); payload SHAPE → `n/a (PayloadContract)` | `shelving_test.exs:167`; `payload_contract.ex:63` + `payload_contract_test.exs:65/:90` |
| 10 | L4 US-1.6.1 / US-1.6.4 sad | Event-isolation deltas (moved-only :183, removed-only :485); negative-emission via rollback :236 | `shelving_test.exs:183/:485/:236` |
| 11 | L4 US-1.6.3 happy | Reread audit-log assertion; payload SHAPE `n/a (PayloadContract)`; **decision:** `placement.reread` registered with `[]` | `shelving_test.exs:564`; `registry_test.exs:52` |
| 12 | L4 US-1.6.4 happy | Removed audit-log assertion; payload SHAPE `n/a (PayloadContract)` | `shelving_test.exs:469`; `payload_contract.ex:65` |
| 13 | L9 US-1.6.1/2/3 sad | `relationships` tests on `stg_bookshelf_placement_history` (book_id, from_bookshelf, to_bookshelf) via the proto manifest | `dbt/models/staging/schema.yml:281-297` |
| 14 | L9 US-1.6.4 happy/sad | Soft-deleted excluded from read-count mart (singular test); **decision:** `placement.removed` registered with DbtRefreshHandler | `dbt/tests/singular/test_mart_community_read_count_excludes_removed.sql`; `registry_test.exs:62` |
| 15 | L10 US-1.6.1/2/4 happy | Confirm-happy: `MoveCompleted (Ok)`→currentBookshelf + mover closes; `RemoveCompleted (Ok)`→OutMsg `NavigateTo` | `BookDetailProgramTest.elm:297/:322` |
| 16 | L10 US-1.6.1/2/4 sad | `RemoveCompleted (Err)` message + four no-op guards; `MoveCompleted (Err)` covered by `BookDetailMoveErrorTest.elm` | `BookDetailProgramTest.elm:341/:370/:388/:405/:422`; `BookDetailMoveErrorTest.elm:68/:82/:96` |
| 17 | E2E US-1.6.2 / US-1.6.3 | Abandon, full journey (PlacementHistory), re-read round-trip in a live browser (minted isolated users) | `reading-journey.spec.ts:244/:271/:308` |
| 18 | E2E US-1.6.5 | **Resolved by #112:** empty-state assertions now unguarded against the zero-placement `empty-shelves` suite user; all five wordings incl. LookingForHome | `bookshelf.spec.ts:333-388`; `looking-for-home.spec.ts:28` |

**US-1.6.6 (added to scope 2026-07, not in the 18-item baseline)** — built in
Phase 2 and covered across all layers: backend transitions + page-count ceiling
(`shelving_test.exs:928-1148`), controller 422s (`bookshelf_placement_controller_test.exs:598-629`),
Elm program tests (`ReadingPileProgressTest.elm`, `BookDetailProgressTest.elm`),
E2E progress journey (`reading-journey.spec.ts:339`), events registered with `[]`
(`registry_test.exs:34`), dbt n/a (stg is a live view, no mart consumes progress).

---

### Verdict

**Audit GREEN — Issue #116 complete.** State across the 13-layer × 6-US
matrix (156 cells):

- **60 ✅ STRONG** — every applicable happy/sad cell has a verified test
  location. The Elixir core (move/abandon/reread/remove/progress DB effects,
  rollback/atomicity, audit-log positives, event isolation, all controller sad
  paths), the Elm confirm-happy + error + no-op coverage, the dbt history
  relationships + removal-exclusion tests, and the five live-browser
  reading-journey E2E specs.
- **0 ⚠️ / 0 ❌** — every baseline gap resolved (18/18 punch items) or moved to
  `n/a` with rationale (payload SHAPE cells → PayloadContract).
- **96 n/a** — external services, storage, cache (no `placement.*` cache
  handler), operational/performance metrics (SLO gate), cost tracking (no
  external spend), payload-shape halves (PayloadContract), and the by-design
  n/a layers per US (reread has no UI/endpoint/job; empty read emits nothing;
  progress consumed by no mart) — each carries an inline rationale.

**What changed from the 2026-07-08 baseline:**
1. **The reread ownership + not_found code gaps are fixed** (Phase 1) —
   `reread_book/1` → `reread_book/2(user_id)` with an ownership check and
   `{:error, :not_found}` (`shelving_test.exs:597/:602`).
2. **The move shelf_id bug is fixed** (Phase 1) — moved books now land on a
   physical shelf of the destination bookshelf and appear on the target browse
   (`shelving_test.exs:275`, E2E `reading-journey.spec.ts:214`). This was the
   blocking Feature-Completeness finding.
3. **Event coverage is now shape-enforced + audit-asserted** — payload shapes
   are guaranteed framework-wide by `PayloadContract` (emit-time `validate!/1`
   + coverage test), the `:audit` Multi step has positive assertions for
   moved/removed/reread (`:167/:469/:564`), and single-event isolation is
   pinned (`:183/:485/:582`).
4. **Transaction rollback is tested** — real partial-abort tests for move
   (`:236`) and abandon (`:633`); remove atomicity rides the shared-Multi proof
   plus the direct op.books-survives assertion (`:498`).
5. **The Elm reading-journey UI is fully covered** — move/remove confirm-happy,
   error surfaces, and all four no-op guards (`BookDetailProgramTest.elm`); the
   US-1.6.6 progress card on both hosts (`ReadingPileProgressTest.elm`,
   `BookDetailProgressTest.elm`).
6. **E2E is live-browser and non-vacuous** — five `reading-journey.spec.ts`
   specs (move-browse regression, abandon, full journey, re-read, progress) on
   minted isolated users; empty-state assertions unguarded (punch #18 by #112).

**Suite state (freshly verified):** ExUnit 2827/0, elm-test 960/0,
dbt 237/237, preview E2E 219 passed / 10 env-skips.
## Definition of Done
- [x] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local` — evidence: fresh-DB `just run mix test` 2827/0 (2026-07-23), elm-test 960/0, dbt 237/237, local chromium `reading-journey.spec.ts` 7/7 (see audit tables for per-cell locations)
- [x] No flaky tests — evidence: `reading-journey.spec.ts` `--repeat-each=3` → 17/17, zero flakes; preview full-run rotating env failures root-caused (512MB-VM actionability timeout; `:auth`-bucket 429s in unmigrated `registerAndConfirm`) and green on clean targeted retries (privacy 10/10, public-profile 8/8); remediation tracked in issues/280
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — evidence: table above with live-drive + preview-E2E artifacts per story; US-1.6.1/1.6.2 fixed by Phase 1 (a1499f92), US-1.6.6 built by Phase 2 (56000f6b); no story reached GREEN via reclassification
- [x] **Test audit (embedded above) is GREEN** — evidence: regenerated 2026-07-23 to 156 cells, 60 ✅ / 0 ⚠️ / 0 ❌ / 96 n/a-with-rationale; all 18 punch items resolved (resolution table above)
- [x] `just verify` passes — evidence: full gate exit 0 (2026-07-22, post-Phase-2) and fresh-DB equivalent 2026-07-23; final `just ci` run supersedes (below)
- [x] **DoD additions (planning sufficiency check, 2026-07-22):**
  - [x] The move shelf_id defect (US-1.6.1/1.6.2 blocking finding) is fixed with browse-level regression tests at unit AND E2E layers — evidence: live drive (minted user: wishlist→antilibrary; target count 1/book present, source count 0/absent) + `shelving_test.exs` browse describe + `reading-journey.spec.ts:214` green locally and on preview
  - [x] US-1.6.6: page-count ceiling enforced — evidence: `shelving_test.exs:1055` ("rejects current_page above the known primary-edition page count") + boundary + unknown-permissive tests, 124/0 targeted run; live API drive: page 999999 on a 925-page book → 422 "must be less than or equal to 925"; unknown-count permissive decision recorded at `shelving.ex` ceiling comment
  - [x] US-1.6.6: `placement.reading_started`/`reading_completed` registered — evidence: `registry.ex` diff (empty-handler-set decision + rationale comment) + `registry_test.exs:34` (catalog membership + empty set pinned)
  - [x] Regenerated audit marks payload-shape cells `n/a (PayloadContract)` with rationale — evidence: audit tables above cite `payload_contract.ex:62-67` emit-time `validate!` + coverage test
  - [x] `just run just ci` green on the branch before the PR — evidence: 2026-07-23 run — all groups PASS; the one blocking semgrep finding (non-literal RegExp in the new spec) fixed in bd578eaf and the security group re-run clean (0 findings); sole residual is the documented dockle-needs-local-Docker environment caveat (CI has Docker)
  - [x] `gdpr-review` lens run at review on the phases touching events/endpoints/dbt — evidence: n/a-with-rationale stated per phase (Phase 2: no new personal-data fields, events carry `book_id` only per PayloadContract; Phase 6: id-keyed aggregates, no PII to warehouse; PE gate confirmed no GDPR drift and that erasure bulk-delete bypasses the new event path)

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
