# Issue #114: E2E Test Suite — Book Detail Overlay

## Summary
Comprehensive end-to-end test coverage for the book detail overlay, including opening/closing behaviour, focus trapping, all detail sections (hero, about, reviews, prices, author, writing, shelf actions), move/remove actions, age gate enforcement, and visibility filtering.

## User Stories Covered
- [US-1.4.1 — Open a Book's Detail Overlay](../docs/user_stories/US-1.4.1-book-detail-overlay.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (BookController, BookshelfPlacementController).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No — two small in-scope builds approved at epic kickoff 2026-07-23: (a) Elm focus trap + focus-return for the overlay (the US-1.4.1 a11y contract; no ports), (b) `BookDetailCache` hit/miss telemetry (~10 lines + firing test). Everything else is test files only.
- Does this issue combine unrelated concerns? No (all book detail overlay).

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
| US-1.4.1 — Open a Book's Detail Overlay | Spine click → `Main.openOverlay` (`frontend/src/Main.elm:2365`; records `triggerSpineId = "spine-<id>"` at `:2377`) → `GET /api/books/:id` via `:optional_auth` → `StacksWeb.BookController.show/2` (`apps/core/lib/stacks_web/controllers/book_controller.ex:185`, `cached_or_fetch/1` at `:197`) → `BookDetail.overlayView` (`frontend/src/Main.elm:2856`) renders hero/about/reviews/prices/author/writing/shelf-actions. Dismissal (X/backdrop/Escape) → `RequestCloseOverlay` OutMsg → overlay closed at `Main.elm:2093` (button/backdrop) and `:2180` (Escape). Focus contract: focus-on-open lands on `book-overlay-close`, sentinel-anchored Tab trap (`frontend/src/Page/BookDetail.elm:1421` `preventDefaultOn "keydown"` + trailing sentinel `:1467`), focus-return to the triggering spine (`Main.elm:2085`). | Live keyboard-walk 2026-07-24 (Progress Notes): overlay opens over the blurred shelf with the URL unchanged; Tab cycles close→content→sentinel→close and never escapes to the shelf behind; Escape is scoped (remove-modal/progress-form first, then the overlay); focus returns to the triggering spine on close. Driven by the `--project=chromium` E2E suite (`book-detail.spec.ts` + `shelf-actions.spec.ts`, 29 passing) and the 36 `BookDetailProgramTest` cases. | ✅ | Built end-to-end. Two kickoff-approved (2026-07-23) in-scope builds landed: (a) the Elm overlay focus trap + focus-return (the US-1.4.1 a11y contract, no ports), (b) `BookDetailCache` hit/miss telemetry. Revision 1 (ux P2 a11y) added scoped Escape, remove-modal dialog semantics + two-element focus trap + focus-on-"Keep It" + focus-return, and the sentinel aria-label. 3/3 reviews (elm, elixir, ux) APPROVED; residual P3s tracked in #295. |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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
- ~~Click Verify; verify navigation to age verification settings~~ — n/a (ADR-020 §2, #069): the Verify affordance was removed by design; `Components.AgeGate.ageGate` has only "Go Back". Provider flow tracked in #069.
- Click Go Back / Dismiss; verify age gate dismissed but book detail not shown

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

## Test Audit

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). Regenerated to the shipped state after implementation — every cell re-verified by grep/Read against the merged suites (commits `454dfd8b` + `56a21f58` + `045a7168` and the intervening baseline-closing merges). The issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-24 (post-implementation — Issue #114, shipped state)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #114 covers a single user story — US-1.4.1 (Open a
Book's Detail Overlay, `docs/user_stories/US-1.4.1-book-detail-overlay.md`)
— so the matrix is 13 layers × 1 US, with happy/sad columns per cell (26
cells). The assertion inventory for each layer is taken from Issue #114's
per-section Test Suites (§1–§11) and the US-1.4.1 spec (§3–§15).

**Feature status:** the book detail overlay IS fully implemented — this is
not a greenfield audit. Existing surface:
- `StacksWeb.BookController.show/2` serving `GET /api/books/:id` via the
  `:optional_auth` pipeline (`apps/core/lib/stacks_web/controllers/book_controller.ex`).
- `StacksWeb.BookshelfPlacementController` — `move/2`, `delete/2`,
  `update_formats/2`, `create/2` (move/remove/formats/add-to-collection).
- `Stacks.Books.BookDetailCache` (ETS, 5-min TTL) +
  `Stacks.Books.Handlers.CacheInvalidationHandler`.
- `Stacks.Shelving.move_book/3` / `remove_book/2` with `Ecto.Multi`,
  `PlacementHistory`, and `placement.moved` / `placement.removed` events.
- Elm `Page.BookDetail` rendered as an **overlay** (not a routed page as of
  2026-03-17; `Route.BookDetail bookId` coexists for deep links per ADR-005),
  exposing `Msg(..)`, `overlayView`, and the `RequestCloseOverlay` OutMsg.
- dbt `stg_bookshelf_placements`, `stg_bookshelf_placement_history`
  (proto-generated) + `wh.mart_community_read_count`.
- Playwright suites `book-detail.spec.ts`, `book-interaction.spec.ts`,
  `shelf-actions.spec.ts`, `editions.spec.ts`, `age-gate.spec.ts`
  (E2E slug `book-detail` in `e2e/tests/helpers.ts`).

The audit therefore baselines real coverage rather than marking blanket
"feature not implemented".

---

### Framework-layer summary

| Layer       | US-1.4.1 |
|-------------|----------|
| Elixir      | ✅ (controller + context + cache fully covered: hidden-book-not-served/403-no-leak, moved/removed event payloads, audit-log on move/remove, no-events-on-read, Multi rollback, controller↔cache integration via telemetry) |
| Elm unit    | ✅ (`BookDecoder.elm` — 12 tests covering Book/edition/author/visibility-tier decoding; page state lives in program tests) |
| Elm program | ✅ (`BookDetailProgramTest` 36 + `BookDetailAvailabilityTest` 4: view rendering + move/remove **success & failure** transitions + `CloseOverlay`→`RequestCloseOverlay` OutMsg + focus trap + scoped Escape + remove-modal dialog semantics/trap) |
| Python      | n/a — vision service not involved in the read-only detail overlay |
| E2E         | ✅ (open-overlay, all-sections, format toggle, move-success, remove-flow, add-to-collection + close (X/backdrop/Escape) with URL-unchanged, focus contract, move/remove failure, error/loading states, unauth prompt; 29 passing across `book-detail.spec.ts` + `shelf-actions.spec.ts` on `--project=chromium`) |
| dbt         | ✅ (staging models + `placement.moved`/`placement.removed`→`mart_community_read_count` refresh tested; `relationships` FK tests present in `schema.yml`) |

**Shipped test inventory (verified by grep/read 2026-07-24):**
- `apps/core/test/stacks_web/book_controller_test.exs` — `GET /api/books/:id` (200 with full JSON, placement, my_writing, editions, primary_edition, community_read_count; 404; 403 age-gated; 200 age-verified; optional-auth null placement; visibility gates; my_writing variants) **plus** the shipped additions: `describe "hidden book is not served"` (`:629` — age-gated book refused for authed + unauthed viewer, payload/title not leaked, `:630`/`:650`), `describe "no events on read"` (`:663` — successful + unauthenticated read each assert `event_log` count unchanged, `:664`/`:679`), `describe "cache miss then hit"` (`:700` — first GET fires `[:stacks, :book_detail_cache, :miss]` then second fires `:hit` with no second miss, via telemetry, `:721`).
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — move (200/403/422/401), delete (204/403/404/401), formats (200/403/422/401), create (201/422/401), mine, visibility, progress.
- `apps/core/test/stacks/shelving_test.exs` — `move_book/3` history + audit-log (`:167`), atomicity/rollback (`describe :235` — a step failure rolls back placement update + history + event + audit, `:236`); `remove_book/2` removed_at + audit-log (`:473`) + rollback (`:637`); `describe "move_book/3 — placement.moved payload"` (`:1390` — asserts aggregate_id == placement.id, `from_bookshelf`/`to_bookshelf` **names**), `describe "remove_book/2 — placement.removed payload"` (`:1408` — asserts `book_id`); unauthorized paths; `place_book/3` payload.
- `apps/core/test/stacks/books_test.exs` — `get_book_detail/1` (loads with preloads; nil for nonexistent), `primary_edition/1`.
- `apps/core/test/stacks/books/book_detail_cache_test.exs` — get miss/put+get hit/invalidate/invalidate_all/TTL expiry (5 tests).
- `apps/core/test/stacks/book_detail_cache_telemetry_test.exs` — **shipped**: `describe "get/1 telemetry"` (5 tests) — `:miss` on cold lookup, `:hit` after put, `:miss` on expired-as-miss, cold-then-warm miss→hit ordering, and a GDPR test pinning `Map.keys(metadata) == [:book_id]` for both events (`:46`–`:112`).
- `apps/core/test/stacks/books/handlers/cache_invalidation_handler_test.exs` — invalidation on `book.created`, `book.cover_confirmed`, `blog.associations_suggested`; ignores unrelated.
- `apps/core/test/stacks/feeds/handlers/placement_handler_test.exs` — `placement.created`/`.moved`/`.removed` → `RegenerateFeedJob` enqueue (`:147` removed describe).
- `apps/core/test/stacks/upload_dbt_test.exs` — `placement.moved` (`:206`) **and** `placement.removed` (`:220` — "placement.removed enqueues community read count refresh") → `mart_community_read_count` refresh.
- `apps/core/test/stacks/visibility_test.exs` — `resolve_visibility/2` incl. age-gate → `:hidden`/`:visible`.
- `frontend/tests/Page/BookDetailProgramTest.elm` (36) + `frontend/tests/Page/BookDetailAvailabilityTest.elm` (4) + `frontend/tests/BookDecoder.elm` (12).
- `e2e/tests/book-detail.spec.ts` (22), `e2e/tests/shelf-actions.spec.ts` (7), `book-interaction.spec.ts`, `editions.spec.ts`, `age-gate.spec.ts`.
- `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (`accepted_values` on `reading_status`; `relationships` on `book_id`→`stg_books`, `bookshelf_id`→`stg_bookshelves`, `:215`+) and `stg_bookshelf_placement_history` (`relationships` on `book_id`→`stg_books`, `from_bookshelf`/`to_bookshelf`→`stg_bookshelves`, `:272`+).

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **15** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **11** |

26 cells total (13 layers × happy/sad). Shipped state: **0 ❌ / 0 ⚠️** — every
applicable cell is `✅`, every non-applicable cell is `n/a`-with-rationale. All
16 punch-list items are dispositioned below.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ book_controller_test.exs — "returns 200 with book JSON when book exists" (asserts id, title, visibility_tier, primary_edition.isbn, editions list, edition_count, community_read_count), "returns placement data when user has an active placement", "returns 200 for age_gated book when user is age_verified"; move/remove/formats happy: bookshelf_placement_controller_test.exs — "returns 200 when user moves own placement", "returns 204 when user deletes own placement", "returns 200 with updated formats", "returns 201 with placement on valid bookshelf and book_id". | ✅ | ✅ book_controller_test.exs — "returns 404 for a missing book" (`:184`), "returns 403 for age_gated book when user is not age_verified" (`:126`/`:535`); bookshelf_placement_controller_test.exs — move "returns 422 when bookshelf parameter is missing"/"403 non-owner", delete "404 nonexistent"/"403 non-owner", formats "422 missing"/"422 not-array"/"403 non-owner". **Hidden-book path:** `describe "GET /api/books/:id — hidden book is not served"` (`:629`) proves the *reachable* hidden outcome — an age-gated book (a book's only server-side hidden state) is refused with 403 for both authed (`:630`) and unauthenticated (`:650`) viewers, and the refusal leaks no `book` payload (`refute Map.has_key?(body, "book")`, `refute resp_body =~ title`). The literal `resolve_visibility == :hidden -> 404` branch (`book_controller.ex:211`) is **n/a — defensively unreachable for books**: `AgeGate.enforce` (`:192`) intercepts with 403 first, and books have no owner/block and always resolve `visibility_tier` to public/age_gated (Phase 2 flag, Progress Notes 2026-07-24). | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ book_controller_test.exs — optional-auth works unauthenticated ("returns 200 with null placement when not authenticated", "public book returns 200 for unauthenticated viewer") and enriches when authenticated ("returns placement data ...", my_writing describe); ownership guards: bookshelf_placement_controller_test.exs — move/delete/formats "403 non-owner"; shelving_test.exs — "returns :unauthorized when user does not own the placement" (remove + abandon). | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 401 when not authenticated" present for **all** mutation endpoints (move, delete, formats, create); age gate: book_controller_test.exs — "returns 403 for age_gated book when user is not age_verified" + "age_gated book returns 403 for unauthenticated viewer". | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ books_test.exs — `get_book_detail/1` "returns book with preloads" + `primary_edition/1`; shelving_test.exs — move "moves placement to new bookshelf and writes history" (asserts `bookshelf.name` change + `history.from_bookshelf`), "creates history record in PlacementHistory table", remove "sets removed_at on the placement"; formats update via controller test; placement lookup via book_controller_test.exs "returns placement data ...". | ✅ | ✅ books_test.exs — `get_book_detail/1` "returns nil for nonexistent book"; shelving_test.exs — move/remove unauthorized. **Ecto.Multi atomicity now covered:** `describe "move_book/3 — atomicity / rollback"` (`:235`) — "a step failure rolls back the placement update, history, event, and audit" (`:236`); the abandon path has a matching rollback test ("a step failure rolls back the abandon (no history, event, or audit, placement unmoved)", `:637`); rejected place/move each assert no placement/history/event/audit row (`:332`/`:347`). | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ **Payloads now asserted:** shelving_test.exs `describe "move_book/3 — placement.moved payload"` (`:1390`) — "payload carries the source and destination bookshelf names" asserts `aggregate_id == placement.id`, `payload["from_bookshelf"] == "library"`, `payload["to_bookshelf"] == "wishlist"`; `describe "remove_book/2 — placement.removed payload"` (`:1408`) — "payload carries the removed placement's book_id" asserts `payload["book_id"] == book.id`. These match the real emits (`shelving.ex:328`-`:332` moved, `:458`-`:462` removed). Handlers: placement_handler_test.exs — `placement.moved`/`.removed` describes (`:69`/`:147`); upload_dbt_test.exs — moved+removed refresh. | ✅ | ✅ **No-events-on-read:** book_controller_test.exs `describe "GET /api/books/:id — no events on read"` (`:663`) — "a successful read emits no event_log rows" (`:664`) and "an unauthenticated read emits no event_log rows" (`:679`) both assert `total_event_count()` unchanged before/after. **Audit-log:** shelving_test.exs "writes an audit-log entry for the move (:audit Multi step)" (`:167`) and "writes an audit-log entry for the removal (:audit Multi step)" (`:473`). | ✅ |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — Issue §5 marks this N/A: the read-only overlay triggers no Oban job; move/remove are synchronous API calls. The event-driven jobs they enqueue (`RegenerateFeedJob`, `DbtRefreshJob`) are covered under Layer 4 (placement_handler_test) and Layer 9 (upload_dbt_test). | n/a — same. |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — Issue §6 / US §8: the detail view reads locally-stored data only. Reviews, prices, and author enrichment are populated by background jobs, not fetched during overlay display. | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — Issue §7 / US §9: cover images are pre-stored URLs (`edition.cover_image_url`); no runtime storage operation on overlay display. | n/a — same. |

#### Layer 8: Cache Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ book_detail_cache_test.exs — the cache **mechanism** is well tested: "returns {:miss, book_id} for uncached entries", "returns cached data" (put+get hit), TTL expiry ("expired entries return :miss"). **Controller↔cache integration now covered:** book_controller_test.exs `describe "GET /api/books/:id — cache miss then hit"` (`:700`) — "first GET misses and caches; second GET hits" (`:721`) attaches `[:stacks, :book_detail_cache, :miss|:hit]` and asserts the first request fires `:miss` (populating the cache) and the second fires `:hit`, with `refute_receive` proving no second miss (the warm read is served from cache, not re-fetched). The cache is wired into the controller at `book_controller.ex:198` (`cached_or_fetch/1`) → `:241` (`put`). | ✅ | ✅ cache_invalidation_handler_test.exs — invalidation on `book.created`, `book.cover_confirmed`, `blog.associations_suggested`, and "ignores unrelated events"; book_detail_cache_test.exs — `invalidate/1`, `invalidate_all/0`, TTL expiry. **Note (by design, not a gap):** `CacheInvalidationHandler` does **not** invalidate on `placement.moved`/`.removed` — correct, since `BookDetailCache` holds book metadata while placement is per-user and fetched separately; Issue §8's "invalidated after move/remove" assumption does not apply to this cache. | ✅ |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (proto-generated; `not_null`+`unique` on id, `accepted_values` on `reading_status`) and `stg_bookshelf_placement_history` exist and expose `bookshelf_id`/`removed_at`/`from_bookshelf`/`to_bookshelf`; upload_dbt_test.exs — "placement.moved enqueues community read count refresh" (`:206`) wires `DbtRefreshHandler` → `mart_community_read_count` (consumed by `BookController.show/2`). | ✅ | ✅ (a) **`relationships` FK tests present** in `schema.yml`: `stg_bookshelf_placements.book_id → ref('stg_books')` and `bookshelf_id → ref('stg_bookshelves')` (`:215`+); `stg_bookshelf_placement_history.book_id → ref('stg_books')`, `from_bookshelf`/`to_bookshelf → ref('stg_bookshelves')` (`:272`+). (b) **CODE GAP closed:** `DbtRefreshHandler.@refresh_map` now maps `"placement.removed" => ["mart_community_read_count"]` (`dbt_refresh_handler.ex:38`), and upload_dbt_test.exs "placement.removed enqueues community read count refresh" (`:220`) proves it — `mart_community_read_count` (which filters `removed_at is null`) is recomputed after a remove. | ✅ |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ BookDetailProgramTest.elm (36) — view rendering ("loading_state", "success_renders_all_sections", "format_toggle", "shelf_mover_flow", "remove_modal_flow", "placement_loaded", "aria_regions", "section_content", "rating_display"); **success transitions now covered:** "move_confirm_happy: SelectBookshelf then ConfirmMove then MoveCompleted Ok updates currentBookshelf, closes the mover, and shows success" (`:665`) and "remove_confirm_happy: ConfirmRemove then RemoveCompleted Ok emits OutMsg NavigateTo previousRoute" (`:690`); the four no-op guards ("confirm_move_no_placement/no_token", "confirm_remove_no_placement/no_token", `:738`-`:790`). BookDetailAvailabilityTest.elm — availability section (4); BookDecoder.elm — Book/edition/author/visibility decoding. | ✅ | ✅ BookDetailProgramTest.elm — "failure_renders_error" (500), "forbidden_triggers_age_gate" (403 → age gate + Go Back); **failure + dismiss now covered:** "move_completed_error: a failed PUT renders the move failure message" (`:288`), "remove_completed_error: a failed DELETE renders the remove failure message" (`:709`), "close_overlay_x: clicking the X button emits RequestCloseOverlay" (`:329`), "close_overlay_backdrop: clicking the backdrop emits RequestCloseOverlay" (`:344`); focus trap (`:365`-`:425`: boundaries, forward/reverse wrap, natural pass-through, non-Tab); scoped Escape (`:102`-`:139`: consumed-modal / consumed-progress / unconsumed→RequestCloseOverlay); remove-modal dialog semantics + two-element trap (`:154`-`:214`). | ✅ |

#### Layer 11: Operational Metrics

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | n/a — per-route latency and status-code counters for `GET /api/books/:id`, move, and remove are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint / Ecto query telemetry. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a | ✅ **Instrumented + firing tests.** `BookDetailCache.get/1` now emits `[:stacks, :book_detail_cache, :hit]` on a live hit and `[:stacks, :book_detail_cache, :miss]` on a cold lookup **and** an expired entry (expired-as-miss) — `book_detail_cache.ex:37`/`:41`. Five firing tests in `book_detail_cache_telemetry_test.exs` (`describe "get/1 telemetry"`, `:46`-`:112`) cover cold-miss, hit-after-put, expired-as-miss, cold→warm miss→hit ordering, and a GDPR test pinning metadata to `[:book_id]` only (no user FK). GDPR lens = n/a: metadata carries `book_id` only. | ✅ |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — covered by SLO gate, not unit tests; in-test SLA bounds (US §14: `overlay.load_time` p95 < 800ms, cache hit-rate > 70%) are an anti-pattern under variable CI timing. Engagement counters (moves/removes/edition-switches per session) are client-side analytics, not test assertions. | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — US §15: no external API costs on the read path (book/placement/community-read-count/writing are local queries); Fly/Neon compute and R2 egress are covered by the cost dashboard at deploy time; there is no per-call spend to record in `BudgetTracker`. | n/a — same. |

---

### Punch list (16 items — all dispositioned)

Every baseline ❌/⚠️ cell, with its shipped disposition. Six items were
already closed by intervening merges before the epic (verified at kickoff
2026-07-23); the rest landed across Phases 1–3 + revision 1. Items #1 and #15's
hidden-book slice resolve as **n/a-with-rationale** (a book has no reachable
`:hidden` state — the age gate 403s first); everything else is a landed ✅.

| # | Cell | What was needed | Disposition (shipped) |
|--:|------|-----------------|------------------------|
| 1 | L1 US-1.4.1 sad | HTTP test: hidden-visibility book → 404 | **n/a — unreachable for books.** A book's only server-side hidden state is the age gate, which `AgeGate.enforce` (`book_controller.ex:192`) 403s **before** the `:hidden -> 404` branch (`:211`). Covered the reachable equivalent: `describe "hidden book is not served"` proves the 403 refusal leaks no payload (book_controller_test.exs `:629`-`:657`). |
| 2 | L3 US-1.4.1 sad | `Ecto.Multi` rollback/atomicity for move/remove | ✅ **Closed pre-epic.** shelving_test.exs `describe "move_book/3 — atomicity / rollback"` (`:235`) + abandon rollback (`:637`) + rejected-place/move no-side-effect tests (`:332`/`:347`). |
| 3 | L4 US-1.4.1 happy | Assert `placement.moved`/`.removed` payloads, not just counts | ✅ **Landed (Phase 2).** shelving_test.exs `:1390` (moved → `from_bookshelf`/`to_bookshelf` **names** + placement-id aggregate) + `:1408` (removed → `book_id`). NOTE: `placement.moved` carries shelf names and NO `book_id` (aggregate_id is the placement id) — tests assert the actual emit; adding `book_id` would be a prod change (follow-up if wanted). |
| 4 | L4 US-1.4.1 sad | No-events-on-read | ✅ **Landed (Phase 2).** book_controller_test.exs `describe "no events on read"` (`:663`) — authed + unauthed reads each assert `event_log` count unchanged. |
| 5 | L4 US-1.4.1 sad | Audit-log on move/remove | ✅ **Closed pre-epic.** shelving_test.exs `:167` (move) + `:473` (remove) assert the `:audit` Multi step. |
| 6 | L8 US-1.4.1 happy | Controller↔cache integration (miss → cache → hit) | ✅ **Landed (Phase 2).** book_controller_test.exs `describe "cache miss then hit"` (`:700`) proves miss-then-hit via `[:stacks, :book_detail_cache, :*]` telemetry + `refute_receive` of a second miss. |
| 7 | L9 US-1.4.1 sad | dbt `relationships` FK tests | ✅ **Closed pre-epic.** `schema.yml` relationships on `stg_bookshelf_placements` (`:215`+) and `stg_bookshelf_placement_history` (`:272`+). |
| 8 | L9 US-1.4.1 sad | **CODE GAP:** `placement.removed` triggers no dbt refresh | ✅ **Closed pre-epic.** `dbt_refresh_handler.ex:38` maps `placement.removed → mart_community_read_count`; upload_dbt_test.exs `:220` proves the enqueue. |
| 9 | L10 US-1.4.1 happy | Elm move/remove **success** paths | ✅ **Landed.** BookDetailProgramTest.elm "move_confirm_happy" (`:665`) + "remove_confirm_happy" (`:690`). |
| 10 | L10 US-1.4.1 sad | Elm move/remove failure + `CloseOverlay` OutMsg | ✅ **Landed (Phase 1).** "move_completed_error" (`:288`), "remove_completed_error" (`:709`), "close_overlay_x" (`:329`), "close_overlay_backdrop" (`:344`). |
| 11 | E2E (L1/L10 sad) | Playwright close-overlay (X/backdrop/Escape), focus-return, URL-unchanged | ✅ **Landed (Phase 3).** book-detail.spec.ts `describe "dismissal"` (`:137`) + `describe "focus contract"` (`:185`) — X/backdrop/Escape close with URL-unchanged before+after, focus-return to the triggering spine. |
| 12 | E2E (L2/a11y) | Playwright focus trap (Tab containment, focus-on-open, Shift+Tab) | ✅ **Landed (Phase 3).** book-detail.spec.ts focus-contract describe — focus-on-open on `book-overlay-close`, Tab never escapes, sentinel↔close forward/reverse wraps. Non-vacuity proven: commenting out `trapKeydownDecoder` makes the wrap test fail. |
| 13 | E2E (L1 sad) | Playwright move/remove failure | ✅ **Landed (Phase 3).** shelf-actions.spec.ts "move failure (403)" (`:304`) + "remove failure (500)" (`:332`). |
| 14 | E2E (L1 sad) | Playwright error + loading states | ✅ **Landed (Phase 3).** book-detail.spec.ts `describe "load and error states"` (`:289`) — 404/500 → "Could not load this book…", delayed-response loading state. |
| 15 | E2E (L2 sad) | Playwright unauth prompt (+ hidden→404) | ✅ **Landed (Phase 3), hidden slice n/a.** book-detail.spec.ts `describe "unauthenticated"` (`:378`) — public overlay shows "Sign In or Register", no owner actions. Hidden-book→404 E2E is **n/a** (books have no reachable hidden state; the unit layer covers 403-no-leak — see punch item 1 above). |
| 16 | L11 US-1.4.1 sad | Instrument `BookDetailCache` hit/miss telemetry + firing tests | ✅ **Landed (Phase 2).** `book_detail_cache.ex:37`/`:41` emit `:hit`/`:miss` (expired-as-miss); 5 firing tests in `book_detail_cache_telemetry_test.exs` (`:46`-`:112`) incl. a GDPR keys-only test. |

---

### Verdict

**Audit GREEN — shipped state.** State across the 13-layer × 1-US matrix
(26 cells):

- **15 ✅ STRONG** — API (happy + sad, incl. hidden-book-not-served/403-no-leak),
  auth guards (happy + sad), DB (happy + Multi rollback sad), event flow
  (moved/removed payloads + no-events-on-read + audit-log), cache (controller↔cache
  integration + invalidation), dbt (staging + relationships FK + moved/removed
  refresh), Elm (move/remove success + failure + `CloseOverlay` OutMsg + focus
  trap + scoped Escape + remove-modal dialog), and cache hit/miss telemetry (sad).
- **0 ⚠️ / 0 ❌** — all 16 punch-list items dispositioned (13 landed as tests,
  3 closed pre-epic by intervening merges, and the hidden-book→404 slice is
  n/a-with-rationale: a book has no reachable `:hidden` state).
- **11 n/a** — background jobs (read view triggers none), external services,
  storage (pre-stored URLs), performance/usability (SLO gate), cost
  tracking (no external spend), and operational-metrics happy path (SLO
  gate + automatic Phoenix/Ecto telemetry).

**Headline findings (shipped):**
1. **Server-side coverage is complete for the named contract** — the two
   previously-untested points are now covered: the reachable **hidden-book
   refusal** (403, no payload leak; the literal `:hidden→404` branch is
   defensively unreachable for books) and the **event payloads** for
   `placement.moved` (shelf names + placement-id aggregate) / `placement.removed`
   (`book_id`).
2. **Two in-scope builds landed** (kickoff-approved 2026-07-23): the Elm overlay
   **focus trap + focus-return** (the US-1.4.1 a11y contract, sentinel-anchored,
   no ports) and **`BookDetailCache` hit/miss telemetry** (`book_id`-only
   metadata, GDPR-clean). The two baseline code gaps (`placement.removed` dbt
   refresh; cache telemetry) are both closed.
3. **The overlay's dismissal contract is now covered end-to-end** — X /
   backdrop / Escape close, focus-return, focus trap, and URL-unchanged are all
   driven live (`book-detail.spec.ts`), with the Elm `CloseOverlay` →
   `RequestCloseOverlay` OutMsg and move/remove failure + book-load error states
   covered at the program-test layer. Revision 1 added scoped Escape and
   remove-modal dialog semantics/focus, all live-verified.

**Test runner totals (verified 2026-07-24):**
Elixir — scoped run 152 tests, 0 failures (book/placement/shelving/cache/handler
+ new telemetry suite); Elm — `BookDetailProgramTest` (36) +
`BookDetailAvailabilityTest` (4) + `BookDecoder` (12), full elm-test 1020 green;
Playwright — `book-detail.spec.ts` (22) + `shelf-actions.spec.ts` (7) = **29
passing** on `--project=chromium`; dbt — staging models with relationships +
`accepted_values` tests. Punch list: **16 items, all dispositioned (0 open).**
## Definition of Done
- [x] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local` — 2026-07-24: Elixir scoped run 152 tests / 0 failures; `elm-test` full suite 1020 / 0 (incl. `BookDetailProgramTest` 36); Playwright `--project=chromium` 29 passing (`book-detail.spec.ts` 22 + `shelf-actions.spec.ts` 7).
- [x] No flaky tests — 2026-07-24: repeated green runs across implementation, TC verification (ALL PASS), and reviewer re-runs (elm + elixir APPROVED, ux APPROVED on re-review after revision 1); `check-e2e-vacuous-guards.sh` clean and the focus-trap E2E proven non-vacuous (fails when `trapKeydownDecoder` is disabled, restored to green).
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — 2026-07-24: US-1.4.1 built end-to-end (spine-click → overlay → dismissal/focus contract) and driven live (keyboard-walk + 29 E2E). No named story reaches GREEN via `n/a (see #NNN)`.
- [x] **Test audit (embedded above) is GREEN** — 2026-07-24: regenerated to shipped state; 15 ✅ / 0 ⚠️ / 0 ❌ / 11 n/a; all 16 punch-list items dispositioned.
- [x] `just verify` passes — evidence: `just run just verify` → exit 0 on the quiescent integrated tree 2026-07-24 ~16:22 (elixir `2888 tests, 0 failures`, elm `Passed: 1031`, dbt `PASS=237`, checkpoint gates all pass; log: scratchpad/verify-quiescent-post287.log)

## Dependencies
- Seeded books with full metadata (editions, authors, reviews, prices)
- Seeded placements on various shelves
- BookDetailCache infrastructure
- Playwright test harness with auth helpers
- `data-testid` attributes on overlay elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/cache tests, `elm-agent` for state machine tests.

## Progress Notes
- 2026-07-23 — Epic kickoff (#115/#114/#113 on `feat/115-114-3-e2e`). Baseline re-verified: six punch items already closed by intervening merges (`placement.removed` in `dbt_refresh_handler.ex:38`; dbt relationships in `staging/schema.yml:218-298`; audit-log tests `shelving_test.exs:167/473`; Multi rollback tests `:235`; cache wired into controller `book_controller.ex:198/241`; Elm move/remove happy + remove-failure in `BookDetailProgramTest` — 18 tests now). Still open: cache telemetry (none in `book_detail_cache.ex`), hidden→404 / no-events-on-read / controller↔cache tests, moved/removed event payload assertions, Elm move-failure + `CloseOverlay`→`RequestCloseOverlay` tests, and all E2E dismissal/focus/error/unauth coverage. FEATURE GAPS confirmed: no focus trap (only `role=dialog`/`aria-modal`/`tabindex -1`, `BookDetail.elm:1294-1297`); Escape handled globally in `Main.elm:2381-2386` (confirm it closes the overlay during live drive). Approved in-scope: focus trap + focus-return build; cache hit/miss telemetry. Age-gate "Click Verify" line corrected to n/a (ADR-020 §2, #069). Weak assertion to fix while in the file: `book-detail.spec.ts:38` OR-assertion passes on error/loading.
- 2026-07-24 — Phase 2 (elixir) done. Added `[:stacks, :book_detail_cache, :hit|:miss]` telemetry to `book_detail_cache.ex:get/1` (hit / cold-miss / expired-as-miss); GDPR lens = n/a (metadata is `%{book_id}` only, no user FK — pinned by a test). Test-first: 5 telemetry tests captured failing (5/5, assertion failures) before impl, green after. New tests: `book_detail_cache_telemetry_test.exs` (5); `book_controller_test.exs` — no-events-on-read (2), controller↔cache miss→hit via telemetry (1), hidden-book-not-served (2); `shelving_test.exs` — placement.moved/removed payload assertions (2, new describes). Scoped run: 152 tests, 0 failures; credo --strict + format clean. FLAG (punch #3): the controller's `resolve_visibility==:hidden → 404` branch is defensively UNREACHABLE for books — a book's only hidden state is the age gate, which `AgeGate.enforce` shadows as 403 first; books have no owner/block and `visibility_tier` always resolves "public". Covered the reachable equivalent (403, no payload leak). FLAG (punch #16): `placement.moved` payload carries shelf NAMES (`from_bookshelf`/`to_bookshelf`), not ids, and NO `book_id` (aggregate_id is the placement id); `placement.removed` carries `book_id` only — tests assert the ACTUAL keys per plan's "read emit call first". Adding `book_id` to the moved payload would be a production change beyond Phase 2 scope → recommend a follow-up if wanted.
- 2026-07-24 — Phase 1 (elm) done. Built the overlay focus trap (no ports): `preventDefaultOn "keydown"` on `book-overlay__card` + a trailing focus sentinel (`book-overlay-focus-sentinel`); the decoder wraps forward-Tab-off-sentinel → close button (`FocusWrapToFirst`) and Shift+Tab-off-close → sentinel (`FocusWrapToLast`), `Browser.Dom.focus` via `firstFocusableId`/`lastFocusableId`; all other keydowns fail the decoder (native tab order, no preventDefault). Anchoring "last" to a sentinel keeps the trap correct regardless of which content controls render. Focus-on-open (`Browser.Dom.focus "book-overlay-close"`), focus-return-to-trigger, and Escape-closes-overlay were already wired in `Main.elm` (`openOverlay:2345`, `OverlayBookDetailMsg RequestCloseOverlay:2093`, `EscapePressed:2158`, keydown sub `:2381`) — confirmed present; their live keyboard drive + the Escape/close/focus-return E2E are Phase 3 (punch #11/#12). Test-first: 2 constructor-free probes captured failing (sentinel absent; card has no keydown handler) before impl. New `BookDetailProgramTest` tests (18→27): 6 trap (boundaries present, forward/reverse wrap targets, forward/reverse natural pass-through, non-Tab ignored), move-failure copy (#10), and CloseOverlay→RequestCloseOverlay via X + backdrop (#10, new `bookDetailOverlayProgramWithOut` harness). Full elm-test 999→1008 green; elm-format + elm-review clean; deployed `app.js` rebuilt (`apps/core/assets` → `priv/static/assets/app.js`).
- 2026-07-24 — Phase 3 (E2E) done. Extended `e2e/tests/book-detail.spec.ts` (dismissal via X/backdrop/Escape with URL-unchanged assertions before+after each; focus contract — focus-on-open lands on `book-overlay-close`, Tab-containment never escapes the overlay, sentinel→close forward wrap, close→sentinel reverse wrap, focus-return to the triggering `spine-<id>` on close; 404/500 book-fetch mocks → "Could not load this book. Please try again."; delayed-response loading state; unauthenticated public-book overlay → "Sign In or Register" with no Choose-Bookshelf/Remove/Add) and `e2e/tests/shelf-actions.spec.ts` (punch #13 — mocked PUT .../move 403 → "Failed to move book…", mocked DELETE .../:id 500 → "Failed to remove book…", overlay stays open on both). Fixed the weak OR at `book-detail.spec.ts:38` → deterministic loaded-hero XOR (cover-img vs placeholder). `check-e2e-vacuous-guards.sh` clean; hidden-book→404 E2E left n/a (books have no reachable hidden state; unit layer covers 403-no-leak). Non-vacuity gate: with `preventDefaultOn "keydown" trapKeydownDecoder` commented + assets rebuilt, the sentinel→close wrap test FAILS (`Expected "book-overlay-close", Received ""` — focus escaped to body); restored + rebuilt → 27/27 green. Full run: 27 passed (book-detail 20 + shelf-actions 7). INCIDENT (recovered): a `git checkout -- BookDetail.elm` during the non-vacuity step reverted Phase 1's UNCOMMITTED trap work; reconstructed it from the intact `BookDetailProgramTest.elm` contract + re-verified (elm-test 1008 green, elm-format clean, E2E 27 green) — Phase 1 elm work should be committed promptly to prevent recurrence.
- 2026-07-24 — Phase 1 revision 1 (ux P2 a11y, test-first). (1) **Scoped Escape** — new `BookDetail.EscapePressed` dismisses the top-most surface first: remove-modal open → close only it (focus returns to the "Remove from collection" trigger); else progress-edit form open → close only it (focus returns to the badge); else → `RequestCloseOverlay`. `Main.elm:2158` now forwards Escape into `BookDetail.update` when the overlay is open and closes the overlay only on the `RequestCloseOverlay` OutMsg (focus-return-to-spine preserved unchanged); Main gained the forward, lost the unconditional close. (2) **Remove-modal focus management** in `Components/RemoveBookModal.elm` — `role="dialog"` + `aria-modal="true"` + `aria-labelledby` on the labelled heading; stable button ids (`remove-book-cancel`/`remove-book-confirm`); a two-element Tab/Shift+Tab trap (`preventDefaultOn "keydown"` → `FocusOn`); `OpenRemoveModal` focuses "Keep It" (safe default), `CloseRemoveModal`/Escape return focus to `book-detail-remove-trigger`. (3) **Sentinel aria-label** — "End of book details — press Tab to return to the top" (also resolves the elm-reviewer P2 on the silent resting stop); no `role="presentation"`/`aria-hidden`. Test-first: 3 constructor-free probes (sentinel label, dialog semantics, button ids) captured failing before impl. New `BookDetailProgramTest` tests (27→36): 3 semantics/label probes + scoped-Escape consumed-modal / consumed-progress / unconsumed→RequestCloseOverlay + modal-trap forward/reverse/natural. Full elm-test 1020 green; elm-format + elm-review clean; `Main.elm --optimize` compiles; `app.js` rebuilt. Files: `frontend/src/Page/BookDetail.elm`, `frontend/src/Components/RemoveBookModal.elm`, `frontend/src/Main.elm`, `frontend/tests/Page/BookDetailProgramTest.elm`.
- 2026-07-24 — Phase 3 revision 1 (E2E for the scoped-Escape + modal-focus rev). Extended `e2e/tests/book-detail.spec.ts` with the live assertions the elm-program-test layer cannot observe (real focus movement in a browser): (1) **scoped Escape** — with the remove modal open, the first Escape closes ONLY the modal (overlay stays visible; `document.activeElement` returns to `book-detail-remove-trigger`), and a second Escape then closes the overlay; (2) **modal focus-on-open** lands on "Keep It" (`activeElement` id `remove-book-cancel`); (3) **modal Tab trap** — Tab from `remove-book-confirm` (Remove) wraps to `remove-book-cancel` (Keep It), Shift+Tab from cancel wraps back to confirm; (4) **sentinel aria-label** now asserted = "End of book details — press Tab to return to the top". The three modal specs provision their own placement via `provisionBookOnShelf` (#294) so they never touch shared-seed drift. Full overlay run green: **31 passed** (`book-detail.spec.ts` 24 + `shelf-actions.spec.ts` 7), `--project=chromium`; `check-e2e-vacuous-guards.sh` clean.
