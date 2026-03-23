# Issue #115: E2E Test Suite — Search

## Summary
Comprehensive end-to-end test coverage for search functionality, including debounced input, full-text search on `title_tsv`, sort/filter controls, empty/no-results states, result click opening the book detail overlay, and platform-wide search scope.

## User Stories Covered
- [US-1.5.1 — Search Across Shelves](../docs/user_stories/US-1.5.1-search-shelves.md)
- [US-1.5.2 — Full-Text Search Across Reviews and Descriptions](../docs/user_stories/US-1.5.2-fulltext-search.md)
- [US-1.5.3 — Platform-Wide Discovery Search](../docs/user_stories/US-1.5.3-platform-discovery.md)

## Scope Check
- Does this issue touch more than 3 controllers? No (SearchController only).
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all search).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Search Input and Debounce (US-1.5.1)
- Navigate to `/search` while authenticated
- Verify search bar with placeholder "Search by title, author, or ISBN..."
- Type a query; verify no API call fires immediately
- Wait 300ms; verify API call fires after debounce
- Type additional characters within 300ms; verify previous debounce cancelled, new one started
- Verify only the final debounced query triggers an API call

#### Search Results (US-1.5.1)
- Type a query matching seeded books; verify results list renders in `div.search-results`
- Verify each result shows: book title, author name, publication year
- Verify results are clickable
- Click a result; verify book detail overlay opens (US-1.4.1 integration)

#### Sort Controls (US-1.5.1)
- Verify sort selector present with options: Title, Author, Year, Date Added
- Change sort to Author; verify results re-ordered
- Change sort to Year; verify results re-ordered
- Verify default sort is by Title ascending

#### Filter Controls (US-1.5.1)
- Verify year range filter available
- Set year range; verify results filtered accordingly

#### Empty States (US-1.5.1)
- With empty query: verify "Enter a search term above to find books." message
- Search for non-existent term: verify "No books found matching your search." message

#### Error State
- Mock `GET /api/search?q=...` to return 500; verify "Search failed. Please try again."

#### Full-Text Deep Search (US-1.5.2 — current status)
- Note: Full-text search on descriptions/reviews is not yet implemented
- Verify current search searches `title_tsv` column via `plainto_tsquery`
- When deep search is implemented: verify "Deep search" toggle, snippet highlighting, "via deep search" labels

#### Platform-Wide Results (US-1.5.3 — current status)
- Current implementation: `Books.search_books/2` returns all visible books platform-wide (not scoped to user)
- Verify visibility rules enforced (hidden books excluded from results)
- When collection scoping is implemented: verify "Your Collection" vs "On the Platform" sections, contextual labels (marketplace, partner, public shelf)

#### Search Query Edge Cases
- Single word query: verify results returned (uses `plainto_tsquery`)
- Multi-word query: verify handled correctly (note: `to_tsquery` fails on multi-word; `plainto_tsquery` used)
- Special characters in query: verify no crash
- Very long query: verify handled gracefully

### 2. API Endpoint Tests

#### `GET /api/search?q=...`
- Authenticated with query: returns 200 with matching books
- Response shape: array of book objects with title, author, publication year
- Empty query: returns 200 with empty results (or 422)
- No matches: returns 200 with empty array
- Unauthenticated: returns 401
- Visibility filtering: hidden books excluded from results
- Full-text search: uses `plainto_tsquery('english', ?)` on `title_tsv`
- SQL injection safe: query parameter properly escaped

#### Search Query Performance
- Verify `title_tsv` GIN index used for full-text queries
- Verify response time within acceptable limits for large datasets

### 3. Database Assertion Tests

#### `op.books` — Full-Text Search
- `title_tsv` tsvector column populated correctly on book creation
- `plainto_tsquery('english', ?)` matches expected books
- GIN index on `title_tsv` exists and is used by query planner

#### Visibility Filtering
- `Visibility.resolve_visibility/2` applied to each result
- Books with `visibility_tier = "hidden"` excluded
- Age-gated books included in results but detail requires verification

### 4. Event Flow Tests

N/A — search is a read-only operation. No events emitted.

### 5. Background Job Tests

N/A — no background jobs triggered by search.

### 6. External Service Tests

N/A — search queries only the local database. No external services called.

### 7. Storage Tests

N/A — no storage operations during search.

### 8. Cache Tests

N/A — search results are not cached. Each search hits the database directly.

### 9. dbt Model Tests

N/A — search reads from `op.books` directly. No dbt models involved in the search query path.

### 10. Elm State Machine Tests

#### Page.Search Init
- `init maybeToken`: `query = ""`, `results = NotAsked`, `debounceCount = 0`
- No API call on init

#### Update Cycle
- `QueryChanged query` -> `query = query`, `debounceCount += 1`, starts 300ms debounce (`Process.sleep 300` then `DebounceExpired count`)
- `DebounceExpired count` with `count == model.debounceCount` and non-empty query -> fires `Api.searchBooks query token SearchCompleted`
- `DebounceExpired count` with `count /= model.debounceCount` -> no-op (stale debounce)
- `DebounceExpired count` with empty query -> no-op
- `SearchCompleted (Ok books)` -> `results = Success books`
- `SearchCompleted (Err err)` -> `results = Failure err`
- `SortChanged sortOption` -> re-sorts results locally or re-fetches
- Result click -> OutMsg `NavigateTo (BookDetail bookId)` -> opens overlay

#### RemoteData States
- `NotAsked`: "Enter a search term above to find books."
- `Loading`: search spinner
- `Success []`: "No books found matching your search."
- `Success books`: results list renders
- `Failure err`: "Search failed. Please try again."

#### No Token Behaviour
- With `maybeToken = Nothing`: debounce expiry does not fire API call

### 11. Metrics & Telemetry Tests

#### HTTP Metrics
- Search endpoint request count incremented on `GET /api/search`
- Search response latency tracked
- Status code distribution: 200, 401, 500

#### Database Metrics
- `ecto_query_duration` for search queries on `op.books`
- `ecto_query_count` incremented per search

## Dependencies
- Seeded books with titles for full-text search testing
- `title_tsv` column populated with tsvector data
- Playwright test harness with auth helpers
- `data-testid` attributes on search elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
