# Plan: E2E Test Suite — Search
**Issue**: #115
**Created**: 2026-07-23
**Status**: Approved (epic kickoff 2026-07-23)

## Context
Harden search test coverage for US-1.5.1 (title search) after de-scoping US-1.5.2 → #284 and US-1.5.3 sectioning → #285/#286. Includes the approved in-scope bug fix: `Api.elm:787` calls `GET /api/books/search`, but the only route is `GET /api/search` — live SPA book search 404s today, masked by the fail-open OR-assertion at `e2e/tests/search.spec.ts:50-57`.

## Research Summary
Re-verified 2026-07-23: path mismatch live; controller has 9 tests (no multi-word/injection/long-query); `search_books/2` has 2 shallow tests (no tsv-population/GIN/multi-word); `SearchProgramTest.elm` has 8 tests incl. 4 `readers_*` (#217 people-search — do not break); missing init-state/SortChanged/year-filter/stale-debounce/Failure-branch/no-token coverage; sort+filters are client-side only; visibility filtering happens in the CONTROLLER (`search_controller.ex:16`), not the context.

## Approach Options
- **Option A (chosen):** Fix the client path in `Api.elm` (route stays `/api/search`, matching `/api/search/users`). — Minimal diff, consistent route namespace. Recommended.
- **Option B:** Add an `/api/books/search` route alias. — Duplicates surface, two routes to guard/test. Not recommended.

## Phases

### Phase 1: Elm — path fix + program-test hardening
**Objective**: Fix `Api.searchBooks` to call `/api/search` (test-first) and close the Elm coverage gaps.
**Agent(s)**: elm-agent
**Steps**:
1. Test-first: add a `SearchProgramTest` case asserting the search request goes to `/api/search` (fails against current `/api/books/search`).
2. Fix `Api.elm:787` (`["api","books","search"]` → `["api","search"]`).
3. Add program tests: init state (query="", results=NotAsked, no init call), `SortChanged` (re-order across the 4 SortOrder variants), `YearFromChanged`/`YearToChanged`/`ClearFilters`, stale-debounce no-op, `SearchCompleted (Err _)` → "Search failed. Please try again.", no-token (book search stays NotAsked; readers section unaffected).
**Test Command**: `just run` elm-test (frontend)
**Proving gate**: elm-test green including the URL assertion that failed pre-fix; live drive in Phase 3 confirms real results render on `/search`.
**DoD Items**: Elm punch items #4, #5 + the path fix (audit punch #6's client half).

### Phase 2: Elixir — controller + context hardening
**Objective**: Close the API/DB layer gaps.
**Agent(s)**: elixir-agent
**Steps**:
1. `search_controller_test.exs`: multi-word query (plainto_tsquery tokenisation), special-char/SQL-injection safety (sanitiser `books.ex:696`), very-long-query.
2. `books_test.exs`: `title_tsv` populated on book creation; GIN index used (EXPLAIN-based assertion); context-level multi-word match.
**Test Command**: `just run mix test` (scoped files)
**Proving gate**: new tests fail if the sanitiser/tsv mechanism is removed (non-vacuous — TC verifies).
**DoD Items**: audit punch items #1, #2, #3.

### Phase 3: E2E — deterministic search spec
**Objective**: Replace the vacuous spec with deterministic assertions against the fixed wire.
**Agent(s)**: testing-coordinator (Playwright)
**Steps**:
1. Delete the fail-open OR-assertion (`search.spec.ts:50-57`); replace with: seeded query → results render title + author + year in `.search-results` (deterministic, seed-backed via `assertSeedOrSkip` pattern).
2. Add empty-state ("No books found…") and error-state (mock 500 → "Search failed…") tests; keep readers-section (#217) untouched.
**Test Command**: `cd e2e && npx playwright test search.spec.ts --project=chromium` against local stack (`scripts/test-e2e.sh` env incl. `STACKS_E2E_TEST_HELPERS=1`, rebuilt assets)
**Proving gate**: the results test FAILS when run against pre-fix code (proves it would have caught the 404) and passes post-fix; live drive of `/search` shows real seeded titles.
**DoD Items**: audit punch #6; kills the #275-class guard.

## Open Questions
None.

## Integration Handoffs
Phase 3 depends on Phase 1's path fix. Phases 1 and 2 are file-disjoint and run in parallel on the integration tree. Final step: regenerate the embedded Test Audit + Pre-Check with live-drive evidence.
