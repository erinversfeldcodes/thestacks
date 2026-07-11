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
| US-1.3.1 — Spine Thickness by Page Count | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.3.2 — Spine Wear by Engagement | ⬜ to verify | ⬜ to verify | ⬜ | — |

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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #113)

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

**Feature status (verified in code):**
- `Components.Spine.spineWidth/spineHeight/spineLean` implemented
  (`frontend/src/Components/Spine.elm:57-85`); `book/1` renders the full 3D
  structure + per-book `aria-label` (`Spine.elm:170-336`).
- Default page-count fallback lives in `Page.Bookshelf.Helpers`
  (`Maybe.withDefault 200 (bookPageCount bk)`, `Helpers.elm:58,129`).
- Per-shelf wear config: `Page.Bookshelf.elm:58` (library=`Softened`),
  `:69`/`:80` (antilibrary/wishlist=`Pristine`); ReadingPile hardcodes
  `Softened` (`ReadingPile.elm:216`).
- Server-side wear: `Shelving.spine_data/1` (`shelving.ex:401-433`,
  `compute_wear_level` → `:new/:light/:moderate/:heavy`) and
  `Stacks.Workers.RecalculateWearJob`. **There is no
  `GET /api/spine_data/:placement_id` route** — the issue references one, but
  `core_web/router.ex` has none; `spine_data/1` is context-only.
- **Not implemented:** bookmark-ribbon / coloured tabs for books with user
  writing (US-1.3.2 §"Books with User Writing") — no such element in
  `Spine.elm`; and wear-specific CSS distinction (only the aria suffix).

---

### Framework-layer summary

| Framework   | US-1.3.1 | US-1.3.2 |
|-------------|----------|----------|
| Elixir      | ✅ (page_count read from primary/first edition) | ⚠️ (spine_data + RecalculateWearJob covered, but only `compute_wear_level` `:new`/move_count-0 branch tested) |
| Elm unit    | ⚠️ (spineWidth/height/lean + 3D structure strong; default-200 fallback untested) | ❌ (no test asserts wear-dependent output or per-shelf config `WearLevel`) |
| Elm program | n/a — `Components.Spine` is a stateless pure component; no program/state machine | n/a — wear is set at config time, not via update cycle |
| Python      | n/a — vision service not involved in spine rendering | n/a |
| E2E         | ⚠️ (3D structure + texture bg + role=list/listitem covered; width-by-page-count + default absent) | ⚠️ (role=list/listitem covered; wear-by-shelf + per-spine aria-label content absent) |
| dbt         | n/a — proto-generated staging; Issue §9 declares dbt N/A | n/a — same |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks/shelving_test.exs` — `spine_data/1` describes:
  wear_level `:new` for unread placement, nil for unknown placement, formats
  from editions (×2), page_count from primary edition, page_count fallback to
  first edition, empty formats when no editions (8 tests total across the two
  `spine_data/1` describes).
- `apps/core/test/stacks/workers/recalculate_wear_job_test.exs` — 2 tests
  (`:ok` for existing placement, `{:cancel, ...}` for missing).
- `apps/core/test/stacks_web/proto_json_test.exs` — `edition/1` "all fields
  serialized" (`page_count: 450`) + "nil optional fields" (`page_count == nil`).
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — "includes book
  editions in placement response", "includes primary_edition when book has
  editions" (asserts `primary_edition.id`, not `page_count`).
- `frontend/tests/SpineTest.elm` — 8 `spineWidth` boundary tests.
- `frontend/tests/SpineBookTest.elm` — `spineWidth` (5) + `spineHeight` (5) +
  `spineLean` (4) + 3D-structure/faces/title-author/bands/texture-bg (9).
- `frontend/tests/BookDecoder.elm` — `bookPageCount b == Just 350` (×2).
- `frontend/tests/BookcaseHelpersTest.elm` — `viewShelfRow Softened` (asserts
  shelf-row structure only, not wear).
- `e2e/tests/book-interaction.spec.ts` — "book spine shows texture background
  image", "book has 3D structure: spine, top, and cover faces".
- `e2e/tests/bookshelf.spec.ts` — "Library bookshelf rows have role=list",
  "Library books have role=listitem", "Shelf labels have aria-label".
- `e2e/tests/reading-pile.spec.ts` — "book pile renders with role=list".
- `e2e/tests/assets.spec.ts` — 6 `/textures/spine-*.png` availability checks.

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **5** |
| ⚠️ shallow | **4** |
| ❌ missing | **2** |
| n/a (covered higher up / not applicable / by-design) | **41** |

52 cells total (13 layers × 2 US × happy/sad). This is the pre-implementation
baseline; Issue #113's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | `proto_json_test.exs` — `edition/1` "all fields serialized" asserts `page_count == 450`; `bookshelf_controller_test.exs` — "includes primary_edition when book has editions" wires the edition into the `/api/bookshelves/:name` response. BUT no test asserts the `page_count` **value** propagates through the endpoint JSON — the controller test only asserts `primary_edition["id"]`. | ⚠️ | `proto_json_test.exs` — `edition/1` "nil optional fields" asserts `result.page_count == nil` (missing metadata serializes cleanly). | ✅ |
| 1.3.2 | n/a — the issue references `GET /api/spine_data/:placement_id`, but no such route exists in `core_web/router.ex`. `Shelving.spine_data/1` is context-only; its DB read is covered at Layer 3 and its job wrapper at Layer 5. | n/a | n/a — same. | n/a |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.3.1 | n/a — spine rendering is a client-side view concern; `page_count` rides the already-guarded `/api/bookshelves/:name` endpoint whose auth is covered by the US-1.2.x bookshelf audit. | n/a — same. |
| 1.3.2 | n/a — no dedicated spine/wear endpoint to guard; wear is applied client-side from the shelf config. | n/a — same. |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.3.1 | `shelving_test.exs` — "page_count comes from the primary edition" (asserts `data.page_count == 450` from the `is_primary` edition) + "page_count falls back to first edition when no primary" (`== 320`). Directly exercises the `op.book_editions` read that drives spine thickness. | ✅ | `shelving_test.exs` — "formats is empty list when book has no editions" exercises the no-edition path, but asserts `data.formats == []` only; it does **not** assert `page_count` is nil when no edition exists. | ⚠️ |
| 1.3.2 | `shelving_test.exs` — "returns spine data with wear_level :new for unread placement" (`move_count == 0` → `:new`). BUT only the `:new` branch of `compute_wear_level` (`shelving.ex:430-433`) is tested — the `:light` (1-2), `:moderate` (3-5), and `:heavy` (6+) branches, which require seeded `PlacementHistory` rows, have zero coverage. | ⚠️ | `shelving_test.exs` — "returns nil for unknown placement" (`Shelving.spine_data(Ecto.UUID.generate()) == nil`). | ✅ |

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
| 1.3.1 | `SpineTest.elm` — 8 `spineWidth` tests (0→35, 200→35, 360→35, 420→35, 500→42, 600→50, 700→55, 9999→55) covering both clamps + mid-values; `SpineBookTest.elm` — `spineWidthNewFormula` (5) + `spineHeightBoundary` (5) + `spineLeanBoundary` (4) + 3D-structure assertions; `BookDecoder.elm` — `bookPageCount b == Just 350`. Core function is strongly covered. BUT the issue-enumerated points `spineWidth 480 = 40`, `540 = 45`, `660 = 55`, `1000 = 55` and the **continuity** assertion (480px book visibly thinner than 540px) are not asserted. | ⚠️ | The default-page-count fallback is untested. `bookPageCount` is only asserted for the **present** case (`Just 350`); no test covers `bookPageCount → Nothing`, and no test covers `Page.Bookshelf.Helpers`' `Maybe.withDefault 200 (bookPageCount bk)` (`Helpers.elm:58,129`) — i.e. a book with a missing edition rendering at the 35px minimum. Feature exists; test missing. | ❌ |
| 1.3.2 | Wear-dependent rendering is untested. `Components.Spine.book` is rendered with `Pristine` (`SpineBookTest` `sampleBook`), `Softened` (`sampleClothBook`), and `Softened` via `BookcaseHelpersTest` — but **no** test asserts the wear-dependent output: the `aria-label` suffix (`", well-loved"` for `Softened` vs `""` for `Pristine`, `Spine.elm:263-269`) or the per-shelf `config.wearLevel` values (`Bookshelf.elm:58/69/80`, `ReadingPile.elm:216`). Feature exists; test missing. | ❌ | n/a — wear is deterministic from the shelf config; US-1.3.2 §2 declares the sad path N/A (no failure mode). | n/a |

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

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item, plus the E2E gaps called out
in the framework-layer summary (Issue #113's primary deliverable is the
Playwright suite; E2E rendering maps into Layer 10). No tests were written or
modified during this audit (pre-implementation baseline). Many ❌ are
expected at baseline.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-1.3.1 happy | Assert `page_count` **value** round-trips through `GET /api/bookshelves/:name` (seed a `book_edition` with a known `page_count`, assert `placement["book"]["primary_edition"]["page_count"]`), not just serializer-level | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 2 | L3 US-1.3.1 sad | Assert `Shelving.spine_data/1` (and/or the bookshelf read) returns `page_count == nil` when the book has no editions / null page_count | `apps/core/test/stacks/shelving_test.exs` |
| 3 | L3 US-1.3.2 happy | Cover the untested `compute_wear_level` branches: seed `PlacementHistory` rows so `move_count` hits 1-2 (`:light`), 3-5 (`:moderate`), 6+ (`:heavy`) | `apps/core/test/stacks/shelving_test.exs` |
| 4 | L10 US-1.3.1 happy | Add `spineWidth` enumerated points `480 → 40`, `540 → 45`, `660 → 55`, `1000 → 55`, plus a continuity assertion (`spineWidth 480 < spineWidth 540`) | `frontend/tests/SpineTest.elm` |
| 5 | L10 US-1.3.1 sad | Test `bookPageCount` returns `Nothing` when the primary edition / page_count is absent, and that `Page.Bookshelf.Helpers` applies the 200 default (⇒ 35px min) | `frontend/tests/BookDecoder.elm` + a `Helpers`/spine render test |
| 6 | L10 US-1.3.2 happy | Assert wear-dependent output of `Components.Spine.book`: `aria-label` ends with `", well-loved"` for `Softened` and has no suffix for `Pristine`; assert per-shelf config `wearLevel` (library=`Softened`, antilibrary/wishlist=`Pristine`, ReadingPile=`Softened`) | `frontend/tests/SpineBookTest.elm` (+ a `Page.Bookshelf` config test) |
| 7 | E2E US-1.3.1 (L10) | Playwright: seed books with page counts 100/200/420/600/660/800, navigate to a shelf, assert rendered spine `width` px matches `max(35, min(55, round(pageCount/12)))` and varies continuously | `e2e/tests/` (new `spine-rendering.spec.ts`) |
| 8 | E2E US-1.3.1 (L10) | Playwright: a book with no `page_count` renders at the 35px default width | new `e2e/tests/spine-rendering.spec.ts` |
| 9 | E2E US-1.3.2 (L10) | Playwright: wear-by-shelf — WishList/AntiLibrary render `Pristine`, ReadingPile/Library render `Softened`; assert the visual/aria distinction between the two states | new `e2e/tests/spine-rendering.spec.ts` |
| 10 | E2E US-1.3.1/1.3.2 (L10) | Playwright: per-spine `aria-label` includes the book title, `"N pages"`, and the wear suffix (`", well-loved"` on Softened shelves); `role="listitem"` on the spine button. (Current e2e only covers `role="list"` container + `role="listitem"` on `.book-button` and shelf-label aria — not the spine's own aria-label content.) | `e2e/tests/bookshelf.spec.ts` or new `spine-rendering.spec.ts` |
| 11 | E2E US-1.3.1 (L10) | Playwright: spine texture classes/background-image vary between books (not all identical) — extends the existing single-book texture check in `book-interaction.spec.ts` | `e2e/tests/book-interaction.spec.ts` |
| 12 | E2E US-1.3.2 (L10) — **FEATURE GAP** | Bookmark ribbon / coloured tabs for a book with associated user writing. **Not implemented** — no such element in `Components.Spine.book`. Requires a source-code change (new spine sub-element keyed on "has writing") before a test can assert it; per scope-lock this likely becomes a new issue. | `frontend/src/Components/Spine.elm` + new test (new issue) |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 2-US matrix (52 cells):

- **5 ✅ STRONG** — Elixir page_count DB read (US-1.3.1), unknown-placement
  nil guard, and both `RecalculateWearJob` outcomes (US-1.3.2), plus the
  nil-page_count serializer path.
- **4 ⚠️ shallow** — page_count endpoint propagation (serializer-only),
  no-edition page_count assertion, `compute_wear_level` (only `:new`
  branch), and `spineWidth` (strong core, but issue-enumerated points +
  continuity missing).
- **2 ❌ missing** — the default-200 page-count fallback (US-1.3.1 sad) and
  all wear-dependent rendering / per-shelf config coverage (US-1.3.2 happy)
  in the Elm layer.
- **41 n/a** — the entire server/data half of the stack (auth, events,
  external, storage, cache, dbt, metrics, perf, cost) is genuinely not
  applicable to what is a pure client-side rendering feature, plus the
  non-existent `spine_data` HTTP endpoint.

**Headline findings:**
1. **The Elm rendering layer — the heart of this feature — is the weakest.**
   `spineWidth`/`spineHeight`/`spineLean` pure functions are well tested,
   but the two behaviours a user actually sees are unverified: the
   **default-200 fallback** for books with no page count, and **wear
   rendering** (the `", well-loved"` aria suffix and the per-shelf
   `Pristine`/`Softened` config) has zero assertions despite being fully
   implemented.
2. **There is no E2E spine suite.** Rendering is only touched incidentally
   (3D faces + one texture-bg check in `book-interaction.spec.ts`;
   role=list/listitem in `bookshelf.spec.ts`/`reading-pile.spec.ts`). None of
   Issue #113's flagship Playwright assertions — width-by-page-count,
   default width, wear-by-shelf, per-spine aria-label content, texture
   variety — exist yet.
3. **Server-side wear is decoupled and half-tested.** `Shelving.spine_data/1`
   + `RecalculateWearJob` exist and have basic tests, but no HTTP route wires
   them to the frontend, and only the `move_count == 0` (`:new`) branch of
   the four-level `compute_wear_level` is exercised. The bookmark-ribbon
   sub-feature (US-1.3.2) is **not implemented at all** and needs code before
   it can be tested.

**Test runner totals at baseline (spine-related):** Elixir ~12 tests
(`spine_data/1` describes + `RecalculateWearJob` + `edition/1` serializer),
Elm ~26 tests (`SpineTest` 8, `SpineBookTest` 19-ish incl. structure,
`BookDecoder` page_count), Playwright ~4 incidental (3D structure, texture
bg, role attributes) + 6 texture-asset checks. Punch list: **12 items**, of
which #12 (bookmark ribbon) is blocked on feature implementation.
## Definition of Done
- [ ] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] `just verify` passes

## Dependencies
- Seeded books with varying page counts and editions
- Seeded placements on multiple shelves
- Seeded placement history records for wear level testing
- `data-testid` attributes on spine elements (Issue #108)

## Agent Assignment
`elm-agent` for state machine / pure function tests, `playwright-agent` for visual rendering tests.

## Progress Notes
[Updated by agents during execution.]
