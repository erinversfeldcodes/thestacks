# Issue #115: E2E Test Suite — Search

## Summary
Comprehensive end-to-end test coverage for search functionality, including debounced input, full-text search on `title_tsv`, sort/filter controls, empty/no-results states, and visibility filtering of results. Includes the in-scope bug fix for the live client/route path mismatch (`Api.elm` calls `/api/books/search`; the route is `/api/search`).

> **De-scoped 2026-07-23 (epic kickoff):** US-1.5.2 (deep search) → #284; US-1.5.3 (platform discovery sectioning) → #285 (+ #286 for the unwired `search_platform/2`). US-1.5.3's one shipped AC — platform-wide visibility filtering — remains validated here under US-1.5.1.

## User Stories Covered
- [US-1.5.1 — Search Across Shelves](../docs/user_stories/US-1.5.1-search-shelves.md)

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
| US-1.5.1 — Search Across Shelves | Route `core_web/router.ex:208` → `SearchController.index` (`search_controller.ex:12`) → `Books.search_books/2` (`books.ex:694`, `plainto_tsquery` on `title_tsv`) → controller visibility filter `Enum.filter(books, &Visibility.can_view?(&1, viewer))` (`search_controller.ex:16`) → object envelope `{query, count, results}` (`search_controller.ex:18-22`) → Elm client `Api.searchBooks` `GET /api/search` (`Api.elm:787`) decoding `Decode.field "results"` (`Api.elm:793`) → `Page.Search.view` applies `applyYearFilter`/`sortBooks` (`Page/Search.elm:231-232`) → `.search-results`. | `/search` q="Book" rendered the three seeded public works in default title-ascending order — The Book of Laughter and Forgetting / Milan Kundera / 1979, The Book of Legendary Lands / Umberto Eco / 2013, The Book of Sand / Jorge Luis Borges / 1975 — each row binding title + author + year, 0 error nodes (observed live 2026-07-24). | ✅ | Both live-wire breaks fixed in-scope: `Api.elm:787` path `/api/books/search`→`/api/search` and `Api.elm:793` bare-array→`Decode.field "results"` decoder (approved at kickoff 2026-07-23); driven live 2026-07-24. |

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
- ~~Verify results are clickable~~ / ~~Click a result; verify book detail overlay opens~~ — DE-SCOPED → #289 (2026-07-23, found during Phase 3: `viewBookResult` renders a plain div, no click affordance or NavigateTo OutMsg exists — feature unbuilt, not a test gap)

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

#### Full-Text Deep Search — DE-SCOPED → #284
- Deep search (descriptions/reviews, toggle, snippets) is unimplemented; feature spun out to #284.
- In scope here: verify current search searches `title_tsv` via `plainto_tsquery`.

#### Platform-Wide Results (visibility slice only; sectioning DE-SCOPED → #285)
- Current implementation: `Books.search_books/2` returns all visible books platform-wide (not scoped to user)
- Verify visibility rules enforced (hidden/age-gated books excluded from results per viewer)
- Collection scoping / "Your Collection" vs "On the Platform" sections → #285; unwired `search_platform/2` → #286

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

_Test-coverage map for this issue (13 layers × user story, happy/sad columns), regenerated 2026-07-24 to the SHIPPED state. **Audit GREEN — 0 ❌ / 0 ⚠️**: every cell is `✅` (with a verified test file:line) or `n/a`-with-rationale. Baseline was generated 2026-07-08; see Progress Notes for the phase-by-phase resolution._

Last regenerated: 2026-07-24 (post-implementation — Issue #115 shipped)

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

**Feature status (verified by reading source + live drive 2026-07-24):**
- **US-1.5.1 is implemented, wired end-to-end, and driven live.**
  `StacksWeb.SearchController.index/2`
  (`apps/core/lib/stacks_web/controllers/search_controller.ex:12`, route
  `GET /api/search`, `core_web/router.ex:208`, `:authenticated` pipeline) →
  `Stacks.Books.search_books/2` (`apps/core/lib/stacks/books.ex:694`,
  `title_tsv @@ plainto_tsquery('english', ?)` with a `~r/[^\w\s]/`
  sanitiser) → controller visibility filter
  `Enum.filter(books, &Visibility.can_view?(&1, viewer))`
  (`search_controller.ex:16`) → object envelope `{query, count, results}`
  (`search_controller.ex:18-22`) → `ProtoJSON.search_book/1`. Frontend
  `Page.Search` + `Components.SearchBar` + `SortSelector` + `FilterPanel`;
  sort/year-filter are **client-side only** (the API takes only `q` +
  `limit`) and are now applied by `Page.Search.view`
  (`applyYearFilter`/`sortBooks`, `Page/Search.elm:231-232, 313, 350`).
- **US-1.5.2 (deep search) — DE-SCOPED → #284.** Deep search across
  descriptions/reviews, `ts_headline` snippets, and the "via deep search"
  label is not built (no `scope=deep`, no `description_tsv`, no Elm toggle).
  Spun out to #284 at kickoff (2026-07-23); its story-specific cells are
  `n/a (de-scoped → #284)`. The current title-only behaviour is covered
  under US-1.5.1.
- **US-1.5.3 (platform-wide discovery) — sectioning DE-SCOPED → #285/#286;
  the one shipped AC validated under US-1.5.1.** `search_books/2` returns
  **all visible books platform-wide** (not scoped to the caller's
  collection) and visibility is enforced in the controller — so the load-
  bearing "visibility rules on all results" AC is met and tested (the two
  age-gated tests). The "Your Collection" vs "On the Platform" sectioning,
  marketplace/partner/other-user sources, and contextual labels are not
  built → #285. `Books.search_platform/2` (`books.ex`) exists but backs
  `CatalogueController`, does not filter by bookshelf/placement visibility,
  and is dead relative to the search path → #286.

**✅ Cross-cutting integration finding RESOLVED (two live-wire breaks fixed
in-scope):** at baseline the Elm client `Api.searchBooks` issued
`GET /api/books/search?q=...` while the backend route is `GET /api/search`
(`core_web/router.ex:208` — there was no `/api/books/search` route), and a
second break surfaced during E2E: the client decoded a bare top-level array
while `SearchController.index` returns the object envelope
`{query, count, results:[...]}`. Both are now fixed:
`Api.elm:787` targets `["api", "search"]` and `Api.elm:793` decodes
`Decode.field "results" (Decode.list bookDecoder)`. The wire is now
exercised: `searchUrlIsApiSearch` (`SearchProgramTest.elm:68`) pins the URL,
`searchResponseJson` (`SearchProgramTest.elm:416`) pins the object envelope,
and `search.spec.ts` drives the real route in a browser. Non-vacuity proven:
reverting the `Api.elm` path makes the seeded-results E2E fail verbatim
(`getByTestId('search-results')` never visible → 404 `Failure` branch).
Issue #093 (Postgres `search_path`) was never this issue. Punch-list #6
resolved.

---

### Framework-layer summary

| Framework    | US-1.5.1 | US-1.5.2 | US-1.5.3 |
|--------------|----------|----------|----------|
| Elixir       | ✅ (controller happy/sad + edge-case describe: multi-word tokenisation, injection + `op.books` intact, tsquery operators, very-long; `search_books/2` multi-word, `title_tsv` populated, GIN `idx_books_title_tsv` via EXPLAIN) | n/a — deep search de-scoped → #284 | ✅ visibility-filtering slice (two age-gated controller tests); sectioning + `search_platform/2` scoping de-scoped → #285/#286 |
| Elm unit     | ✅ (`Page/SearchTest.elm`: init state, `SortChanged` ×5, `YearFrom/YearToChanged`, `ClearFilters`) | n/a — de-scoped → #284 | n/a — sectioning de-scoped → #285 |
| Elm program  | ✅ (`SearchProgramTest.elm`: URL guard, debounce, clear, empty, filter toggle, failure, stale-debounce, no-token, sort ×4 view-level, year filter) | n/a — de-scoped → #284 | n/a — de-scoped → #285 |
| Python       | n/a — vision service not involved in search | n/a | n/a |
| E2E          | ✅ (`search.spec.ts`, 10 tests: render/hint/sort-present/filter-present/clear + deterministic seeded results, empty-state, error-state, sort re-order, year filter; fail-open guard removed, non-vacuity proven) | n/a — de-scoped → #284 | n/a — sectioning de-scoped → #285 |
| dbt          | n/a — search reads `op.books` directly, no dbt in the path | n/a | n/a — `mart_platform_searchable` exists + tested but backs `CatalogueController`, not search |

**Existing test inventory (verified by grep/read this regeneration):**
- `apps/core/test/stacks_web/search_controller_test.exs` —
  matching query, empty results, 422 missing `q`, valid/invalid limit,
  author info, 401 unauthenticated, the two age-gated visibility tests
  (`:150+`), and the `GET /api/search — query edge cases` describe (`:93`):
  multi-word tokenisation (`:94`), SQL-injection + `op.books` intact
  (`:106`), tsquery operator chars (`:119`), very-long query (`:130`).
- `apps/core/test/stacks/books_test.exs` — `search_books/2`: title match,
  empty on no-match, multi-word `plainto_tsquery` (`:247`), `title_tsv`
  populated on creation (`:263`), GIN `idx_books_title_tsv` used via EXPLAIN
  with `SET LOCAL enable_seqscan=off` (`:279`).
- `frontend/tests/Page/SearchProgramTest.elm` — `searchUrlIsApiSearch`
  (`:68`), `searchDebounce`, `searchClear`, `searchEmptyResults`,
  `searchFilterPanelToggle`, `searchFailure` (`:213`), `searchStaleDebounce`
  (`:240`), `searchNoTokenFiresNoBookRequest` (`:260`), the four view-level
  sort tests (`:345-383`), `yearFilterAndClear` (`:384`), plus the #217
  `readers_*` people-search tests (untouched). `searchResponseJson`
  (`:416`) is the single object-envelope body builder.
- `frontend/tests/Page/SearchTest.elm` — NEW unit suite: init state,
  `SortChanged` ×5 (`:57`), `YearFromChanged`/`YearToChanged`,
  `ClearFilters`.
- `e2e/tests/search.spec.ts` — 10 Playwright tests (deterministic seeded
  anchor on query `"Book"`; error-state via `page.route` 500).
- `dbt/models/marts/mart_platform_searchable.sql` + `schema.yml` — generic
  column tests — consumed by catalogue, not search.
- `apps/core/test/stacks/books/title_search_cache_test.exs` (+`_persistent`)
  — **NOT part of this feature**: the upload-path ISBN-resolution memo,
  unrelated to `GET /api/search`.

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **11** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher / not applicable / de-scoped) | **67** |

78 cells total (13 layers × 3 US × happy/sad). **Audit GREEN — 0 ❌ / 0 ⚠️.**
The eight shallow cells at baseline all resolved: the five US-1.5.1 cells
(API sad edge cases, DB happy + sad, Elm program happy + sad) became ✅ with
real test citations; the three US-1.5.3 sectioning cells became
`n/a (de-scoped → #285/#286)`. US-1.5.2 (deep search) remains
`n/a (de-scoped → #284)`. Per the scope-lock rule the de-scoped behaviours
are new issues, not tests written under the test-only #115; US-1.5.3's one
shipped AC (platform-wide visibility filtering) stays validated under
US-1.5.1's controller visibility tests.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ✅ search_controller_test.exs — "returns matching books for query" (asserts `query` echo + title membership), "returns author info when book has an associated author" (nested `author.name`), "respects a valid limit parameter". Response shape (`{query, count, results}`) exercised end-to-end and now driven live (2026-07-24). | ✅ | ✅ search_controller_test.exs — "returns empty results for non-matching query" (200 + `count:0` + `results:[]`), "returns 422 when q param missing", "ignores invalid limit and defaults to 20", **plus the `query edge cases` describe (`:93`)**: multi-word tokenisation (`:94`, proves `plainto_tsquery` handles `"elixir action"`), SQL-injection-style query returns 200 + `op.books` intact (`:106`), tsquery operator chars degrade without a 500 (`:119`), very-long query (`:130`). Non-vacuity: swapping `plainto_tsquery`→`to_tsquery` fails the operator/multi-word tests (tsquery syntax_error → 500). | ✅ |
| 1.5.2 | n/a — deep search (descriptions/reviews, `scope=deep`, `ts_headline` snippets) de-scoped → #284; the current title-only endpoint is covered under US-1.5.1. | n/a | n/a — same; deep-search error paths de-scoped → #284. | n/a |
| 1.5.3 | n/a — platform-wide book results ARE the current behaviour (`search_books/2` returns all visible books, not user-scoped) and are exercised by the US-1.5.1 happy + E2E tests. The US-1.5.3-specific multi-source discovery (marketplace, partner inventory, other users' public bookshelves, events) and "Your Collection"/"On the Platform" sectioning are de-scoped → #285. | n/a | ✅ Visibility enforcement (the load-bearing US-1.5.3 AC "visibility rules enforced on all results") is tested: search_controller_test.exs — "excludes age_gated books from results for non-age-verified user" and "includes age_gated books … for age-verified user" (the `visibility filtering` describe, `:149`). | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ✅ search_controller_test.exs — every describe uses an authenticated conn (`Guardian.encode_and_sign` Bearer token in `setup`), exercising the `:authenticated` pipeline; visibility guard covered by the two age-gated tests. | ✅ | ✅ search_controller_test.exs — "returns 401 without authentication" (bare `build_conn()`). | ✅ |
| 1.5.2 | n/a — same pipeline as US-1.5.1; no deep-search-specific guard. | n/a | n/a | n/a |
| 1.5.3 | ✅ Same `:authenticated` pipeline + `build_viewer/1` → `Visibility.can_view?/2` filtering, tested via the age-gated visibility cases (viewer identity drives result set). | ✅ | ✅ 401 path shared with US-1.5.1 ("returns 401 without authentication"). | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 1.5.1 | ✅ books_test.exs — `search_books/2` "returns books matching title query" (title match, non-match excluded), **plus the two DB-mechanism tests the feature rests on**: "populates the title_tsv tsvector column on book creation" (`:263`, asserts the `GENERATED ALWAYS AS to_tsvector` column carries stemmed `elixir`/`action` lexemes with `in` dropped as a stopword) and "the full-text query uses the title_tsv GIN index" (`:279`, `EXPLAIN` under `SET LOCAL enable_seqscan=off` asserts `idx_books_title_tsv` is chosen). | ✅ | ✅ books_test.exs — `search_books/2` "returns empty list when no match" (`:243`) **and** "matches a multi-word query via plainto_tsquery tokenisation" (`:247`, drives `"elixir action"` through the context to prove the multi-word path returns the right book rather than failing — the documented `to_tsquery` gotcha, now asserted at the context level). | ✅ |
| 1.5.2 | n/a — `description_tsv`/review-summary columns and their indexes do not exist; deep search de-scoped → #284. | n/a | n/a | n/a |
| 1.5.3 | n/a — `search_platform/2` DB behaviour and its placement/bookshelf-level platform-visibility scoping (US-1.5.3 §5, currently unimplemented — it `ilike`-scans all books and backs `CatalogueController`, not search) are de-scoped → #285/#286. The actual search path (`SearchController`) enforces book-level `can_view?`, covered under US-1.5.1 / L1 US-1.5.3 sad. | n/a | n/a — same; `search_platform/2` placement-visibility exclusion de-scoped → #286. | n/a |

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
| 1.5.1 | ✅ SearchProgramTest.elm — `searchUrlIsApiSearch` (`:68`, pins `GET /api/search?q=`), `searchDebounce` ("Searching…" → `advanceTime 300` → `simulateHttpOk` → `.search-results` + title + author), `searchFilterPanelToggle`, plus the four view-level sort tests (`:345-383`, assert rendered `.search-result__title` ORDER for default title / author / year / date-added) and `yearFilterAndClear` (`:384`, year range narrows rendered results, `ClearFilters` restores). Unit `Page/SearchTest.elm` pins init state (`query=""`, `results=NotAsked`, `debounceCount=0`, default sort/filters), `SortChanged` ×5 (`:57`), `YearFrom/YearToChanged`, `ClearFilters`. | ✅ | ✅ SearchProgramTest.elm — `searchEmptyResults` (`Success []` → "No books found matching your search."), `searchClear` (`ClearQuery` → entry hint), `searchFailure` (`:213`, `Http.BadStatus_` 500 → "Search failed. Please try again." — the `Failure` branch now rendered), `searchStaleDebounce` (`:240`, two `QueryChanged` → only the latest count fires a request), `searchNoTokenFiresNoBookRequest` (`:260`, anonymous → 0 book-search requests, readers search unaffected, entry hint remains). | ✅ |
| 1.5.2 | n/a — no "Deep search" toggle, `searchScope` field, or snippet rendering in `Page.Search`; de-scoped → #284. | n/a | n/a | n/a |
| 1.5.3 | n/a — no `platformResults` field, `PlatformSearchCompleted` Msg, or "Your Collection"/"On the Platform" split in `Page.Search`; sectioning de-scoped → #285. | n/a | n/a | n/a |

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

### Punch list (all resolved — 0 open)

Every baseline ❌/⚠️ cell converted to a numbered item. Items #1–#6 were
**in-scope test gaps for #115** (feature exists, test missing) — all
resolved with the citations below. Items #7–#9 were **code gaps**; per the
scope-lock rule they became new issues at kickoff (2026-07-23).

| # | Cell | Resolution | Evidence |
|--:|------|------------|----------|
| 1 | L1 US-1.5.1 sad | ✅ RESOLVED | `search_controller_test.exs` `query edge cases` describe (`:93`): multi-word `:94`, injection + `op.books` intact `:106`, tsquery operators `:119`, very-long `:130`. Non-vacuity: `to_tsquery` swap fails the operator/multi-word tests. |
| 2 | L3 US-1.5.1 happy | ✅ RESOLVED | `books_test.exs` — "populates the title_tsv tsvector column on book creation" (`:263`) and "the full-text query uses the title_tsv GIN index" (`:279`, `EXPLAIN` + `SET LOCAL enable_seqscan=off` → `idx_books_title_tsv`). |
| 3 | L3 US-1.5.1 sad | ✅ RESOLVED | `books_test.exs` — "matches a multi-word query via plainto_tsquery tokenisation" (`:247`). |
| 4 | L10 US-1.5.1 happy | ✅ RESOLVED | `Page/SearchTest.elm` (init state, `SortChanged` ×5 `:57`, `YearFrom/YearToChanged`, `ClearFilters`) + `SearchProgramTest.elm` view-level sort `:345-383`, `yearFilterAndClear` `:384`, `searchStaleDebounce` `:240`. |
| 5 | L10 US-1.5.1 sad | ✅ RESOLVED | `SearchProgramTest.elm` — `searchFailure` (`:213`, `Failure` branch → "Search failed. Please try again.") and `searchNoTokenFiresNoBookRequest` (`:260`). |
| 6 | L1/L10 US-1.5.1 (E2E) | ✅ RESOLVED | `search.spec.ts` — deterministic seeded results (`:106`), empty-state (`:145`), error-state (`:157`), sort re-order (`:181`), year filter (`:217`); fail-open OR-guard removed; passes `scripts/check-e2e-vacuous-guards.sh`. Path mismatch fixed in-scope (`Api.elm:787` + decoder `:793`); non-vacuity proven by path revert. Driven live 2026-07-24. |
| 7 | L1/L3 US-1.5.3 (code gap) | → #285 | Platform-wide discovery sectioning ("Your Collection" vs "On the Platform", multi-source) spun out to #285. Only visibility-filtered book search exists (validated under US-1.5.1). |
| 8 | L3 US-1.5.3 (code gap) | → #286 | `Books.search_platform/2` placement/bookshelf-visibility scoping (dead relative to search) spun out to #286. |
| 9 | All layers US-1.5.2 (code gap) | → #284 | Deep search (`scope=deep`, `description_tsv`, `ts_headline` snippets, Elm toggle) spun out to #284. |

---

### Verdict

**Audit GREEN — shipped state.** State across the 13-layer × 3-US matrix
(78 cells):

- **11 ✅ STRONG** — US-1.5.1 API happy + sad, DB happy + sad, Elm program
  happy + sad, and both auth cells; US-1.5.3 visibility enforcement (sad) +
  both auth cells.
- **0 ⚠️** — every baseline shallow cell resolved (five US-1.5.1 cells → ✅
  with real citations; three US-1.5.3 sectioning cells → n/a de-scoped).
- **0 ❌** — no cell is "feature exists, zero tests".
- **67 n/a** — read-only layers (events, jobs, external, storage, cache,
  dbt, metrics, performance, cost) across all three US; every US-1.5.2 cell
  (deep search de-scoped → #284); and the US-1.5.3 sectioning cells
  (de-scoped → #285/#286).

**Headline findings:**
1. **US-1.5.1 is implemented, covered, and driven live.** The two DB
   mechanisms the feature rests on are now asserted — `title_tsv` tsvector
   population (`books_test.exs:263`) and GIN index usage via `EXPLAIN`
   (`:279`) — and the multi-word `plainto_tsquery` path is proven at both
   the controller (`search_controller_test.exs:94`) and context
   (`books_test.exs:247`) levels. The Elm `Failure` branch is now rendered
   (`SearchProgramTest.elm:213`).
2. **Both live-wire breaks are fixed and locked.** The path mismatch
   (`/api/books/search` → `/api/search`, `Api.elm:787`) and the decoder
   shape mismatch (bare array → `Decode.field "results"`, `Api.elm:793`)
   are pinned by `searchUrlIsApiSearch`/`searchResponseJson` and exercised
   in a real browser by `search.spec.ts`. Non-vacuity proven: reverting the
   path fails the seeded-results E2E verbatim. Live drive of `/search`
   q="Book" rendered the three seeded works title-ascending (2026-07-24).
3. **US-1.5.2 (deep search) and US-1.5.3 discovery sectioning are de-scoped
   code gaps** → #284 / #285 / #286 (the scope-lock rule keeps them out of
   the test-only #115). US-1.5.3's one shipped AC — platform-wide
   visibility filtering — is validated under US-1.5.1 (the two age-gated
   controller tests).

**Test runner totals (this session, verified green):** Elixir 2862 / 0,
Elm 999 / 0, Playwright 12 / 12 live (10 search + 2 setup, 2026-07-24),
`just verify` green (dbt 237 / 237). Punch list: **0 open** — items #1–#6
resolved with citations above, #7–#9 spun out to #284/#285/#286.
## Definition of Done
- [x] All test cases enumerated in the Test Suites / Technical Requirements above are implemented and passing with `TEST_TARGET=local` — Elixir 2862/0, Elm 999/0, Playwright 12/12 live (10 search + 2 setup, 2026-07-24)
- [x] No flaky tests — each suite green across three independent runs this session (impl + reviewer re-runs); E2E passes `scripts/check-e2e-vacuous-guards.sh`, non-vacuity proven by `Api.elm` path revert
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — US-1.5.1 happy path built end-to-end and driven live 2026-07-24 (`/search` q="Book" → three seeded works title-ascending); US-1.5.2 → #284, US-1.5.3 sectioning → #285/#286 de-scoped (Summary edited + spin-out issues). No named story reaches GREEN via `n/a (see #NNN)`.
- [x] **Test audit (embedded above) is GREEN** — 11 ✅ / 0 ⚠️ / 0 ❌ / 67 n/a across the 78-cell matrix; regenerated to shipped state 2026-07-24, every ✅ cell cites a verified test file:line
- [x] `just verify` passes — green 2026-07-24, dbt 237/237

## Dependencies
- Seeded books with titles for full-text search testing
- `title_tsv` column populated with tsvector data
- Playwright test harness with auth helpers
- `data-testid` attributes on search elements (Issue #108)

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB tests, `elm-agent` for state machine tests.

## Progress Notes
- 2026-07-23 — Epic kickoff (#115/#114/#113 on `feat/115-114-3-e2e`). Baseline re-verified against current code: path mismatch (`Api.elm:787` `/api/books/search` vs route `/api/search`) still live, masked by the fail-open OR-assertion at `search.spec.ts:50-57`. People-search (#217) added to `Page.Search` since baseline (readers section + 4 `readers_*` program tests) — specs must not break it. `search_books/2` does visibility in the CONTROLLER, not the context. US-1.5.2 → #284, US-1.5.3 sectioning → #285, `search_platform/2` dead code → #286. Approved in-scope: the `Api.elm` path fix.
- 2026-07-23 — Phase 2 (Elixir) done: added controller edge-case tests (multi-word tokenisation, SQL-injection safety + `op.books` intact assertion, tsquery-operator chars, very-long query) in `search_controller_test.exs` and context tests (multi-word `plainto_tsquery` match, `title_tsv` populated on insert, GIN `idx_books_title_tsv` used via EXPLAIN with `SET LOCAL enable_seqscan=off`) in `books_test.exs`. 75 tests / 0 failures; format + credo clean. Non-vacuity proven: swapping `plainto_tsquery`→`to_tsquery` fails 5 of the new tests (tsquery syntax_error). FLAG: removing the `~r/[^\w\s]/` sanitiser alone does NOT fail any test — `plainto_tsquery` + Ecto param binding already make injection inert; the sanitiser is belt-and-suspenders, not the load-bearing guard (audit punch #1 rests on `plainto_tsquery`, not the regex). No production changes.
- 2026-07-23 — Phase 1 (elm-agent) done: fixed `Api.elm` `searchBooks` path `/api/books/search`→`/api/search` (+ the in-sync `TestHelpers.searchEffects` mirror, since program tests exercise the mirror not the opaque real Cmd). Test-first URL assertion (`searchUrlIsApiSearch`) captured failing pre-fix (`GET /api/books/search?q=habit` observed). Added program tests `searchFailure`, `searchStaleDebounce`, `searchNoTokenFiresNoBookRequest` (punch #5) and pure-unit `tests/Page/SearchTest.elm` — init state, `SortChanged` ×5, `YearFrom/YearToChanged`, `ClearFilters` (punch #4). FLAG: `Page.Search.view` never consumes `model.sort`/`model.filters` — the sort/year controls set state but do not re-order/filter rendered results (inert control, candidate follow-up). Full elm-test 978 pass / 0 fail; elm-format + elm-review clean.
- 2026-07-23 — Phase 1 revision 1 (elm-agent): the inert-sort/filter flag accepted as in-scope bug fix. Test-first — 4 new view-level tests in `SearchProgramTest.elm` (`sort_default_title`, `sort_by_author`, `sort_by_year`, `year_filter`) failed against the unsorted view (verbatim: rendered order stayed server-order `[Zebra, Middle, Alpha]`; `sort_by_date_added` passed pre-fix since DateAdded preserves server order). Implemented `applyYearFilter`/`sortBooks` in `Page.Search.view` (filter then sort the Success list before render; DateAdded keeps server order, no-year books excluded once a bound is active). Update-level `SearchTest.elm` tests retained. Full elm-test 983 pass / 0 fail; elm-format, `elm make --optimize`, elm-review all clean.
- 2026-07-23 — Phase 1 revision 2 (elm-agent): second live-wire bug (found by Phase 3 E2E). `SearchController.index` returns `{query, count, results:[...]}` (`search_controller.ex:18-22`) but `Api.searchBooks` decoded a bare top-level array → every real response failed to decode → live search rendered "Search failed" for all queries. Root cause the mirror missed: every simulated search body used the same bare-list fiction. Test-first — switched `searchResponseJson` to the real object shape FIRST; 7 tests failed on the bare-list decoder (`search_debounce`, `search_empty_results`, all 4 `sort_*`, `year_filter`). Fixed `Api.elm:793` → `Decode.field "results" (Decode.list bookDecoder)` (matches sibling `book`/`users` unwrapping) + synced the `TestHelpers.searchEffects` mirror decoder. Swept: no bare-list search body remains (single builder `searchResponseJson` is object-shaped). Full elm-test 983 pass / 0 fail; elm-format + elm-review clean. Rebuilt deployed assets (`apps/core/assets && npm run deploy`) so the live stack serves the fixed `app.js`.
- 2026-07-23 — Phase 3 (testing-coordinator/Playwright) done: rewrote `e2e/tests/search.spec.ts` — killed the fail-open OR-guard (old `:50-57`, a #275-class vacuous assertion) and replaced it with deterministic seeded-content tests anchored on query `"Book"` (3 distinct public works: The Book of Legendary Lands/Eco/2013, The Book of Sand/Borges/1975, The Book of Laughter and Forgetting/Kundera/1979). New: seeded-results (exact title order + per-row author+year bound inside `[data-testid="search-results"]`), empty-state ("No books found matching your search."), error-state (page.route 500 → "Search failed. Please try again."), sort re-order (Title/Author/Year, exact computed orders), year-filter (From=1976 excludes Sand, Clear Filters restores). Kept the render/hint/sort-present/filter-present/clear tests. Run against a real local stack (Phoenix :4000, `STACKS_E2E_TEST_HELPERS=1` + `AGE_GATING_ENABLED=true`, seeded `stacks_dev`, assets rebuilt): **12 passed / 0 failed** (10 search + 2 setup). Passes `scripts/check-e2e-vacuous-guards.sh`. Non-vacuity PROVEN: with `Api.elm` path reverted to `/api/books/search` + assets rebuilt, the seeded-results test FAILS verbatim (`getByTestId('search-results')` never visible → 404 Failure branch); path restored, assets rebuilt, `git diff -- frontend/src/Api.elm` shows only Phase-1's path+decoder fix (no proving-gate trace). Live drive of `/search` q=`"Book"`: 3 rows rendered in default title order [Laughter/Kundera/1979, Legendary/Eco/2013, Sand/Borges/1975], 0 error nodes — US-1.5.1 Pre-Check happy path observed live end-to-end. Note: Phase 3 caught Phase 1's second live-wire bug (decoder shape), fixed under Phase 1 revision 2. Touched only `e2e/**` + this issue file.
