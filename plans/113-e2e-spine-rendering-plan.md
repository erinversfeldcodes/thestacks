# Plan: E2E Test Suite — Spine Rendering
**Issue**: #113
**Created**: 2026-07-23
**Status**: Approved (epic kickoff 2026-07-23) — starts after #115 completes (sequential epic order)

## Context
Close the spine-rendering coverage gaps for US-1.3.1 (thickness) and US-1.3.2 (wear, aria-level slice) after de-scoping the bookmark ribbon → #287 and visual wear CSS → #288. Issue text corrected: real wear thresholds are `:new/:light/:moderate/:heavy` (`shelving.ex:545-548`); no `spine_data` HTTP route exists; Elm wear (`Pristine|Softened`, static per-shelf config) is decoupled from backend wear.

## Research Summary
Re-verified 2026-07-23: no ribbon/wear-CSS; `SpineTest.elm` covers 8 width points but not 480/540/660/1000 or continuity; the 200-default fallback (`Helpers.elm:58,129,252`) has zero tests; wear branches `:light/:moderate/:heavy` untested; no page_count assertion through `GET /api/bookshelves/:name`; no `spine-rendering.spec.ts`; seeds span page_count 95–796 (full clamp range); new hidden/owner-only spine affordance (`Spine.elm:272-277`) must be composed with.

## Approach Options
- **Option A (chosen):** Assert wear at the aria level (", well-loved" suffix) in E2E; widths via computed style on seeded books. — Tests what exists; visual wear deferred to #288. Recommended.
- **Option B:** Build wear CSS now to make wear visually assertable. — Feature work inside a validation issue; rejected at kickoff (→ #288).

## Phases

### Phase 1: Elixir — wear branches + page_count propagation
**Objective**: Close the DB/API layer gaps.
**Agent(s)**: elixir-agent
**Steps**:
1. `shelving_test.exs` `spine_data/1`: seed `PlacementHistory` rows for move_count 1-2 → `:light`, 3-5 → `:moderate`, 6+ → `:heavy`; assert `page_count == nil` when book has no editions.
2. `bookshelf_controller_test.exs`: seed an edition with known `page_count`, assert the VALUE at `placement["book"]["primary_edition"]["page_count"]` in `GET /api/bookshelves/:name`.
**Test Command**: `just run mix test` (scoped files)
**Proving gate**: branch tests fail if `compute_wear_level` thresholds change (non-vacuous).
**DoD Items**: audit punch #1, #2, #3.

### Phase 2: Elm — width points, fallback, wear config
**Objective**: Close the Elm layer gaps.
**Agent(s)**: elm-agent
**Steps**:
1. `SpineTest.elm`: add `spineWidth` 480→40, 540→45, 660→55, 1000→55 + monotonicity (480 < 540).
2. `bookPageCount → Nothing` (missing edition/page_count) + the `Maybe.withDefault 200` fallback ⇒ 35px minimum (test via `Page.Bookshelf.Helpers` render or extracted helper).
3. `SpineBookTest.elm`: aria-label ends ", well-loved" iff `Softened`, no suffix for `Pristine` (compose with the hidden-suffix affordance); per-shelf config assertions (library=Softened, antilibrary/wishlist=Pristine, ReadingPile=Softened).
**Test Command**: `just run` elm-test
**Proving gate**: wear tests fail if `wearSuffix` (`Spine.elm:264-270`) or a shelf config flips.
**DoD Items**: audit punch #4, #5, #6.

### Phase 3: E2E — spine-rendering.spec.ts
**Objective**: The issue's flagship Playwright suite.
**Agent(s)**: testing-coordinator (Playwright)
**Steps**:
1. New `e2e/tests/spine-rendering.spec.ts`: seeded books (Dreamtigers=95, Lathe of Heaven=184, Left Hand=304, Republic=416, Crime and Punishment=671, Brothers Karamazov=796) → rendered spine width px == `max(35, min(55, round(pageCount/12)))`; continuity across two mid-range books.
2. Default width 35px for a no-page_count book (seed-dependent; add via test helper if no such seed exists — flag if a seed change is needed).
3. Wear-by-shelf: aria suffix present on Library/ReadingPile spines, absent on WishList/AntiLibrary.
4. Per-spine aria-label content (title, "N pages", suffix) + `role="listitem"`; texture background varies between books (extends `book-interaction.spec.ts` single-book check).
**Test Command**: `cd e2e && npx playwright test spine-rendering.spec.ts --project=chromium` against local stack
**Proving gate**: width assertions computed from live DOM `getBoundingClientRect`/computed style on the deployed-asset build — a formula change fails the spec.
**DoD Items**: audit punch #7, #8, #9, #10, #11 (#12 de-scoped → #287).

## Open Questions
Whether a seeded book with NULL page_count exists; if not, Phase 3 adds one via the placement helper (not seeds.exs — avoids triggering the preview seed path) or flags for a decision.

## Integration Handoffs
Phases 1 and 2 are file-disjoint (parallel); Phase 3 after both. Final step: regenerate embedded Test Audit + Pre-Check with live-drive evidence.
