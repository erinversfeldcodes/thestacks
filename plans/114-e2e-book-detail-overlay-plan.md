# Plan: E2E Test Suite — Book Detail Overlay
**Issue**: #114
**Created**: 2026-07-23
**Status**: In Progress (phases 1+2 launched 2026-07-24, overlapping #113's review-only tail — file-disjoint)

## Context
Close the remaining US-1.4.1 gaps. Six baseline punch items were already closed by intervening merges (see issue Progress Notes 2026-07-23). Approved in-scope builds: (a) Elm focus trap + focus-return for the overlay, (b) `BookDetailCache` hit/miss telemetry. Age-gate "Click Verify" line corrected to n/a (ADR-020 §2, #069).

## Research Summary
Re-verified 2026-07-23. Still open — Elixir: cache telemetry absent (`book_detail_cache.ex`), hidden-visibility→404, no-events-on-read, controller↔cache miss/hit, moved/removed event payload assertions (count-only today, `shelving_test.exs:136/465`). Elm: move-failure (`MoveCompleted (Err _)`) and `CloseOverlay`→`RequestCloseOverlay` OutMsg untested; focus trap NOT implemented (`BookDetail.elm:1294-1297` has only dialog semantics); Escape handled globally (`Main.elm:2381-2386`) — confirm it closes the overlay. E2E: no dismissal (X `:1307-1329`/backdrop `:1280-1289`/Escape), focus-return, focus-trap, move/remove-failure, 404/500, loading, or unauth-prompt tests; weak OR-assertion at `book-detail.spec.ts:38`.

## Approach Options
- **Option A (chosen):** Elm-native focus trap (Tab/Shift+Tab keydown handling within the overlay + `Browser.Dom.focus` for open/return). — No ports, testable in elm-test/program tests. Recommended.
- **Option B:** JS port-based trap. — Violates "no ports unless absolutely necessary". Not recommended.

## Phases

### Phase 1: Elm — focus trap build (test-first) + state-machine gaps
**Objective**: Implement the US-1.4.1 a11y contract and close Elm test gaps.
**Agent(s)**: elm-agent
**Steps**:
1. Test-first: program tests for focus-on-open (first focusable), Tab-cycle containment, Shift+Tab reverse, focus-return-to-trigger on close — failing against current code.
2. Implement the trap in `Page.BookDetail`/overlay view (keydown Tab handling, `Browser.Dom.focus`; focus-return via the triggering spine's id). Verify Escape: confirm the global `EscapePressed` (`Main.elm:2158,2381-2386`) dismisses the overlay; add the missing test.
3. Add: `MoveCompleted (Err _)` → "Failed to move book…" test; `CloseOverlay` → `RequestCloseOverlay` OutMsg test.
**Test Command**: `just run` elm-test
**Proving gate**: pre-implementation failing trap tests captured; post-implementation green; live keyboard drive in Phase 3.
**DoD Items**: audit punch #9 (remainder), #10; the focus-trap feature (kickoff-approved).

### Phase 2: Elixir — cache telemetry + controller/context gaps
**Objective**: Instrument the cache and close server-side test gaps.
**Agent(s)**: elixir-agent
**Steps**:
1. Test-first: telemetry firing test (pattern: `upload_telemetry_test.exs`) for `[:stacks, :book_detail_cache, :hit]`/`:miss` — failing; then add `:telemetry.execute` to `BookDetailCache.get/1` paths.
2. `book_controller_test.exs`: hidden-visibility→404; no-events-on-read (event_log count unchanged); controller↔cache integration (first GET miss→cached, second hit — assert via cache state / query count).
3. `shelving_test.exs`: extend moved/removed emit tests to assert payloads (`from_bookshelf`/`to_bookshelf`/`book_id`).
**Test Command**: `just run mix test` (scoped files)
**Proving gate**: telemetry test fails with instrumentation removed; GDPR lens: telemetry payload carries NO user identifiers (cache is keyed by book_id — keep it that way).
**DoD Items**: audit punch #1, #3, #4 (closed variant), #6, #16.

### Phase 3: E2E — dismissal/focus/error/unauth suite
**Objective**: The overlay's defining dismissal + a11y contract, end-to-end.
**Agent(s)**: testing-coordinator (Playwright)
**Steps**:
1. `book-detail.spec.ts`: close via X, backdrop, Escape (each reopens fresh); URL unchanged; focus returns to triggering spine; focus trap (Tab cycles inside, Shift+Tab reverses); loading state; 404/500 mocks → "Could not load this book…"; fix the weak OR-assertion at `:38`.
2. Unauthenticated: public book overlay shows "Sign In or Register", no Move/Remove/Add (use `mintSession`/no-auth context).
3. `shelf-actions.spec.ts`: move failure (mock 403/422) → "Failed to move book…"; remove failure → "Failed to remove book…".
**Test Command**: `cd e2e && npx playwright test book-detail.spec.ts shelf-actions.spec.ts --project=chromium` against local stack
**Proving gate**: focus-trap spec fails when the Phase-1 trap is reverted (run once against pre-trap build); live keyboard drive observed.
**DoD Items**: audit punch #11–#15.

## Open Questions
None — Escape behaviour is verified (not assumed) in Phase 1.

## Integration Handoffs
Phase 3 depends on Phase 1 (trap) for the focus specs; Phases 1 and 2 are file-disjoint (parallel). GDPR lens runs on the Phase 2 telemetry diff. Final step: regenerate embedded Test Audit + Pre-Check with live-drive evidence.
