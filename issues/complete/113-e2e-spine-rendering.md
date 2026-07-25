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
| US-1.3.1 — Spine Thickness by Page Count | Width formula `Spine.elm:57-59` (`max(35, min(55, round(pageCount/12)))`) → default fallback `Page.Bookshelf.Helpers.elm:58,129` (`Maybe.withDefault 200 (bookPageCount bk)`) → `page_count` round-trips through `GET /api/bookshelves/:name` (`bookshelf_controller_test.exs:274-290`, `primary_edition.page_count == 450`). | Library shelf 2026-07-24: Dreamtigers 95pp→35px, Queen Loana 480pp→40px, Name of the Rose 536pp→45px, Brothers Karamazov 796pp→55px — observed `offsetWidth == inline width`. | ✅ | Built end-to-end + observed live. |
| US-1.3.2 — Spine Wear by Engagement | Wear suffix `Spine.elm:264-277` (`Softened` → `", well-loved"`; `Pristine` → none; composes with `", hidden (only visible to you)"`) → per-shelf config `Page.Bookshelf.elm:68/81/94` (library=`Softened`, antilibrary/wishlist=`Pristine`) + `ReadingPile.elm:460` (hardcoded `Softened`). | Full aria observed 2026-07-24: `"Book: The Name of the Rose by Umberto Eco, 536 pages, well-loved, hidden (only visible to you)"`; ReadingPile Goldfinch 771pp `", well-loved"`. | ✅ (in-scope aria/config slice) | Aria-level wear slice built + observed live. Bookmark-ribbon slice de-scoped → **#287**; visual wear CSS slice de-scoped → **#288** (see Resolution note under Test Suites §Wear Level by Shelf). |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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
- Navigate to WishList: verify spines render with `Pristine` wear (aria-label has no wear suffix)
- Navigate to AntiLibrary: verify spines render with `Pristine` wear (per codebase — `wearLevel = Pristine`)
- Navigate to Reading Pile: verify spines render with `Softened` wear (aria-label ends ", well-loved")
- Navigate to Library: verify spines render with `Softened` wear
- Verify the aria-level distinction between Pristine and Softened wear states (", well-loved" suffix present iff Softened). **Visual CSS distinction DE-SCOPED → #288** (no wear-specific CSS exists — wear reaches only the aria suffix, `Spine.elm:264-270`)

#### ARIA Labels (US-1.3.1, US-1.3.2)
- Verify each spine button has an `aria-label` attribute
- Verify `aria-label` includes the book title
- Verify `aria-label` includes page count (e.g., "420 pages")
- Verify `aria-label` includes wear state suffix (e.g., ", well-loved" for Softened)
- Verify `role="listitem"` on each spine button
- Verify `role="list"` on `shelf-row__books` container

#### Books with User Writing — DE-SCOPED → #287
- Bookmark ribbon / coloured tabs are unimplemented (no such element in `Components.Spine`); feature spun out to #287.

### 2. API Endpoint Tests

#### Spine Data via Bookshelf API
- `GET /api/bookshelves/:name` returns placements with `book.primary_edition.page_count`
- Page count is an integer or null
- Verify `page_count` propagates correctly through the JSON response

#### Server-side wear calculation (`Shelving.spine_data/1` — context-only; NO HTTP route exists)
- CORRECTED 2026-07-23: there is no `GET /api/spine_data/:placement_id` route, and the real
  `compute_wear_level` thresholds (`shelving.ex:545-548`) are: move_count 0 → `:new`,
  1-2 → `:light`, 3-5 → `:moderate`, 6+ → `:heavy` (not pristine/softened/well_loved).
- Test all four `compute_wear_level` branches via seeded `PlacementHistory` rows
- Verify `Shelving.spine_data/1` returns correct structure (and nil for unknown placement)
- Note: Elm wear (`Pristine|Softened` from static per-shelf config) is fully DECOUPLED from
  this backend wear model — the renderer never consumes `spine_data` wear.

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

## Test Audit

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). **Regenerated to the SHIPPED state** — every cell re-verified against the merged suites; the punch list is resolved. The issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-24 (SHIPPED — Issue #113, all punch items resolved)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #113 covers two user stories — US-1.3.1 (Spine
Thickness by Page Count, `docs/user_stories/US-1.3.1-spine-thickness.md`)
and US-1.3.2 (Spine Wear by Engagement,
`docs/user_stories/US-1.3.2-spine-wear.md`) — so the matrix is 13 layers ×
2 US, with happy/sad columns per cell. The assertion inventory for each
layer is taken from Issue #113's Test Suites section
(`issues/113-e2e-spine-rendering.md`).

**Domain note:** Spine rendering is overwhelmingly a **frontend (Elm)**
concern. Layer 10 (Elm state machine) is the core of the audit. US-1.3.1
(thickness) is a pure client-side function of page count
(`Components.Spine.spineWidth`) — no server round trip. US-1.3.2 (wear) has
a richer server-side model (`Shelving.spine_data/1` + `RecalculateWearJob`)
that is **not yet consumed by the frontend** — the frontend applies a
simpler per-shelf `WearLevel` (`Pristine | Softened`) from the page config,
and wear currently affects only the ARIA-label suffix (no wear-specific CSS
yet, per US-1.3.2 §12). Layers 6/7/8/13 are entirely n/a.

**Feature status (verified in code + driven live 2026-07-24):**
- `Components.Spine.spineWidth/spineHeight/spineLean` implemented
  (`frontend/src/Components/Spine.elm:57-85`); `book/1` renders the full 3D
  structure + per-book `aria-label` (`Spine.elm:170-336`).
- Default page-count fallback lives in `Page.Bookshelf.Helpers`
  (`Maybe.withDefault 200 (bookPageCount bk)`, `Helpers.elm:58,129`).
- Per-shelf wear config: `Page.Bookshelf.elm:68` (library=`Softened`),
  `:81`/`:94` (antilibrary/wishlist=`Pristine`); ReadingPile hardcodes
  `Softened` (`ReadingPile.elm:460`).
- Wear suffix reaches only the aria-label: `Softened` → `", well-loved"`,
  `Pristine` → none, composing with the owner-private `", hidden (only visible
  to you)"` suffix (`Spine.elm:264-277`).
- Server-side wear: `Shelving.spine_data/1` (`compute_wear_level` → move_count
  0 `:new`, 1-2 `:light`, 3-5 `:moderate`, 6+ `:heavy`, `shelving.ex:545-548`)
  and `Stacks.Workers.RecalculateWearJob`. **There is no
  `GET /api/spine_data/:placement_id` route** — `spine_data/1` is context-only;
  the Elm renderer never consumes its wear (decoupled from the static per-shelf
  `Pristine|Softened`).
- **De-scoped (not in this issue):** bookmark-ribbon / coloured tabs for books
  with user writing → **#287**; wear-specific CSS distinction (only the aria
  suffix exists) → **#288**. Both removed from Summary/User Stories scope; the
  aria-level wear assertion stays in-scope and is shipped.

---

### Framework-layer summary

| Framework   | US-1.3.1 | US-1.3.2 |
|-------------|----------|----------|
| Elixir      | ✅ (page_count value round-trips `GET /api/bookshelves/:name`; primary/first-edition read; nil when no editions) | ✅ (spine_data + RecalculateWearJob covered; all four `compute_wear_level` boundaries — 1/2→:light, 3/5→:moderate, 6→:heavy — asserted exactly) |
| Elm unit    | ✅ (spineWidth clamps + sloped mid-range + monotonicity; `bookPageCount → Nothing` ×2; rendered 35px floor via `viewShelfRow`) | ✅ (wear aria-suffix Pristine/Softened/Softened+hidden; per-shelf `Config.wearLevel`; ReadingPile rendered aria) |
| Elm program | n/a — `Components.Spine` is a stateless pure component; wear/width are set at config/render time, not via an update cycle. ReadingPile's rendered-aria assertion drives a real `ProgramTest`. | n/a — same |
| Python      | n/a — vision service not involved in spine rendering | n/a |
| E2E         | ✅ (`spine-rendering.spec.ts` — width across the clamp range, continuity, per-spine aria/roles, texture variety; no-page_count default is `n/a` at E2E — seed-unreachable, pinned at Elm) | ✅ (`spine-rendering.spec.ts` — wear-by-shelf via robust `", well-loved"` substring composing with the hidden suffix) |
| dbt         | n/a — proto-generated staging; Issue §9 declares dbt N/A | n/a — same |

**Test inventory (verified by grep/read 2026-07-24):**
- `apps/core/test/stacks/shelving_test.exs` — `spine_data/1`: wear_level `:new`
  for unread placement, `:light` at move_count 1 & 2, `:moderate` at 3 & 5,
  `:heavy` at 6 (boundaries asserted exactly via `seed_move_history/3`,
  `:736-806`); nil for unknown placement; formats from editions; page_count
  from primary edition; page_count fallback to first edition; empty formats
  when no editions; `page_count == nil` when book has no editions (`:898-907`).
- `apps/core/test/stacks/workers/recalculate_wear_job_test.exs` — 2 tests
  (`:ok` for existing placement, `{:cancel, ...}` for missing).
- `apps/core/test/stacks_web/proto_json_test.exs` — `edition/1` "all fields
  serialized" (`page_count: 450`) + "nil optional fields" (`page_count == nil`).
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — "propagates the
  primary edition's page_count value through the response" (`primary_edition
  ["page_count"] == 450`, `:274-290`) + "includes primary_edition when book has
  editions".
- `frontend/tests/SpineTest.elm` — `spineWidth` boundaries incl. 480→40, 540→45,
  660→55, 1000→55, and monotonicity (`spineWidth 480 < spineWidth 540`,
  `:43-62`).
- `frontend/tests/SpineBookTest.elm` — `spineWidth`/`spineHeight`/`spineLean` +
  3D structure; wear aria-suffix (Pristine none / Softened ", well-loved" /
  Softened+hidden in order, `:272-290`); per-shelf `Config.wearLevel`
  (library=Softened, antilibrary/wishlist=Pristine) + ReadingPile rendered aria
  via `ProgramTest` (`:298-333`).
- `frontend/tests/BookDecoder.elm` — `bookPageCount → Nothing` for no primary
  edition and for a page_count-less edition (`:253-303`).
- `frontend/tests/BookcaseHelpersTest.elm` — rendered 35px floor via
  `viewShelfRow Softened` for a page-count-less book and a bookless placement
  (`:198-213`, fixtures `:223-227`).
- `e2e/tests/spine-rendering.spec.ts` — width across the clamp range (`:170`),
  continuity (`:218`), no-page_count default (`:255`, loud auto-activating
  skip), wear-by-shelf (`:291`), aria + list roles (`:374`), texture variety
  (`:406`). 7 pass / 1 justified skip.
- `e2e/tests/book-interaction.spec.ts` — "book spine shows texture background
  image", "book has 3D structure: spine, top, and cover faces" (incidental).
- `e2e/tests/bookshelf.spec.ts`, `reading-pile.spec.ts`, `assets.spec.ts` —
  role=list/listitem, shelf-label aria, and 6 `/textures/spine-*.png` checks
  (incidental / asset availability).

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **11** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **41** |

52 cells total (13 layers × 2 US × happy/sad). **SHIPPED: 0 ❌ / 0 ⚠️** — the
audit is GREEN. All 12 punch-list items are resolved (item #8, the E2E
no-page_count default, resolved as `n/a` at the E2E layer — seed-unreachable —
and pinned at the Elm render layer; item #12, the bookmark ribbon, de-scoped to
**#287**).

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | `bookshelf_controller_test.exs:274-290` — "propagates the primary edition's page_count value through the response" seeds a `book_edition` with `page_count: 450` and asserts `placement["book"]["primary_edition"]["page_count"] == 450` through `GET /api/bookshelves/:name`; `proto_json_test.exs` — `edition/1` "all fields serialized" asserts serializer-level `page_count == 450`. The endpoint value round-trip is now covered. | ✅ | `proto_json_test.exs` — `edition/1` "nil optional fields" asserts `result.page_count == nil` (missing metadata serializes cleanly). | ✅ |
| 1.3.2 | n/a — the issue references `GET /api/spine_data/:placement_id`, but no such route exists in `core_web/router.ex`. `Shelving.spine_data/1` is context-only; its DB read is covered at Layer 3 and its job wrapper at Layer 5. | n/a | n/a — same. | n/a |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — spine rendering is a client-side view concern; `page_count` rides the already-guarded `/api/bookshelves/:name` endpoint whose auth is covered by the US-1.2.x bookshelf audit. | n/a — same. |
| 1.3.2 | n/a — no dedicated spine/wear endpoint to guard; wear is applied client-side from the shelf config. | n/a — same. |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | `shelving_test.exs` — "page_count comes from the primary edition" (`data.page_count == 450` from the `is_primary` edition) + "page_count falls back to first edition when no primary". Directly exercises the `op.book_editions` read that drives spine thickness. | ✅ | `shelving_test.exs:898-907` — "page_count is nil when book has no editions" asserts `data.page_count == nil` for a placement whose book has zero editions (the no-edition render-fallback source). | ✅ |
| 1.3.2 | `shelving_test.exs:736-806` — all four `compute_wear_level` boundaries asserted exactly via `seed_move_history/3`: move_count 1 & 2 → `:light`, 3 & 5 → `:moderate`, 6 → `:heavy` (plus the pre-existing `:new` at move_count 0). Threshold constants are pinned — any shift fails a boundary test. | ✅ | `shelving_test.exs` — "returns nil for unknown placement" (`Shelving.spine_data(Ecto.UUID.generate()) == nil`). | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — rendering emits no events (US-1.3.1 §6). Page count is read-only metadata. | n/a — same. |
| 1.3.2 | n/a — wear rendering emits nothing (US-1.3.2 §6); wear changes are a side effect of `placement.moved`, but the render itself triggers no event. | n/a — same. |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | n/a — no background job in the thickness path (US-1.3.1 §7). | n/a | n/a — same. | n/a |
| 1.3.2 | `recalculate_wear_job_test.exs` — "returns :ok for an existing placement_id" (drives `RecalculateWearJob` → `Shelving.spine_data/1`). | ✅ | `recalculate_wear_job_test.exs` — "returns {:cancel, reason} for a nonexistent placement_id". | ✅ |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — page count is populated at book-creation time from Open Library / Google Books (US-1.3.1 §8); no external call during render. | n/a — same. |
| 1.3.2 | n/a — no external service in the wear path (US-1.3.2 §8). | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — no storage operations during spine rendering (US-1.3.1 §9). Spine texture PNGs are static assets served from `/textures/`; their availability (not storage ops) is covered by `e2e/tests/assets.spec.ts`. | n/a — same. |
| 1.3.2 | n/a — no storage operations (US-1.3.2 §9). | n/a — same. |

#### Layer 8: Cache Interactions

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — spine data is not cached independently (Issue §8); page count rides the bookshelf response. | n/a — same. |
| 1.3.2 | n/a — wear is recomputed, not cached; the job logs but does not persist (US-1.3.2 §7 note). | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — Issue §9 declares dbt N/A ("reads from existing staging models... no specific dbt validation beyond #112"). `stg_book_editions` exposes `page_count` (`stg_book_editions.sql:10`, `schema.yml:88` description-only); the column is nullable by design, so no `accepted_values`/`not_null` assertion is warranted. Staging is proto-generated (`mix proto.sync`). | n/a — same. |
| 1.3.2 | n/a — `stg_bookshelf_placement_history` (proto-generated) supplies the move-count source; wear is derived in Elixir, not dbt. Issue §9 N/A. | n/a — same. |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | `SpineTest.elm:43-62` — `spineWidth` covers both clamps + the sloped mid-range: 480→40, 540→45, 660→55 (exact ceiling), 1000→55 (over-ceiling clamp), plus a **continuity/monotonicity** assertion (`spineWidth 480 < spineWidth 540`); `SpineBookTest.elm` — `spineWidth`/`spineHeight`/`spineLean` + 3D structure. Rendered-width proof: `BookcaseHelpersTest.elm:198-213` asserts the on-DOM `width:35px` floor via `viewShelfRow`. E2E: `spine-rendering.spec.ts:170,218` measures live `offsetWidth` across the clamp range (95→35, 480→40, 536→45, 576→48, 796→55) + continuity. | ✅ | `BookDecoder.elm:253-303` — `bookPageCount → Nothing` for a book with no primary edition and for a primary edition that omits `page_count`; `BookcaseHelpersTest.elm:198-213` proves the `Maybe.withDefault 200 (bookPageCount bk)` render-fallback (`Helpers.elm:58,129`) renders the 35px minimum for both a page-count-less book and a bookless placement. | ✅ |
| 1.3.2 | `SpineBookTest.elm:272-290` asserts the wear-dependent aria output exactly: `Pristine` → no suffix, `Softened` → `", well-loved"`, `Softened + hidden` → both suffixes in order; `:298-333` asserts per-shelf `Config.wearLevel` (library=`Softened`, antilibrary/wishlist=`Pristine`) directly and the ReadingPile's hardcoded `Softened` via its **rendered** aria-label through a `ProgramTest`. E2E: `spine-rendering.spec.ts:291` asserts wear-by-shelf live (`", well-loved"` present on Library+ReadingPile, absent on WishList+AntiLibrary), composing with the owner-private hidden suffix. | ✅ | n/a — wear is deterministic from the shelf config; US-1.3.2 §2 declares the sad path N/A (no failure mode). | n/a |

#### Layer 11: Operational Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — the `spine.page_count_missing` / `spine.width_distribution` metrics (US-1.3.1 §13) are informational client-side counters, not instrumented server-side; per-route latency is covered by the SLO gate (`scripts/check-slo-gate.sh`). | n/a — same. |
| 1.3.2 | n/a — `spine_data.query.*` metrics (US-1.3.2 §13) will only become active when per-book wear is wired to the frontend; Ecto telemetry is automatic, and per-US firing tests add no guarantee. | n/a — same. |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — covered by the SLO gate, not unit tests; in-test render-time SLA bounds (US-1.3.1 §14, p95 < 500µs/book) are an anti-pattern under variable CI timing. | n/a — same. |
| 1.3.2 | n/a — same rationale (US-1.3.2 §14). | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — spine thickness is a pure O(1) client-side calculation with no external API cost (US-1.3.1 §15); page count rides the bookshelf query already accounted in US-1.2.x. | n/a — same. |
| 1.3.2 | n/a — wear is currently client-side from shelf config; no per-call spend to record in `BudgetTracker` (US-1.3.2 §15). | n/a — same. |

---

### Punch list (SHIPPED — 12/12 resolved)

Every baseline ❌/⚠️ cell plus the E2E gaps, all resolved and cited against the
merged suites. Item #8 resolved as `n/a` at the E2E layer (seed-unreachable),
pinned at the Elm render layer; item #12 de-scoped to **#287**.

| # | Cell | Resolution (verified 2026-07-24) | Where |
|--:|------|-----------------------------------|-------|
| 1 | L1 US-1.3.1 happy | ✅ `page_count` value round-trips `GET /api/bookshelves/:name` — "propagates the primary edition's page_count value through the response" asserts `primary_edition["page_count"] == 450` | `bookshelf_controller_test.exs:274-290` |
| 2 | L3 US-1.3.1 sad | ✅ "page_count is nil when book has no editions" asserts `data.page_count == nil` | `shelving_test.exs:898-907` |
| 3 | L3 US-1.3.2 happy | ✅ All `compute_wear_level` boundaries seeded via `seed_move_history/3`: 1/2→:light, 3/5→:moderate, 6→:heavy (exact atoms) | `shelving_test.exs:736-806` |
| 4 | L10 US-1.3.1 happy | ✅ `spineWidth` 480→40, 540→45, 660→55, 1000→55 + monotonicity (480<540) | `SpineTest.elm:43-62` |
| 5 | L10 US-1.3.1 sad | ✅ `bookPageCount → Nothing` ×2 + rendered 35px floor via `viewShelfRow` (book-present-no-pages and bookless) | `BookDecoder.elm:253-303`, `BookcaseHelpersTest.elm:198-213` |
| 6 | L10 US-1.3.2 happy | ✅ Wear aria-suffix (Pristine/Softened/Softened+hidden in order) + per-shelf `Config.wearLevel` + ReadingPile rendered aria via `ProgramTest` | `SpineBookTest.elm:272-290,298-333` |
| 7 | E2E US-1.3.1 (L10) | ✅ Live `offsetWidth` across clamp range (95→35, 480→40, 536→45, 576→48, 796→55) + continuity | `spine-rendering.spec.ts:170,218` |
| 8 | E2E US-1.3.1 (L10) | **n/a at E2E — seed-unreachable** (all seeded editions carry `page_count`; the placement API cannot construct a null-page_count book). Pinned at the Elm render layer (`BookcaseHelpersTest.elm:198-213`); a **loud auto-activating skip** at `spine-rendering.spec.ts:255` activates the instant a null-page_count book is ever seeded | `spine-rendering.spec.ts:255` + `BookcaseHelpersTest.elm:198-213` |
| 9 | E2E US-1.3.2 (L10) | ✅ Wear-by-shelf via robust `", well-loved"` substring — present on Library+ReadingPile (Softened), absent on WishList+AntiLibrary (Pristine); composes with the hidden suffix | `spine-rendering.spec.ts:291` |
| 10 | E2E US-1.3.1/1.3.2 (L10) | ✅ Per-spine aria carries title + `"N pages"`; `role="listitem"` on the spine button, `role="list"` on `.shelf-row__books` | `spine-rendering.spec.ts:374` |
| 11 | E2E US-1.3.1 (L10) | ✅ ≥2 distinct `.book__spine` background textures across the shelf (observed 3 of 5) | `spine-rendering.spec.ts:406` |
| 12 | E2E US-1.3.2 (L10) — **DE-SCOPED** | Bookmark ribbon / coloured tabs — no such element in `Components.Spine`; spun out to **#287** (removed from this issue's scope). Visual wear CSS likewise de-scoped → **#288** | new issue **#287** (+ **#288**) |

---

### Verdict

**GREEN — audit resolved to the shipped state.** State across the
13-layer × 2-US matrix (52 cells):

- **11 ✅ STRONG** — Elixir page_count endpoint round-trip + DB read
  (US-1.3.1), no-edition nil page_count, all four `compute_wear_level`
  boundaries + unknown-placement nil guard + both `RecalculateWearJob`
  outcomes (US-1.3.2), the nil-page_count serializer path, and the full Elm
  render layer: `spineWidth` clamps/mid-range/monotonicity, `bookPageCount →
  Nothing` + 35px floor, and wear aria-suffix + per-shelf config.
- **0 ⚠️ / 0 ❌** — every baseline gap is closed or de-scoped.
- **41 n/a** — the entire server/data half of the stack (auth, events,
  external, storage, cache, dbt, metrics, perf, cost) is genuinely not
  applicable to a pure client-side rendering feature, plus the non-existent
  `spine_data` HTTP endpoint. One additional `n/a` is recorded *within* the
  resolved punch list (item #8, below) rather than as a matrix cell.

**Headline outcomes:**
1. **The Elm rendering layer — the heart of this feature — is now fully
   covered.** `spineWidth`/`spineHeight`/`spineLean` pure functions plus the
   two behaviours a user actually sees: the **default-200 fallback** (proven
   at the render layer via `viewShelfRow`, 35px floor) and **wear rendering**
   (the `", well-loved"` aria suffix and the per-shelf `Pristine`/`Softened`
   config, including composition with the owner-private hidden suffix).
2. **A dedicated E2E spine suite ships.** `e2e/tests/spine-rendering.spec.ts`
   (7 pass / 1 justified skip, driven live 2026-07-24) asserts width-by-page-
   count across the clamp range, continuity, wear-by-shelf, per-spine aria +
   list roles, and texture variety. Non-vacuity was proven by mutation
   (divisor 12→10 → exact expected failure; `Spine.elm` restored, diff clean)
   and `scripts/check-e2e-vacuous-guards.sh` is clean.
3. **The one E2E gap is honest, not hidden.** The no-page_count default
   (item #8) is `n/a` at E2E because it is seed-unreachable — every seeded
   edition carries a `page_count` and the placement API cannot construct a
   null one — so it is pinned at the Elm render layer and left as a loud
   auto-activating skip that fires the moment such a book is seeded. The
   bookmark-ribbon sub-feature is **de-scoped to #287**; visual wear CSS to
   **#288** (the aria-level wear assertion stays in-scope and is shipped).

**Test-runner totals at ship (spine-related, verified 2026-07-24):** Elixir
scoped run 139/0 (full suite 2862/0); Elm 999/0; Playwright
`spine-rendering.spec.ts` 7 pass / 1 justified skip. Punch list: **12 items,
all resolved** (#8 as `n/a`-with-pin, #12 de-scoped to #287).
## Definition of Done
- [x] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local` — Elixir scoped 139/0 (full 2862/0), Elm 999/0, Playwright `spine-rendering.spec.ts` 7 pass / 1 justified skip (2026-07-24)
- [x] No flaky tests — evidence: repeated independent green runs 2026-07-24 with zero intermittent failures: `just run mix test apps/core/test/stacks/shelving_test.exs apps/core/test/stacks_web/bookshelf_controller_test.exs` → `139 tests, 0 failures` (specialist run) and again 139/0 (elixir-reviewer re-run); `npx elm-test` → `999 passed, 0 failed` (specialist) and 69/0 on the four spine suites (elm-reviewer re-run); `npx playwright test spine-rendering.spec.ts --project=chromium` → `7 passed, 1 skipped` twice (pre- and post-proving-gate restore)
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — US-1.3.1 + US-1.3.2 built end-to-end and observed live 2026-07-24; the ribbon slice de-scoped → #287 and the visual wear CSS slice → #288 (Summary/User Stories edited, spin-out issues opened). No named story reaches GREEN via `n/a (see #NNN)`.
- [x] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all 12 punch-list items resolved; #8 as `n/a`-with-pin, #12 → #287). Regenerated 2026-07-24 to the shipped state.
- [x] `just verify` passes — green 2026-07-24; quiescent `just ci` green except the documented local `dockle` step

## Dependencies
- Seeded books with varying page counts and editions
- Seeded placements on multiple shelves
- Seeded placement history records for wear level testing
- `data-testid` attributes on spine elements (Issue #108)

## Agent Assignment
`elm-agent` for state machine / pure function tests, `playwright-agent` for visual rendering tests.

## Progress Notes
- 2026-07-23 — Epic kickoff (#115/#114/#113 on `feat/115-114-3-e2e`). Baseline re-verified: all major claims hold (no ribbon, no wear CSS, no spine_data route, wear branches untested, no spine-rendering.spec.ts). Corrections applied above: real wear thresholds are `:new/:light/:moderate/:heavy`; Elm wear is decoupled (static per-shelf `Pristine|Softened`). New since baseline: hidden/owner-only spine affordance (`book--hidden`, aria suffix ", hidden (only visible to you)", `Spine.elm:272-277`) — tests must compose with it. Seeds span page_count 95–796 (e.g. Dreamtigers=95, Lathe of Heaven=184, Left Hand=304, Republic=416, Crime and Punishment=671, Brothers Karamazov=796) covering the full width clamp. De-scoped: ribbon → #287, visual wear CSS → #288 (aria-level assertion stays in-scope).
- 2026-07-24 — Phase 1 (Elixir, test-only) complete. Punch #1 (page_count value round-trips `GET /api/bookshelves/:name`, asserts `primary_edition.page_count == 450`), #2 (`spine_data/1` `page_count == nil` for a book with no editions), #3 (`compute_wear_level` boundaries via seeded `PlacementHistory`: move_count 1/2→:light, 3/5→:moderate, 6→:heavy). Non-vacuity verified: nudging `n<=2`→`n<=1` fails the move_count-2 test, `n<=5`→`n<=4` fails the move_count-5 test; restored, `apps/core/lib/` diff clean. Scoped run green: 139 tests, 0 failures. No production changes.
- 2026-07-24 — Phase 3 (E2E) complete. New `e2e/tests/spine-rendering.spec.ts` (8 tests), driven live against local stack (STACKS_E2E_TEST_HELPERS, 169-book dev seed). Each test mints an isolated user (`POST /api/test/session`) and places books by page_count onto specific shelves; width read as `offsetWidth` on `.book` (`#spine-<id> [data-testid=book-spine]`). Punch #7: width == `max(35,min(55,round(pc/12)))` for Dreamtigers 95→35 (clamp-min), Queen Loana 480→40, Name of the Rose 536→45, Selected Non-Fictions 576→48, Brothers Karamazov 796→55 (clamp-max) + continuity (480<536 ⇒ strictly wider). Punch #9: wear-by-shelf via robust substring (`, well-loved` present on Library+ReadingPile/Softened, absent on WishList+AntiLibrary/Pristine) — composes with the owner-private `, hidden (only visible to you)` suffix that every minted placement carries; each negative anchored by a positive title match. Punch #10: aria-label carries title + "536 pages", `role=listitem` on the spine button, `role=list` on the `.shelf-row__books` container. Punch #11: ≥2 distinct `.book__spine` background textures across the shelf (observed 3 of 5). Punch #8 (no-page_count default): **SKIPPED + FLAGGED** — the dev seed populates page_count on all 200 editions (0 null) and the placement API cannot construct a null-page_count book, so the null→`Maybe.withDefault 200`→35px path is unreachable at E2E; it is proven at the Elm unit layer (`BookcaseHelpersTest.elm`, punch #5). The test searches the live catalogue and activates automatically if a null-page_count book is ever seeded. Non-vacuity gate: divisor 12→10 in `Spine.elm` (watcher rebuilt assets) made the width test fail (Queen Loana 48px vs expected 40px); restored exactly (`git diff` clean), rebuilt, suite green (7 passed, 1 skipped). `scripts/check-e2e-vacuous-guards.sh` clean. Live-drive observed: Dreamtigers 35px, Queen Loana 40px, Name of the Rose 45px, Brothers Karamazov 55px; aria "Book: The Name of the Rose by Umberto Eco, 536 pages, well-loved, hidden (only visible to you)".
- 2026-07-24 — Phase 2 (Elm, tests-only) complete. Punch #4: added `spineWidth` points 480→40/540→45/660→55/1000→55 + monotonicity (480<540) in `SpineTest.elm`. Punch #5: `bookPageCount → Nothing` for missing primary edition and page-count-less edition in `BookDecoder.elm`; the `Maybe.withDefault 200` render fallback → 35px floor (book-present and book-absent branches) via `viewShelfRow` in `BookcaseHelpersTest.elm`. Punch #6: wear aria-suffix (Pristine none / Softened ", well-loved" / Softened+hidden composes both in order) + per-shelf config (library=Softened, antilibrary=Pristine, wishlist=Pristine via `Config` records; ReadingPile=Softened via rendered aria-label through the page) in `SpineBookTest.elm`. No production changes. Full suite: 999 passed, 0 failed; elm-format + elm-review clean.
