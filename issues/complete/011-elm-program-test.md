# Issue #011: elm-program-test User Journey Coverage

## Summary

Add `avh4/elm-program-test` as a test dependency and write program-level tests for every user story implemented in Issue #002 (Elm MVP frontend). These tests run offline without a browser, execute in milliseconds, and catch regressions in `update` logic and view rendering before they reach Playwright or the browser.

## Why now

Issue #002 is merged. Every subsequent issue that touches Elm (Phase 2C, 3D, 4A, 4C) should have program tests alongside its changes. Retrofitting later means writing tests for a large surface area at once. The time to add the harness and seed tests is immediately after the first frontend lands.

## What elm-program-test provides

`elm-program-test` simulates user interactions against the real `update` and `view` functions. It does not render HTML to a browser — it operates on the virtual DOM. This means:

- Zero external dependencies (no browser, no HTTP server)
- Runs in `elm-test` alongside unit tests
- Simulates clicks, form input, navigation, and HTTP responses
- Asserts on rendered HTML text, element presence, and model state via `Html.Query`

What it **cannot** test: actual file upload (FileList API), drag-and-drop, CSS rendering, real HTTP. Those belong in Playwright (Issue #012).

## Setup

### 1. Add dependency to `frontend/elm.json`

```json
"test-dependencies": {
    "direct": {
        "avh4/elm-program-test": "4.0.0",
        "elm-explorations/test": "2.0.0"
    }
}
```

Run `elm-test install avh4/elm-program-test` from `frontend/`.

### 2. Test helper: `frontend/tests/TestHelpers.elm`

Provides a shared `SimulatedEffect` setup and HTTP response builders so each test file does not repeat boilerplate.

## Tests to write

### `frontend/tests/Page/UploadTest.elm`

Cover `Page.Upload` — the most complex page with 6 result states and a polling loop.

| Test | Scenario |
|------|----------|
| `upload_happy_path` | File selected → upload accepted → `StatusReceived Resolved` with bookId → `GotIdentifiedBook Ok` → confirmation card renders title/author |
| `upload_isbn_rejection` | File selected → `StatusReceived Rejected` → "Could Not Identify Book" message + "Try Another Photo" button visible |
| `upload_not_a_book` | File selected → `StatusReceived Resolved` with no bookId → "That Doesn't Look Like a Book" message |
| `upload_poll_timeout` | File selected → `CheckStatus` fires 15 times → `IdentificationFailed` state |
| `upload_duplicate_detected` | `StatusReceived Resolved` with `isDuplicate: True` → duplicate card renders book title + shelf selector |
| `upload_manual_isbn_entry` | "Enter ISBN manually" clicked → ISBN input rendered; valid ISBN submitted → `ManualISBNEntry` state |
| `upload_manual_isbn_validation` | Invalid ISBN submitted → error message rendered, state unchanged |
| `upload_reset` | "Try Again" clicked from any result state → page returns to drop zone |
| `upload_drag_over` | `DragOver` msg → `upload-area--dragging` class present in view |

### `frontend/tests/Page/BookshelfTest.elm`

Cover the shared bookshelf pattern (Library is representative; others follow identical structure).

| Test | Scenario |
|------|----------|
| `bookshelf_loading_state` | `init` → `BooksLoaded` not yet received → loading indicator visible |
| `bookshelf_renders_placements` | `BooksLoaded (Ok placements)` → spine elements rendered for each placement |
| `bookshelf_empty_state` | `BooksLoaded (Ok [])` → empty bookshelf component visible |
| `bookshelf_error_state` | `BooksLoaded (Err _)` → error message visible |
| `bookshelf_age_gate` | Age-gated book selected → age gate component shown; `DismissAgeGate` → hidden |

### `frontend/tests/Page/SearchTest.elm`

| Test | Scenario |
|------|----------|
| `search_debounce` | Query typed → `DebounceExpired` fires → `SearchCompleted` response → results rendered |
| `search_clear` | Query typed, then cleared → `NotAsked` state, no results shown |
| `search_empty_results` | `SearchCompleted (Ok [])` → "No results" message |
| `search_filter_panel_toggle` | Filter button clicked → filter panel visible; clicked again → hidden |

### `frontend/tests/NavigationTest.elm`

| Test | Scenario |
|------|----------|
| `navigate_to_upload` | `/upload` URL → `PageUpload` page rendered |
| `navigate_to_library` | `/bookshelves/library` URL → `PageLibrary` page rendered |
| `navigate_to_search` | `/search` URL → `PageSearch` page rendered |
| `navigate_not_found` | Unknown URL → `PageNotFound` rendered |

## Definition of Done

- [ ] `avh4/elm-program-test` added to `frontend/elm.json` test dependencies
- [ ] `frontend/tests/TestHelpers.elm` with shared HTTP simulation helpers
- [ ] `frontend/tests/Page/UploadTest.elm` — all 9 tests listed above pass
- [ ] `frontend/tests/Page/BookshelfTest.elm` — all 5 tests pass
- [ ] `frontend/tests/Page/SearchTest.elm` — all 4 tests pass
- [ ] `frontend/tests/NavigationTest.elm` — all 4 tests pass
- [ ] `scripts/test-elm.sh` runs `elm-test` (already does — no script change needed)
- [ ] `elm-format --validate` passes on all new test files
- [ ] All tests pass in CI (`just test-elm`)

## Dependencies

- Issue #002 complete (Elm MVP frontend merged) ✅

## Blocks

- Issue #012 (Playwright) — program tests must pass before browser tests are added; they share the same user story scope

## Agent Assignment

- **elm-agent** for all test code
- **Reviewer**: elm-agent reviewer pass (elm-format, elm-test, logic review)
