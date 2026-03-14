# Plan: elm-program-test User Journey Coverage
**Issue**: #011
**Created**: 2026-03-14
**Status**: Approved

## Context
Issue #002 (Elm MVP frontend) is merged. Every page has `update`/`view` functions but no program-level tests that simulate user interactions against the real virtual DOM. Adding `avh4/elm-program-test` now — before subsequent frontend issues land — keeps the test surface small and establishes patterns for future work.

## Research Summary
- 10 existing test files use `elm-explorations/test` for unit-level testing (decoders, model updates, ISBN validation)
- `UploadTest.elm` already tests `update` directly but doesn't use elm-program-test's simulated browser
- All pages follow consistent patterns: `init`/`update`/`view`, `RemoteData` for async state, `OutMsg` for cross-page communication
- Upload page has 6 `UploadResult` states and is the most complex test target
- Bookshelf pages (5 variants) share identical structure — testing Library covers all
- Search page has debounce, filter panel, and sort — straightforward program test targets
- No `TestHelpers.elm` exists yet

## Approach Options
- **Option A (chosen):** `avh4/elm-program-test` with per-page `ProgramTest.createElement` harnesses. Each page is wrapped in a minimal element program in `TestHelpers.elm`, simulating HTTP via `SimulatedEffect.Http`. Recommended — matches the issue specification and keeps tests focused.
- **Option B:** Test at the `Main.elm` application level using `ProgramTest.createApplication`. Not recommended — tests would be coupled to routing and page composition, making them fragile and slow to write.

## Phases

### Phase 1: Infrastructure Setup
**Objective**: Add elm-program-test dependency and create shared test helpers
**Agent(s)**: elm-agent
**Steps**:
1. Add `avh4/elm-program-test` to `frontend/elm.json` test dependencies
2. Run `cd frontend && npx elm-test install avh4/elm-program-test` to resolve transitive deps
3. Create `frontend/tests/TestHelpers.elm` with:
   - `SimulatedEffect` wrappers for `Api` HTTP calls (upload, poll, getBook, getBookshelf, searchBooks)
   - HTTP response builders for common responses (successful book, placement list, poll responses)
   - Per-page `ProgramTest.createElement` harness functions
4. Verify `npx elm-test` still passes with all existing tests
**Test Command**: `cd frontend && npx elm-test`
**DoD Items**:
- [ ] `avh4/elm-program-test` in elm.json test dependencies
- [ ] `TestHelpers.elm` compiles and existing tests pass

### Phase 2: Upload Page Program Tests
**Objective**: Cover the Upload page's 6 result states and user interaction flows
**Agent(s)**: elm-agent
**Steps**:
1. Create `frontend/tests/Page/UploadProgramTest.elm`
2. Implement 9 tests per the issue specification:
   - `upload_happy_path`: file → upload accepted → poll resolved → book identified → card renders
   - `upload_isbn_rejection`: poll rejected → rejection message
   - `upload_not_a_book`: poll resolved with no bookId → not-a-book message
   - `upload_poll_timeout`: 15 poll cycles → IdentificationFailed
   - `upload_duplicate_detected`: poll resolved with isDuplicate → duplicate card
   - `upload_manual_isbn_entry`: enter ISBN mode → input rendered → submit
   - `upload_manual_isbn_validation`: invalid ISBN → error message
   - `upload_reset`: "Try Again" → back to drop zone
   - `upload_drag_over`: DragOver → dragging class present
**Test Command**: `cd frontend && npx elm-test tests/Page/UploadProgramTest.elm`
**DoD Items**:
- [ ] All 9 upload program tests pass
- [ ] Tests use SimulatedEffect.Http, not real HTTP

### Phase 3: Bookshelf Page Program Tests
**Objective**: Cover bookshelf loading, rendering, empty/error states, and age gate
**Agent(s)**: elm-agent
**Steps**:
1. Create `frontend/tests/Page/BookshelfProgramTest.elm`
2. Implement 5 tests using Library as the representative bookshelf:
   - `bookshelf_loading_state`: init → loading indicator visible
   - `bookshelf_renders_placements`: BooksLoaded Ok → spine elements rendered
   - `bookshelf_empty_state`: BooksLoaded Ok [] → empty component visible
   - `bookshelf_error_state`: BooksLoaded Err → error message visible
   - `bookshelf_age_gate`: age-gated book → gate shown; dismiss → hidden
**Test Command**: `cd frontend && npx elm-test tests/Page/BookshelfProgramTest.elm`
**DoD Items**:
- [ ] All 5 bookshelf program tests pass

### Phase 4: Search + Navigation Program Tests
**Objective**: Cover search interactions and route-based page rendering
**Agent(s)**: elm-agent
**Steps**:
1. Create `frontend/tests/Page/SearchProgramTest.elm` with 4 tests:
   - `search_debounce`: query → debounce → results rendered
   - `search_clear`: query cleared → NotAsked state
   - `search_empty_results`: search returns [] → "No results" message
   - `search_filter_panel_toggle`: toggle filter panel visibility
2. Create `frontend/tests/NavigationProgramTest.elm` with 4 tests:
   - `navigate_to_upload`: /upload → PageUpload rendered
   - `navigate_to_library`: /bookshelves/library → PageLibrary rendered
   - `navigate_to_search`: /search → PageSearch rendered
   - `navigate_not_found`: unknown URL → PageNotFound rendered
**Test Command**: `cd frontend && npx elm-test tests/Page/SearchProgramTest.elm tests/NavigationProgramTest.elm`
**DoD Items**:
- [ ] All 4 search program tests pass
- [ ] All 4 navigation program tests pass

### Parallel Execution
**Independent phases**: 2, 3, 4 (all depend on Phase 1 but not on each other)
**Merge order**: Phase 1 first, then 2/3/4 in any order

## Open Questions
None.

## Integration Handoffs
- **Phase 1 → Phases 2/3/4**: `TestHelpers.elm` must export all harness functions and HTTP simulators before page tests can be written.
- No cross-agent handoffs — single agent (elm-agent) for all phases.
