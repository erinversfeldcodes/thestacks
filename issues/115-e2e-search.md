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
| US-1.5.1 — Search Across Shelves | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.5.2 — Full-Text Search Across Reviews and Descriptions | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-1.5.3 — Platform-Wide Discovery Search | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #115)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
framework-wide mechanism test) and per-US repetition adds no guarantee, or
(c) the story-specific behaviour is **not implemented** (deferred code, not
a test gap). Each `n/a` carries a one-line rationale.

**Scope note:** Issue #115 covers three user stories:
- **US-1.5.1 — Search Across Bookshelves** (`docs/user_stories/US-1.5.1-search-shelves.md`)
- **US-1.5.2 — Full-Text Search Across Reviews and Descriptions** (`docs/user_stories/US-1.5.2-fulltext-search.md`)
- **US-1.5.3 — Platform-Wide Discovery Search** (`docs/user_stories/US-1.5.3-platform-discovery.md`)

The matrix is 13 layers × 3 US, with happy/sad columns per cell. The
assertion inventory is drawn from each US's §3–§13 plus Issue #115's "Test
Suites" section (Playwright / API / DB / Elm / metrics enumerations).

**Feature status (verified by reading source):**
- **US-1.5.1 is implemented.** `StacksWeb.SearchController.index/2`
  (`apps/core/lib/stacks_web/controllers/search_controller.ex`, route
  `GET /api/search`, `:authenticated` pipeline, router line 175) →
  `Stacks.Books.search_books/2` (`apps/core/lib/stacks/books.ex:522`,
  `title_tsv @@ plainto_tsquery('english', ?)` with a `~r/[^\w\s]/`
  sanitiser) → `Visibility.can_view?/2` filter → `ProtoJSON.search_book/1`.
  Frontend `Page.Search` + `Components.SearchBar` + `SortSelector` +
  `FilterPanel`; sort/year-filter are **client-side only** (the API takes
  only `q` + `limit`).
- **US-1.5.2 (deep search across descriptions/reviews, snippets, "via deep
  search" labels) is NOT implemented.** The backend searches `title_tsv`
  only; there is no `scope=deep`, no `description_tsv`, no `ts_headline`
  snippet generation, and no Elm "Deep search" toggle. This is a code gap,
  not a test gap — the story-specific cells are `n/a (not implemented)` and
  its current title-only behaviour is already covered under US-1.5.1.
- **US-1.5.3 (platform-wide discovery) is PARTIALLY implemented.**
  `search_books/2` already returns **all visible books platform-wide** (not
  scoped to the caller's collection), and visibility filtering is enforced —
  so the "visibility rules on all results" AC is met and tested. But the
  "Your Collection" vs "On the Platform" sectioning, marketplace/partner/
  other-user sources, and contextual labels are not implemented.
  `Books.search_platform/2` (`books.ex:614`) exists but backs
  `CatalogueController`, not `SearchController`, and does **not** actually
  filter by bookshelf/placement visibility (it `ilike`-scans all books).

**⚠️ Cross-cutting integration finding (path mismatch):** the Elm client
`Api.searchBooks` (`frontend/src/Api.elm:468`) issues
`GET /api/books/search?q=...`, but the backend route is `GET /api/search`
(router line 175 — there is no `/api/books/search` route). `SearchProgramTest`
mocks the client's URL and `search_controller_test.exs` hits the real route
directly, so **no layer's tests exercise the wire between them** — and the
Playwright suite is deliberately loose ("any response, incl. error state")
precisely because the live call 404s. Note: Issue #093 ("search-path
consistency") is about the Postgres `search_path`, NOT this API path, so this
mismatch is unresolved. Flagged as punch-list #6.

---

### Framework-layer summary

| Framework    | US-1.5.1 | US-1.5.2 | US-1.5.3 |
|--------------|----------|----------|----------|
| Elixir       | ⚠️ (9 controller + 2 `search_books/2` tests; gaps: multi-word/`plainto_tsquery` gotcha, special-char/injection sanitiser, `title_tsv`/GIN mechanism) | n/a — deep search not implemented | ⚠️ (3 `search_platform/2` tests + visibility filtering; placement/bookshelf-level platform scoping not implemented) |
| Elm unit     | ❌ — no `Page/SearchTest.elm`; only the program test exists | n/a — no deep-search UI | n/a — no platform-section UI |
| Elm program  | ⚠️ (`SearchProgramTest.elm`, 4 tests: debounce, clear, empty, filter toggle; gaps: init state, sort, year filters, stale-debounce, error state, no-token) | n/a — not implemented | n/a — not implemented |
| Python       | n/a — vision service not involved in search | n/a | n/a |
| E2E          | ⚠️ (`search.spec.ts`, 6 tests: render/hint/sort/filter/clear + one loose "any response"; no deterministic seeded result / empty / error assertion; masked by the path mismatch) | n/a — not implemented | n/a — not implemented |
| dbt          | n/a — search reads `op.books` directly, no dbt in the path | n/a | n/a — `mart_platform_searchable` exists + tested but backs `CatalogueController`, not search |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/search_controller_test.exs` — 9 tests
  (matching query, empty results, 422 missing `q`, valid limit, invalid
  limit, author info, 401 unauthenticated, + 2 visibility-filtering tests
  for age-gated books).
- `apps/core/test/stacks/books_test.exs` — `search_books/2` (2 tests:
  title match, empty on no-match) + `search_platform/2` (3 tests: matching
  query returns `{books, count}`, empty query returns catalogue slice,
  no-match returns `{[], 0}`).
- `frontend/tests/Page/SearchProgramTest.elm` — 4 program tests
  (`search_debounce`, `search_clear`, `search_empty_results`,
  `search_filter_panel_toggle`).
- `e2e/tests/search.spec.ts` — 6 Playwright tests.
- `dbt/models/marts/mart_platform_searchable.sql` + `schema.yml` — generic
  column tests (`not_null`/`unique`/`relationships` on `book_id`,
  `not_null` on `title` + `last_refreshed_at`) — consumed by catalogue.
- `apps/core/test/stacks/books/title_search_cache_test.exs` (+`_persistent`)
  — **NOT part of this feature**: this is the ISBN-resolution memo for the
  upload path (title→ISBN against Open Library), unrelated to `GET /api/search`.

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **6** |
| ⚠️ shallow | **8** |
| ❌ missing | **0** |
| n/a (covered higher / not applicable / not implemented) | **64** |

78 cells total (13 layers × 3 US × happy/sad). This is the pre-implementation
baseline. Issue #115's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands — noting that US-1.5.2 (deep search) and the
US-1.5.3 sectioning/multi-source behaviour are **code gaps** that, per the
scope-lock rule, become new issues rather than tests written under #115.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ✅ search_controller_test.exs — "returns matching books for query" (asserts `query` echo + title membership), "returns author info when book has an associated author" (nested `author.name`), "respects a valid limit parameter". Response shape (`{query, count, results}`) exercised. | ✅ | ⚠️ search_controller_test.exs — "returns empty results for non-matching query" (200 + `count:0` + `results:[]`), "returns 422 when q param missing", "ignores invalid limit and defaults to 20". **Missing (Issue §"Search Query Edge Cases"/§API):** no multi-word query test (the `to_tsquery` gotcha — code uses `plainto_tsquery`, which *does* handle multi-word, but nothing asserts it), no special-character / SQL-injection-safety test on the `~r/[^\w\s]/` sanitiser, no very-long-query test. | ⚠️ |
| 1.5.2 | n/a — deep search (descriptions/reviews, `scope=deep`, `ts_headline` snippets) not implemented; the current title-only endpoint is covered under US-1.5.1. | n/a | n/a — same; deep-search error paths do not exist yet. | n/a |
| 1.5.3 | ⚠️ Platform-wide book results ARE the current behaviour (`search_books/2` returns all visible books, not user-scoped) and are exercised by the US-1.5.1 happy tests. BUT the US-1.5.3-specific multi-source discovery (marketplace listings, partner inventory, other users' public bookshelves, events) and "Your Collection"/"On the Platform" sectioning are **not implemented** — no endpoint returns them. | ⚠️ | ✅ Visibility enforcement (the load-bearing US-1.5.3 AC "visibility rules enforced on all results") is tested: search_controller_test.exs — "excludes age_gated books from results for non-age-verified user" and "includes age_gated books … for age-verified user". | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ✅ search_controller_test.exs — every describe uses an authenticated conn (`Guardian.encode_and_sign` Bearer token in `setup`), exercising the `:authenticated` pipeline; visibility guard covered by the two age-gated tests. | ✅ | ✅ search_controller_test.exs — "returns 401 without authentication" (bare `build_conn()`). | ✅ |
| 1.5.2 | n/a — same pipeline as US-1.5.1; no deep-search-specific guard. | n/a | n/a | n/a |
| 1.5.3 | ✅ Same `:authenticated` pipeline + `build_viewer/1` → `Visibility.can_view?/2` filtering, tested via the age-gated visibility cases (viewer identity drives result set). | ✅ | ✅ 401 path shared with US-1.5.1 ("returns 401 without authentication"). | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ⚠️ books_test.exs — `search_books/2` "returns books matching title query" (title match, non-match excluded). BUT Issue §3 DB-assertion requirements are unmet: no test that `title_tsv` is **populated** on book creation, and no test that the **GIN index** on `title_tsv` is used by the planner (no `EXPLAIN`/index-usage assertion). The tsvector mechanism itself is trusted, not asserted. | ⚠️ | ⚠️ books_test.exs — `search_books/2` "returns empty list when no match". BUT the **known `to_tsquery` gotcha is untested**: no test drives a multi-word query (e.g. `"elixir action"`) through `plainto_tsquery` to prove multi-word input is tokenised correctly rather than failing (existing tests all use single words by convention). | ⚠️ |
| 1.5.2 | n/a — `description_tsv`/review-summary columns and their indexes do not exist. | n/a | n/a | n/a |
| 1.5.3 | ⚠️ books_test.exs — `search_platform/2` "returns {books, count} tuple for a matching query" and "returns catalogue for empty query" (this is the `CatalogueController` path, adjacent to search). BUT: (a) the test inserts a `platform`-visibility bookshelf + placement, yet `search_platform/2` never joins `op.bookshelf_placements`/`op.bookshelves` — placement/bookshelf-level platform-visibility scoping (US-1.5.3 §5) is **not implemented**, so the placement in the fixture is inert; (b) the actual search path (`SearchController`) enforces only book-level `can_view?`. | ⚠️ | ⚠️ books_test.exs — `search_platform/2` "returns {[], 0} when query matches nothing". Same caveat: no placement/bookshelf-visibility exclusion asserted because it isn't implemented. | ⚠️ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — search is read-only; emits no events (US §6). | n/a |
| 1.5.2 | n/a — read-only. | n/a |
| 1.5.3 | n/a — read-only. | n/a |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — no jobs triggered by search (US §7). | n/a |
| 1.5.2 | n/a — review-summary enrichment jobs (BookCreatedHandler) that *would* feed deep search are a separate pipeline, out of scope for the search read path and unimplemented for search. | n/a |
| 1.5.3 | n/a — no jobs. | n/a |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — queries the local DB only (US §8). | n/a |
| 1.5.2 | n/a — local DB only. | n/a |
| 1.5.3 | n/a — current impl is local-only; partner-API / web-search sources are future work (US §8). | n/a |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — no storage in the search path (US §9). | n/a |
| 1.5.2 | n/a. | n/a |
| 1.5.3 | n/a. | n/a |

#### Layer 8: Cache Interactions

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — search results are not cached; each search hits the DB (US §10). `Stacks.Books.TitleSearchCache` is the upload-path ISBN-resolution memo and is **unrelated** to `GET /api/search`. | n/a |
| 1.5.2 | n/a — not cached. | n/a |
| 1.5.3 | n/a — not cached. | n/a |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — search reads `op.books` directly; no dbt model in the query path (US §11). | n/a |
| 1.5.2 | n/a — no dbt model involved. | n/a |
| 1.5.3 | n/a — `dbt/models/marts/mart_platform_searchable.sql` exists and is tested (`not_null`/`unique`/`relationships` on `book_id`, `not_null` on `title`/`last_refreshed_at`, registered in `sources.yml`), but it is consumed by `CatalogueController.index`, **not** by the search path. Cited as future backing for platform search (US §11) but currently inert to this feature. | n/a |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ⚠️ SearchProgramTest.elm — `search_debounce` (`QueryChanged` → "Searching…" → `advanceTime 300` → `simulateHttpOk` → `.search-results` + title + author rendered) and `search_filter_panel_toggle` (Show/Hide Filters). **Missing:** init-state assertion (`query=""`, `results=NotAsked`, `debounceCount=0`), `SortChanged` re-sort, `YearFromChanged`/`YearToChanged`/`ClearFilters`, and the stale-debounce no-op (`DebounceExpired count` with `count /= debounceCount`). No `Page/SearchTest.elm` unit test exists — only the program test. | ⚠️ | ⚠️ SearchProgramTest.elm — `search_empty_results` (`Success []` → "No books found matching your search.") and `search_clear` (`ClearQuery` → "Enter a search term above…"). **Missing:** `SearchCompleted (Err _)` → "Search failed. Please try again." (the `Failure` branch is never rendered by any test), and the no-token path (`maybeToken = Nothing` → debounce fires no API call). | ⚠️ |
| 1.5.2 | n/a — no "Deep search" toggle, `searchScope` field, or snippet rendering in `Page.Search`. | n/a | n/a | n/a |
| 1.5.3 | n/a — no `platformResults` field, `PlatformSearchCompleted` Msg, or "Your Collection"/"On the Platform" split in `Page.Search`. | n/a | n/a | n/a |

#### Layer 11: Operational Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — covered by the SLO gate + automatic Phoenix/Ecto telemetry. `scripts/check-slo-gate.sh` gates `catalogue_p95_ms` but defines **no search-specific SLI**; no search mention in any telemetry/observability test. Per project convention, per-US firing tests add no guarantee. | n/a |
| 1.5.2 | n/a — SLO gate. | n/a |
| 1.5.3 | n/a — SLO gate. | n/a |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — covered by SLO gate, not unit tests; in-test latency bounds (US §14 targets like p95 < 500ms) are an anti-pattern under variable CI timing. | n/a |
| 1.5.2 | n/a — SLO gate. | n/a |
| 1.5.3 | n/a — SLO gate. | n/a |

#### Layer 13: Cost Tracking

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 1.5.1 | n/a — no external-API spend; search is a local Postgres query. Fly/Neon compute is a deploy-time dashboard concern, not a per-call `BudgetTracker` record (US §15). | n/a |
| 1.5.2 | n/a — local only. | n/a |
| 1.5.3 | n/a — local only; future partner-API costs are out of scope. | n/a |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Items #1–#6 are
**in-scope test gaps for #115** (feature exists, test missing). Items #7–#9
are **code gaps** that, per the scope-lock rule, should become new issues.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-1.5.1 sad | Multi-word query test (prove `plainto_tsquery` tokenises `"elixir action"` and returns the expected book — the documented `to_tsquery` gotcha), plus special-character / SQL-injection-safety test on the `~r/[^\w\s]/` sanitiser and a very-long-query test | `apps/core/test/stacks_web/search_controller_test.exs` |
| 2 | L3 US-1.5.1 happy | Assert `title_tsv` tsvector is populated on book creation, and that the `title_tsv` GIN index is used (an `EXPLAIN`-based or query-planner assertion, or at minimum a DB-level `plainto_tsquery` fragment test independent of `search_books/2`) | `apps/core/test/stacks/books_test.exs` |
| 3 | L3 US-1.5.1 sad | Context-level multi-word `plainto_tsquery` match test on `search_books/2` (single-word convention leaves the multi-word path unverified) | `apps/core/test/stacks/books_test.exs` |
| 4 | L10 US-1.5.1 happy | Elm state-machine tests: init state (`query=""`, `results=NotAsked`, `debounceCount=0`, no init API call), `SortChanged` (all four `SortOrder` variants), `YearFromChanged`/`YearToChanged`/`ClearFilters`, and stale-debounce no-op (`DebounceExpired count` with `count /= model.debounceCount` → no API call) | new `frontend/tests/Page/SearchTest.elm` (unit) and/or `SearchProgramTest.elm` |
| 5 | L10 US-1.5.1 sad | Elm failure-state tests: `SearchCompleted (Err _)` → "Search failed. Please try again." (the `Failure` branch is currently never rendered by any test); no-token path (`maybeToken = Nothing` → debounce fires no API call) | `frontend/tests/Page/SearchProgramTest.elm` |
| 6 | L1/L10 US-1.5.1 (E2E) | Replace the loose "any response" assertion with deterministic seeded-result checks (results render title + author + year in `.search-results`), plus empty-state and error-state assertions. **Blocked on the path mismatch:** `Api.searchBooks` calls `GET /api/books/search` but the route is `GET /api/search` — fix the client (or add a route) first, otherwise the live call 404s and only the error branch is reachable. Issue #093 does NOT cover this (it is about the Postgres `search_path`). | `e2e/tests/search.spec.ts` + `frontend/src/Api.elm` |
| 7 | L1/L3 US-1.5.3 (code gap → new issue) | Implement platform-wide **discovery sectioning**: marketplace listings, partner inventory, other users' public-bookshelf placements, and events, split into "Your Collection" vs "On the Platform" with contextual labels. Then test. Currently only visibility-filtered book search exists. | new issue (server context + `SearchController` + `Page.Search`) |
| 8 | L3 US-1.5.3 (code gap → new issue) | `Books.search_platform/2` ignores bookshelf/placement visibility (it `ilike`-scans all books; the `platform` bookshelf/placement in the existing test is inert). Implement placement/bookshelf-level platform-visibility scoping (US-1.5.3 §5), then assert exclusion of non-`platform` placements | new issue + `apps/core/test/stacks/books_test.exs` |
| 9 | All layers US-1.5.2 (code gap → new issue) | Implement **deep search** across `description`/review-summary/`subjects` (`scope=deep`, GIN index on `description_tsv`, `ts_headline` snippets, "via deep search" label, Elm `searchScope` toggle), then build its own 13-layer coverage. Entirely unimplemented today — out of scope for the test-only #115 | new issue |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 3-US matrix (78 cells):

- **6 ✅ STRONG** — US-1.5.1 API happy path + both auth cells; US-1.5.3
  visibility enforcement (sad) + both auth cells.
- **8 ⚠️ shallow** — US-1.5.1 API sad (multi-word/injection), DB happy+sad
  (`title_tsv`/GIN mechanism, `plainto_tsquery` gotcha), Elm program
  happy+sad (init/sort/filters/stale-debounce, error/no-token); US-1.5.3 API
  happy + DB happy+sad (platform sectioning + placement-visibility scoping
  unimplemented).
- **0 ❌** — no cell is "feature exists, zero tests"; every gap is either a
  shallow test (⚠️) or an unimplemented feature (n/a).
- **64 n/a** — read-only layers (events, jobs, external, storage, cache,
  dbt, metrics, performance, cost) across all three US; plus every
  US-1.5.2 cell (deep search not implemented) and the US-1.5.3 UI-section
  cells (not implemented).

**Headline findings:**
1. **US-1.5.1 is genuinely implemented and reasonably covered** at the
   controller/context level (11 Elixir tests) — but the two DB mechanisms
   the feature rests on are untested: `title_tsv` tsvector population + GIN
   index usage, and the multi-word `plainto_tsquery` behaviour (the
   documented `to_tsquery` single-word gotcha means the multi-word path has
   never been asserted). The `Failure` UI branch is also never rendered by
   any Elm test.
2. **A live path mismatch is masked by the test suite:** the Elm client
   calls `/api/books/search` while the backend serves `/api/search`. Unit
   tests mock each side of the wire independently and the Playwright test is
   loose enough ("any response, incl. error") to pass on the resulting 404.
   This is the single most important integration gap and is not what Issue
   #093 fixes.
3. **US-1.5.2 (deep search) and the US-1.5.3 discovery sectioning are code,
   not test, gaps** — they should become new issues rather than absorb #115's
   test-only scope. US-1.5.3's one shipped, testable AC — platform-wide
   visibility filtering — is the audit's clearest ✅.

**Test runner totals at baseline (search-related only):** Elixir 14 tests
(9 `search_controller_test.exs` + 2 `search_books/2` + 3 `search_platform/2`),
Elm 4 program tests (`SearchProgramTest.elm`), Playwright 6 tests
(`search.spec.ts`), dbt 5 generic column tests on `mart_platform_searchable`
(catalogue, not search). Punch list: **9 items** — 6 in-scope test gaps
(#1–#6), 3 code gaps for new issues (#7–#9).
## Definition of Done
- [ ] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] `just verify` passes

## Dependencies
- Seeded books with titles for full-text search testing
- `title_tsv` column populated with tsvector data
- Playwright test harness with auth helpers
- `data-testid` attributes on search elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB tests, `elm-agent` for state machine tests.

## Progress Notes
[Updated by agents during execution.]
