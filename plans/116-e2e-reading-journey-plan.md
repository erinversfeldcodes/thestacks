# Plan: E2E Test Suite — Reading Journey
**Issue**: #116
**Created**: 2026-07-22
**Status**: Approved (Option A, human-approved 2026-07-22)

## Context
Issue #116 validates the reading-journey lifecycle (US-1.6.1–US-1.6.6): move, abandon, re-read,
remove, empty states, and reading progress. Planning research re-baselined the 2026-07-08 embedded
audit against current code (#112, #192, #276 all landed since) and live-drove every story. Two
named stories are 🟡 partial and are **built/fixed in-scope** per the approved Option A; the rest
of the issue is test hardening to turn the audit GREEN.

## Research Summary
- **Blocking bug (live-drive discovery):** `Shelving.move_book/3` (`shelving.ex:278`) updates
  `bookshelf_id` but never reassigns `shelf_id`. Since #151, browse (`get_bookshelf_shelves/2`,
  `shelving.ex:819`) lists placements via the physical shelf, so a moved book stays on the SOURCE
  bookshelf's browse and never appears on the TARGET. Confirmed via code, DB rows, and both browse
  APIs. The existing `shelf-actions.spec.ts` move test asserts only overlay text — vacuous w.r.t.
  listings. Breaks US-1.6.1/US-1.6.2 happy paths.
- **US-1.6.6:** backend fully built + tested (route/controller/context/changeset/events/stamps);
  frontend orphaned: `Components.PlacementCard` complete but mounted nowhere; no
  `Api.updateProgress`; `placement.reading_started/completed` unregistered in `Events.Registry`;
  **no page-count ceiling** (live drive: page 999999 accepted on a 112-page book).
- **Punch-list delta (18 baseline items):** #18 RESOLVED by #112 (empty-state assertions now
  unguarded against the zero-placement `empty-shelves` suite user). PARTIAL: #6/#7 (#276 delivered
  real Multi-abort rollback tests; remaining: `remove_book` rollback, books-survive,
  `history.to_bookshelf` happy-path), #9–#12 (payload SHAPE now enforced framework-wide by
  `Stacks.Events.PayloadContract` + emit-time validate + coverage test → those halves become
  `n/a (PayloadContract)`; remaining: audit-log positive assertions + event isolation), #16
  (`BookDetailMoveErrorTest.elm` covers MoveCompleted-Err; remaining: RemoveCompleted-Err +
  no-op guards). OPEN: #1–#5, #8, #13–#15, #17. Code gaps #5/#8 (`reread_book/1` no ownership
  check, `Repo.get!` raises) unchanged.
- **New enablers:** `mintSession`/`injectSession` (#192) for isolated destructive E2E users;
  `reading-pile-limit.spec.ts` as the template; typed `Api.MoveError` path (#276) as the Elm
  error-surfacing template.
- **Canonical-surface reconciliation:** no competing implementation of the reading-journey
  surface; `shelf-transitions.spec.ts` is US-1.2.5 navigation animation (a decoy — not counted).

## Approach Options
- **Option A (chosen, approved):** fix the shelf_id move bug in-scope (Phase 1) and build the
  US-1.6.6 frontend in-scope (Phase 2). Both are named-story blockers under the
  Feature-Completeness gate; both touch the files the tests target.
- **Option B:** spin the shelf_id bug into its own issue blocking #116 — cleaner bookkeeping,
  splits the same code across branches for no delivery gain. Not chosen.
- **Option C:** de-scope US-1.6.6 into a feature issue — reverses the issue's explicit 2026-07
  scope decision. Not chosen.

## Scope Lock
Approved scope = Phases 1–7 below. New discoveries become new issues. Known deferred-out items
(pre-approved as out of scope): `DbtRunner` dev `dbt_dir` path defect (pre-existing, unrelated);
specific full-pile copy on the `Api.placeBook` path (follow-up from #276).

## Phases

### Phase 1: Shelving fixes — move shelf_id + reread hardening
**Objective**: A moved book lands on a physical shelf of the destination bookshelf (browse
correct both sides); `reread_book` verifies ownership and returns `{:error, :not_found}`.
**Agent(s)**: elixir-agent
**Steps**:
1. TESTS FIRST: browse-visibility tests for move (target shows book, source doesn't — through
   `get_bookshelf_shelves/2`), shelf_id-reassignment unit tests, reread ownership/not_found tests.
2. `move_book/3`: reassign `shelf_id` mirroring how placement creation assigns shelves in the
   destination bookshelf (get-or-create default shelf); inside the existing Multi.
3. `reread_book/1` → `reread_book/2` (user_id) with ownership check; replace `Repo.get!` with
   `{:error, :not_found}`; update callers/tests.
**Test Command**: `just run mix test apps/core/test/stacks/shelving_test.exs apps/core/test/stacks_web/bookshelf_placement_controller_test.exs apps/core/test/stacks_web/bookshelf_controller_test.exs`
**Proving gate**: live drive — move a book via API on a minted user; `GET /api/bookshelves/<target>`
lists it, `<source>` doesn't (the exact observation that failed in planning).
**DoD Items**: punch #5, #8; the shelf_id defect fixed with browse-level regression tests.

### Phase 2: US-1.6.6 frontend build — reading progress UI
**Objective**: US-1.6.6 happy path built end-to-end and driveable live.
**Agent(s)**: elm-agent (+ elixir-agent for ceiling/registry)
**Steps** (design per `docs/user_stories/US-1.6.6-reading-progress.md` §2/§12):
1. TESTS FIRST (elm-test program tests + ExUnit for ceiling).
2. `Api.updateProgress` (PUT /api/placements/:id/progress) + decoder.
3. Mount `Components.PlacementCard` in `Page.Bookshelf.ReadingPile` and `Page.BookDetail`
   (readable bookshelves: reading_pile, library); host pages handle `ProgressUpdateRequested`
   OutMsg → API call → fold result into placement.
4. Page-count ceiling: changeset validates `current_page <= edition page count` where known
   (elixir; decide the unknown-page-count behaviour and record it).
5. Register `placement.reading_started`/`reading_completed` in `Events.Registry` with a decided
   handler set (likely DbtRefreshHandler for completed; record the decision either way).
6. "Finished → record this read?" bridge prompt toward US-1.6.3 (move to library).
**Test Command**: `npx elm-test` (frontend), targeted ExUnit files
**Proving gate**: live drive — set progress from the Reading Pile card in the browser; badge +
`p. X/Y` persist across reload; finishing surfaces the bridge prompt.
**DoD Items**: US-1.6.6 Pre-Check row → ✅; ceiling + registration DoD additions.

### Phase 3: Elixir test hardening (punch remainder)
**Objective**: Close #1–#4, #6/#7 remainder, #9–#12 remainder.
**Agent(s)**: elixir-agent
**Steps**: move sad paths (404/invalid-name/all-5-targets/same-shelf), abandon-via-move API test,
reread sequence test (or endpoint decision — default: sequence test, `reread_book` stays
context-only), delete idempotency, `remove_book` rollback + `op.books`-survives +
`history.to_bookshelf` happy-path, audit-log POSITIVE assertions for moved/removed/reread,
event-isolation assertions. Document `placement.reread` orphan status.
**Test Command**: targeted ExUnit files
**Proving gate**: each new test demonstrated to fail when its guarded behaviour is broken
(spot-check at review).

### Phase 4: Elm state-machine tests (punch #15/#16 remainder)
**Objective**: Confirm-happy + remaining sad/no-op coverage in `Page.BookDetail`.
**Agent(s)**: elm-agent
**Steps**: `MoveCompleted (Ok)` → currentBookshelf + mover closes; `ConfirmRemove` →
`RemoveCompleted (Ok)` → `NavigateTo previousRoute`; `RemoveCompleted (Err)` message;
no-op guards (placement/token Nothing) for both confirms. Reuse `BookDetailMoveErrorTest` harness.
**Test Command**: `npx elm-test`

### Phase 5: E2E reading-journey specs (punch #17 + regression + progress)
**Objective**: The journeys driven in a real browser against a live stack, minted isolated users.
**Agent(s)**: testing-coordinator/playwright via elixir/elm-agent support
**Steps**: abandon (reading_pile→antilibrary) with browse assertions; full journey
WishList→AntiLibrary→ReadingPile→Library asserting PlacementHistory; reread round-trip;
move-browse presence/absence regression (Phase 1's bug); US-1.6.6 progress journey.
**Test Command**: `npx playwright test --project=chromium <new specs>` against local stack
**Proving gate**: full targeted run green locally; then the deploy-preview E2E gate (2B-iii) on
the phase's completion.

### Phase 6: dbt (punch #13/#14)
**Objective**: History-model integrity + removal reflection covered.
**Agent(s)**: database-agent
**Steps**: relationships tests for `stg_bookshelf_placement_history` (via proto manifest /
`mix proto.sync` or singular tests — schema.yml is generated); `removed_at` exclusion test;
decide + record `placement.removed` → DbtRefreshHandler registration.
**Test Command**: `scripts/test-dbt.sh`, `scripts/lint-dbt.sh`

### Phase 7: Audit regeneration + completion
**Objective**: Issue exit per the Completion Bar.
**Agent(s)**: orchestrator + testing-coordinator
**Steps**: regenerate the embedded audit (PayloadContract cells `n/a` with rationale; #112-resolved
cells updated), update Pre-Check to shipped reality, run `completion-audit` skill, `just run just ci`
on the branch, 2F PE gate over the cumulative diff.

### Parallel Execution
**Independent after Phase 1**: Phases 3, 4, 6. Phase 2 independent of 3/4/6. Phase 5 depends on
Phases 1+2. Merge order: smallest-first within a level. NOTE: worktrees are avoided this epic —
they branch from origin/main which lacks this branch's commits (project memory) — so parallel
phases run sequentially-committed in the main tree instead.

## Open Questions
None blocking. In-phase decisions to record: unknown-page-count ceiling behaviour (P2),
reading-event handler set (P2), reread endpoint vs sequence-test (P3, default sequence test),
`placement.removed`→dbt decision (P6).

## Integration Handoffs
- P1→P5: the browse-assertion pattern (target/source) becomes the E2E regression spec.
- P2→P5: PlacementCard testids drive the progress E2E.
- P2 elixir ceiling → P3 test files (same suite, coordinate to avoid churn).
- gdpr-review lens runs at review on P2 (events/endpoint surface) and P6 (dbt) — expected
  n/a-with-rationale; state it, don't skip it.
