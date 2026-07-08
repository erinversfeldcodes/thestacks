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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #114)

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
| Elixir      | ⚠️ (strong controller + context + cache coverage; gaps: hidden-visibility→404 at HTTP, moved/removed event payloads, audit-log on move/remove, no-events-on-read, Multi rollback, controller↔cache integration) |
| Elm unit    | ✅ (`BookDecoder.elm` — 12 tests covering Book/edition/author/visibility-tier decoding; page state lives in program tests) |
| Elm program | ⚠️ (`BookDetailProgramTest` 11 + `BookDetailAvailabilityTest` 4 = strong view rendering; move/remove **success/failure** transitions and `CloseOverlay`→`RequestCloseOverlay` OutMsg untested) |
| Python      | n/a — vision service not involved in the read-only detail overlay |
| E2E         | ⚠️ (open-overlay, all-sections, format toggle, move-success, remove-flow, add-to-collection covered; **close (X/backdrop/Escape), focus trap, move/remove failure, error states, unauth prompt, hidden-404** all absent) |
| dbt         | ⚠️ (staging models exist + `placement.moved`→`mart_community_read_count` refresh tested; no relationships/FK tests; `placement.removed` does **not** trigger a refresh — code gap) |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/book_controller_test.exs` — `GET /api/books/:id` (200 with full JSON, placement, my_writing, editions, primary_edition, community_read_count; 404; 403 age-gated; 200 age-verified; optional-auth null placement; visibility gates; my_writing variants).
- `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — move (200/403/422/401), delete (204/403/404/401), formats (200/403/422/401), create (201/422/401), mine, visibility, progress.
- `apps/core/test/stacks/shelving_test.exs` — `move_book/3` (history + `placement.moved` count), `remove_book/2` (removed_at + `placement.removed` count), unauthorized paths, `place_book/3` payload.
- `apps/core/test/stacks/books_test.exs` — `get_book_detail/1` (loads with preloads; nil for nonexistent), `primary_edition/1`.
- `apps/core/test/stacks/books/book_detail_cache_test.exs` — get miss/put+get hit/invalidate/invalidate_all/TTL expiry (5 tests).
- `apps/core/test/stacks/books/handlers/cache_invalidation_handler_test.exs` — invalidation on `book.created`, `book.cover_confirmed`, `blog.associations_suggested`; ignores unrelated.
- `apps/core/test/stacks/feeds/handlers/placement_handler_test.exs` — `placement.created`/`.moved`/`.removed` → `RegenerateFeedJob` enqueue.
- `apps/core/test/stacks/upload_dbt_test.exs` — `placement.moved` → `mart_community_read_count` refresh (and standalone).
- `apps/core/test/stacks/visibility_test.exs` — `resolve_visibility/2` incl. age-gate → `:hidden`/`:visible`.
- `frontend/tests/Page/BookDetailProgramTest.elm` (11) + `frontend/tests/Page/BookDetailAvailabilityTest.elm` (4) + `frontend/tests/BookDecoder.elm` (12).
- `e2e/tests/book-detail.spec.ts` (6), `book-interaction.spec.ts` (open overlay), `shelf-actions.spec.ts` (move/remove/add), `editions.spec.ts`, `age-gate.spec.ts`.
- `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (+ `accepted_values` on `reading_status`) and `stg_bookshelf_placement_history` (generic column tests only).

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **6** |
| ⚠️ shallow | **7** |
| ❌ missing | **2** |
| n/a (covered higher up / not applicable / by-design) | **11** |

26 cells total (13 layers × happy/sad). This is the pre-implementation
baseline; Issue #114's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ book_controller_test.exs — "returns 200 with book JSON when book exists" (asserts id, title, visibility_tier, primary_edition.isbn, editions list, edition_count, community_read_count), "returns placement data when user has an active placement", "returns 200 for age_gated book when user is age_verified"; move/remove/formats happy: bookshelf_placement_controller_test.exs — "returns 200 when user moves own placement", "returns 204 when user deletes own placement", "returns 200 with updated formats", "returns 201 with placement on valid bookshelf and book_id". | ✅ | ⚠️ book_controller_test.exs — "returns 404 when book does not exist", "returns 403 for age_gated book when user is not age_verified"; bookshelf_placement_controller_test.exs — move "returns 422 when bookshelf parameter is missing"/"403 non-owner", delete "404 nonexistent"/"403 non-owner", formats "422 missing"/"422 not-array"/"403 non-owner". **GAP:** Issue §2/US §4 require a **hidden-visibility book → 404** at the HTTP layer — no such test exists (`GET /api/books/:id` for a book whose visibility resolves to `:hidden`; note book `visibility_tier` is only `public`/`age_gated`, so the hidden path is via `Visibility.resolve_visibility`, untested through the controller). | ⚠️ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ book_controller_test.exs — optional-auth works unauthenticated ("returns 200 with null placement when not authenticated", "public book returns 200 for unauthenticated viewer") and enriches when authenticated ("returns placement data ...", my_writing describe); ownership guards: bookshelf_placement_controller_test.exs — move/delete/formats "403 non-owner"; shelving_test.exs — "returns :unauthorized when user does not own the placement" (remove + abandon). | ✅ | ✅ bookshelf_placement_controller_test.exs — "returns 401 when not authenticated" present for **all** mutation endpoints (move, delete, formats, create); age gate: book_controller_test.exs — "returns 403 for age_gated book when user is not age_verified" + "age_gated book returns 403 for unauthenticated viewer". | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ books_test.exs — `get_book_detail/1` "returns book with preloads" + `primary_edition/1`; shelving_test.exs — move "moves placement to new bookshelf and writes history" (asserts `bookshelf.name` change + `history.from_bookshelf`), "creates history record in PlacementHistory table", remove "sets removed_at on the placement"; formats update via controller test; placement lookup via book_controller_test.exs "returns placement data ...". | ✅ | ⚠️ books_test.exs — `get_book_detail/1` "returns nil for nonexistent book"; shelving_test.exs — move/remove unauthorized. **GAP:** Issue §3 "Ecto.Multi Transactions: Move (update + history insert + event emit) all atomic; Remove (soft-delete + event + audit log) all atomic" — no **rollback/atomicity** test (e.g. forcing the history insert or event step to fail and asserting the placement update is rolled back). | ⚠️ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ⚠️ shelving_test.exs — "emits placement.moved event" and "emits placement.removed event" (both assert event **count** +1 only); handlers: placement_handler_test.exs — `placement.moved` "enqueues jobs for both source and destination bookshelves" + `placement.removed` "handles nil bookshelf name gracefully"; upload_dbt_test.exs — "placement.moved enqueues community read count refresh". **GAP:** Issue §4 requires the `placement.moved` payload `%{from_bookshelf, to_bookshelf}` and `placement.removed` payload to be asserted — only `placement.created` has a payload-shape test (shelving_test.exs "placement.created payload includes the book's visibility_tier"). | ⚠️ | ❌ Two Issue-§4 assertions have **zero** tests: (a) "No Events on Read — `GET /api/books/:id` emits no events" (no read-path event-absence test in book_controller_test.exs or events_test.exs); (b) "Move creates audit log entry / Remove creates audit log entry" — no audit-log assertion tied to move/remove (no `audit`/`AuditLog` reference in shelving_test.exs). | ❌ |

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
| 1.4.1 | ⚠️ book_detail_cache_test.exs — the cache **mechanism** is well tested: "returns {:miss, book_id} for uncached entries", "returns cached data" (put+get hit), TTL expiry ("expired entries return :miss"). **GAP:** Issue §8 requires **controller↔cache integration** — first `GET /api/books/:id` = cache miss → DB → cached; second fetch = cache hit → no DB query. No test wires `BookController.show/2` to the cache or asserts DB-query count on hit vs miss. | ⚠️ | ✅ cache_invalidation_handler_test.exs — invalidation on `book.created`, `book.cover_confirmed`, `blog.associations_suggested`, and "ignores unrelated events"; book_detail_cache_test.exs — `invalidate/1`, `invalidate_all/0`, TTL expiry. **Note (by design, not a gap):** `CacheInvalidationHandler` does **not** invalidate on `placement.moved`/`.removed` — correct, since `BookDetailCache` holds book metadata while placement is per-user and fetched separately; Issue §8's "invalidated after move/remove" assumption does not apply to this cache. | ✅ |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ✅ `dbt/models/staging/schema.yml` — `stg_bookshelf_placements` (proto-generated; `not_null`+`unique` on id, `accepted_values` on `reading_status`) and `stg_bookshelf_placement_history` exist and expose `bookshelf_id`/`removed_at`/`from_bookshelf`/`to_bookshelf`; upload_dbt_test.exs — "placement.moved enqueues community read count refresh" wires `DbtRefreshHandler` → `mart_community_read_count` (consumed by `BookController.show/2`). | ✅ | ❌ (a) No `relationships` tests: `stg_bookshelf_placements.book_id → stg_books.id` / `bookshelf_id → stg_bookshelves.id`, `stg_bookshelf_placement_history.from_bookshelf|to_bookshelf → stg_bookshelves.id` (schema.yml is proto-generated — fixes must go via `mix proto.sync` generator or a singular test under `dbt/tests/`). (b) **CODE GAP:** `DbtRefreshHandler`'s `@refresh_map` maps only `placement.created` and `placement.moved` — **`placement.removed` triggers no refresh**, so `mart_community_read_count` goes stale after a remove. Issue §9 ("After Remove: DbtRefreshHandler triggered by placement.removed") assumes a mapping that does not exist. | ❌ |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | ⚠️ BookDetailProgramTest.elm — "loading_state", "success_renders_all_sections" (hero/about/reviews/prices/author-card/writing/shelf-actions), "format_toggle", "shelf_mover_flow" (open→cancel), "remove_modal_flow" (open→Keep It), "placement_loaded", "aria_regions", "section_content", "rating_display"; BookDetailAvailabilityTest.elm — availability section (4); BookDecoder.elm — Book/edition/author/visibility decoding. **GAP:** the **success** transitions are untested: `ConfirmMove` → `MoveCompleted (Ok _)` → `currentBookshelf` updates + shelf mover closes; `ConfirmRemove` → `RemoveCompleted (Ok _)` → `NavigateTo previousRoute` OutMsg. | ⚠️ | ⚠️ BookDetailProgramTest.elm — "failure_renders_error" (500 → "Could not load this book. Please try again."), "forbidden_triggers_age_gate" (403 → age gate + Go Back dismiss). **GAP:** `MoveCompleted (Err _)` → "Failed to move book...", `RemoveCompleted (Err _)` → "Failed to remove book...", and `CloseOverlay` → `RequestCloseOverlay` OutMsg (X / backdrop / Escape dismiss) are untested. | ⚠️ |

#### Layer 11: Operational Metrics

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.4.1 | n/a — per-route latency and status-code counters for `GET /api/books/:id`, move, and remove are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint / Ecto query telemetry. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a | ⚠️ Issue §11 / US §13 explicitly list `cache.hit{cache="BookDetailCache"}` / `cache.miss` / `cache.hit_ratio` metrics and flag them "not yet instrumented — verify events exist when added". `BookDetailCache` emits no telemetry today (no `:telemetry.execute` in `book_detail_cache.ex`; no cache metric in any telemetry test). Needs a decision: instrument hit/miss + add firing tests (pattern: `upload_telemetry_test.exs`), or formally descope and reclassify n/a. **Partially blocked on instrumentation (feature gap, not just test gap).** | ⚠️ |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — covered by SLO gate, not unit tests; in-test SLA bounds (US §14: `overlay.load_time` p95 < 800ms, cache hit-rate > 70%) are an anti-pattern under variable CI timing. Engagement counters (moves/removes/edition-switches per session) are client-side analytics, not test assertions. | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.4.1 | n/a — US §15: no external API costs on the read path (book/placement/community-read-count/writing are local queries); Fly/Neon compute and R2 egress are covered by the cost dashboard at deploy time; there is no per-call spend to record in `BudgetTracker`. | n/a — same. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to numbered items. No tests were written or
modified during this audit (pre-implementation baseline). Items #8 and #16
are **code gaps** that exceed a test-only issue and, per the scope-lock
rule, may spin out as new issues.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-1.4.1 sad | HTTP test: `GET /api/books/:id` for a book whose visibility resolves to `:hidden` returns 404 (Issue §2 / US §4 — hidden book must not leak) | `apps/core/test/stacks_web/book_controller_test.exs` |
| 2 | L3 US-1.4.1 sad | `Ecto.Multi` rollback/atomicity: force the history-insert or event-emit step to fail in `move_book/3` (and the event/audit step in `remove_book/2`) and assert the placement change is rolled back | `apps/core/test/stacks/shelving_test.exs` |
| 3 | L4 US-1.4.1 happy | Extend the two "emits placement.*" tests to assert payload: `placement.moved` carries `%{from_bookshelf, to_bookshelf, book_id}`; `placement.removed` carries the book/bookshelf ids — not just event count | `apps/core/test/stacks/shelving_test.exs` |
| 4 | L4 US-1.4.1 sad | No-events-on-read: `GET /api/books/:id` inserts no `event_log` row (assert count unchanged before/after) | `apps/core/test/stacks_web/book_controller_test.exs` (or `events_test.exs`) |
| 5 | L4 US-1.4.1 sad | Audit-log assertion: `move_book/3` and `remove_book/2` each write an `audit_log` entry (Issue §4 "Move/Remove creates audit log entry") — or confirm-and-descope if move/remove are not audit-logged by design | `apps/core/test/stacks/shelving_test.exs` |
| 6 | L8 US-1.4.1 happy | Controller↔cache integration: first `GET /api/books/:id` = miss → DB → cached; second = hit → no DB query (assert via `BookDetailCache.get/1` state and/or Ecto query telemetry count) | `apps/core/test/stacks_web/book_controller_test.exs` |
| 7 | L9 US-1.4.1 sad | dbt `relationships` tests: `stg_bookshelf_placements.book_id → stg_books.id`, `bookshelf_id → stg_bookshelves.id`; `stg_bookshelf_placement_history.from_bookshelf|to_bookshelf → stg_bookshelves.id` — via `mix proto.sync` generator (schema.yml is proto-generated) or singular tests under `dbt/tests/singular/` | `dbt/tests/singular/` or proto-sync generator |
| 8 | L9 US-1.4.1 sad | **CODE GAP:** `placement.removed` triggers no dbt refresh. Add `"placement.removed" => ["mart_community_read_count"]` to `DbtRefreshHandler.@refresh_map` and a test in upload_dbt_test.exs — or formally descope §9's remove-refresh claim. **Exceeds test-only scope → likely a new issue.** | `apps/core/lib/stacks/workers/dbt_refresh_handler.ex` + `apps/core/test/stacks/upload_dbt_test.exs` |
| 9 | L10 US-1.4.1 happy | Elm program tests for the move/remove **success** paths: `ConfirmMove` → `MoveCompleted (Ok _)` updates `currentBookshelf` + closes shelf mover; `ConfirmRemove` → `RemoveCompleted (Ok _)` fires `NavigateTo previousRoute` OutMsg | `frontend/tests/Page/BookDetailProgramTest.elm` |
| 10 | L10 US-1.4.1 sad | Elm program tests for failure + dismiss: `MoveCompleted (Err _)` → "Failed to move book...", `RemoveCompleted (Err _)` → "Failed to remove book...", `CloseOverlay` → `RequestCloseOverlay` OutMsg | `frontend/tests/Page/BookDetailProgramTest.elm` |
| 11 | E2E (L1/L10 sad) | Playwright close-overlay flows: X button, backdrop click, and Escape key each dismiss the overlay; focus returns to the triggering spine button; URL never changes | `e2e/tests/book-detail.spec.ts` |
| 12 | E2E (L2/accessibility) | Playwright focus trap: Tab cycles within the overlay (does not escape to the shelf behind), first focusable element focused on open, Shift+Tab reverses | `e2e/tests/book-detail.spec.ts` |
| 13 | E2E (L1 sad) | Playwright move/remove **failure**: mock move 403/422 → "Failed to move book. Please try again."; mock remove failure → "Failed to remove book. Please try again." | `e2e/tests/shelf-actions.spec.ts` |
| 14 | E2E (L1 sad) | Playwright error + loading states: mock `GET /api/books/:id` 404 and 500 → "Could not load this book. Please try again."; loading skeleton/spinner shown before the response | `e2e/tests/book-detail.spec.ts` |
| 15 | E2E (L2 sad) | Playwright unauthenticated overlay: view a public book without auth → "Sign In or Register" prompt shown, no Move/Remove/Add actions; and hidden book → "Could not load this book" (404) | `e2e/tests/book-detail.spec.ts` |
| 16 | L11 US-1.4.1 sad | Decide + implement: instrument `BookDetailCache` hit/miss telemetry (+ `book_detail_request_count`) and add firing tests (pattern: `upload_telemetry_test.exs`), or formally descope §11 and reclassify n/a. **Partially blocked on instrumentation — the counters do not exist in `book_detail_cache.ex` yet.** | `apps/core/lib/stacks/books/book_detail_cache.ex` + new telemetry test |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 1-US matrix (26 cells):

- **6 ✅ STRONG** — API happy path, auth guards (happy + sad), DB happy
  path, cache invalidation/TTL (sad), and dbt happy path (staging models +
  `placement.moved` refresh).
- **7 ⚠️ shallow** — hidden-visibility→404 untested at HTTP; Multi rollback
  untested; `placement.moved`/`.removed` event **payloads** unasserted;
  controller↔cache integration untested; Elm move/remove success + failure
  transitions and `CloseOverlay` OutMsg untested; `BookDetailCache` metrics
  uninstrumented.
- **2 ❌ missing** — no-events-on-read + audit-log-on-move/remove (L4 sad);
  dbt relationships/FK tests + the `placement.removed`-refresh code gap
  (L9 sad).
- **11 n/a** — background jobs (read view triggers none), external services,
  storage (pre-stored URLs), performance/usability (SLO gate), cost
  tracking (no external spend), and operational-metrics happy path (SLO
  gate + automatic Phoenix/Ecto telemetry).

**Headline findings:**
1. **Server-side coverage is genuinely strong** — `book_controller_test.exs`
   and `bookshelf_placement_controller_test.exs` exercise every endpoint's
   200/401/403/404/422 branches — but two contract points the issue names
   are untested: **hidden-visibility → 404** at the controller and the
   **event payloads** for `placement.moved`/`.removed` (only counts are
   asserted).
2. **Two real code gaps** surfaced (not just test gaps): (a)
   `DbtRefreshHandler` never refreshes `mart_community_read_count` on
   `placement.removed`, so the community read count goes stale after a
   remove; (b) `BookDetailCache` emits no hit/miss telemetry despite US §11
   listing those metrics. Both likely warrant follow-up issues under the
   scope-lock rule.
3. **The overlay's dismissal contract is untested end-to-end** — the
   defining behaviour of US-1.4.1 (X / backdrop-click / Escape close, focus
   return, focus trap, URL-unchanged) has **no** Playwright coverage, and
   the corresponding Elm `CloseOverlay` → `RequestCloseOverlay` OutMsg is
   likewise untested. Move-success is well covered (shelf-actions.spec.ts);
   move/remove **failure** and book-load **error** states are not.

**Test runner totals at baseline (not re-run during this audit):**
Elixir — book/placement/shelving/cache/handler suites across ~8 files;
Elm — `BookDetailProgramTest` (11) + `BookDetailAvailabilityTest` (4) +
`BookDecoder` (12); Playwright — `book-detail.spec.ts` (6) plus overlapping
`book-interaction`/`shelf-actions`/`editions`/`age-gate` specs; dbt —
generic column tests on the two placement staging models. Punch list:
**16 items**, of which #8 and #16 are partially blocked on code/instrumentation.
## Definition of Done
- [ ] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] `just verify` passes

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
