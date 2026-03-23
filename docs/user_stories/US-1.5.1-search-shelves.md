# US-1.5.1 — Search Across Shelves

## 1. User Story

> **As a** user, **I want to** search for a book across all my shelves **so that** I can quickly find any book in my collection regardless of which shelf it's on.

**What the user wants to accomplish:** Locate a specific book without having to browse each shelf individually.

**How they accomplish it:**
1. The user clicks the search icon in the top navigation bar (or presses a keyboard shortcut).
2. A search bar drops down, styled as a card catalogue drawer sliding open.
3. The user types a query (title, author, or keyword).
4. Results appear after a 300ms debounce period.
5. Each result shows the book's title, author, and publication year.
6. Clicking a result opens the book detail overlay (US-1.4.1).

**What they see on the page:**
- The search bar has a warm cream background with a serif placeholder: "Search by title, author, or ISBN..."
- Results appear in a list below the search bar.
- Sort selector with options: Title, Author, Year, Date Added.
- Filter panel with year range filter.

**Acceptance Criteria:**
- Search queries fire after 300ms debounce.
- Results display title, author, and publication year.
- Sort options: by title, author, year, date added.
- Year range filter available.
- Empty state shows "Enter a search term above to find books."
- No results shows "No books found matching your search."

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/search`.
2. `Page.Search.init` creates the initial model with `query = ""`, `results = NotAsked`.
3. User types in the search bar -> `QueryChanged query` fires.
4. Model sets `query` and starts a 300ms debounce via `Process.sleep 300`.
5. After 300ms, `DebounceExpired count` fires. If `count == model.debounceCount` and query is non-empty, `Api.searchBooks query token SearchCompleted` fires.
6. `SearchCompleted (Ok books)` -> `results = Success books` -> results list renders.
7. User can sort results via the sort selector (`SortChanged`).
8. User can filter by year range via the filter panel.

### Sad Paths
- **API error**: `SearchCompleted (Err err)` -> "Search failed. Please try again."
- **Empty results**: `Success []` -> "No books found matching your search."
- **No query**: `NotAsked` -> "Enter a search term above to find books."
- **No token**: No API call fires on debounce expiry.

### Elm State Machine
- **Page module**: `Page.Search`
- **Model fields involved**: `query : String`, `results : RemoteData Http.Error (List Book)`, `filters : FilterState`, `sort : SortOrder`, `filterPanelOpen : Bool`, `debounceCount : Int`
- **Msg flow**: `QueryChanged query` -> `DebounceExpired count` -> `Api.searchBooks` -> `SearchCompleted result`
- **RemoteData states**: `NotAsked` (no query) -> `Loading` (query entered, waiting for debounce/API) -> `Success books` / `Failure err`
- **OutMsg pattern**: N/A -- `Page.Search` does not use OutMsg; book detail navigation is not yet wired from search results.

---

## 3. API Calls

### `GET /api/search?q=...`
- **Auth**: Required (`:authenticated` pipeline)
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.SearchController.index/2`
- **Request body**: N/A (query params: `q` required, `limit` optional)
- **Response (success)**: `{ query: "...", count: N, results: [{ id, title, visibility_tier, author: { id, name }, editions: [...], edition_count, primary_edition: {...} }] }` -- HTTP 200
- **Response (error)**: `{ error: "query parameter 'q' is required" }` -- HTTP 422
- **FallbackController handling**: 422 for missing query parameter.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: `Visibility.can_view?(book, viewer)` filters results -- books with hidden visibility are excluded.
- **Age gate**: Not enforced on search results (only on book detail).
- **Ownership checks**: N/A -- search returns all visible books, not just the user's.

---

## 5. Database Interactions

### Read: Full-text search on book titles
- **Table(s)**: `op.books`
- **Query**: `Book |> where([b], fragment("title_tsv @@ plainto_tsquery('english', ?)", ^safe_query)) |> preload([:author, :editions]) |> limit(^limit)`. The `safe_query` strips non-word/non-space characters via `String.replace(query, ~r/[^\w\s]/, "")`.
- **Indexes used**: GIN index on `title_tsv` column (tsvector)
- **Schema module**: `Stacks.Books.Book`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- search is a read-only operation.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A

---

## 8. External Service Calls

N/A -- search queries the local database only. Platform-wide discovery search (US-1.5.3) extends this to external sources.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A -- search results are not cached.

---

## 11. dbt Model Dependencies

N/A -- search queries the `op.books` table directly, not dbt models.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Search` (implied from page structure)
- **URL**: `/search`
- **Public or authenticated**: Authenticated (`:authenticated` pipeline for API)

### Init
- **`initPage` branch**: Creates `Page.Search.init`
- **API calls on init**: None -- search only fires after user types and debounce expires
- **Initial model state**: `{ query = "", results = NotAsked, filters = defaultFilterState, sort = ByTitle, filterPanelOpen = False, debounceCount = 0 }`

### Update cycle
- **Msg `QueryChanged query`**: `query` -> new value; `debounceCount` incremented; `results` -> `Loading` if non-empty query, `NotAsked` if empty; Cmd: `Process.sleep 300` then `DebounceExpired newCount`
- **Msg `ClearQuery`**: `query` -> `""`; `results` -> `NotAsked`
- **Msg `DebounceExpired count`**: If `count == debounceCount` and query non-empty, fires `Api.searchBooks`; otherwise no-op
- **Msg `SearchCompleted (Ok books)`**: `results` -> `Success books`
- **Msg `SearchCompleted (Err err)`**: `results` -> `Failure err`
- **Msg `SortChanged sortStr`**: `sort` -> parsed `SortOrder` (`ByTitle`, `ByAuthor`, `ByYear`, `ByDateAdded`)
- **Msg `ToggleFilterPanel`**: `filterPanelOpen` -> toggled
- **Msg `YearFromChanged str`**: `filters.yearFrom` -> `String.toInt str`
- **Msg `YearToChanged str`**: `filters.yearTo` -> `String.toInt str`
- **Msg `ClearFilters`**: `filters` -> `defaultFilterState`

### View
- **Key elements**:
  - `div.page.page--search` wrapper
  - `h1.page__title` "Search Books"
  - `Components.SearchBar.searchBar` -- input with placeholder "Search by title, author, or ISBN...", clear button
  - `Components.SortSelector.sortSelector` -- dropdown for sort order
  - `Components.FilterPanel.filterPanel` -- collapsible year range filter
  - `NotAsked`: `p.search-hint` "Enter a search term above to find books."
  - `Loading`: `div.loading` "Searching..."
  - `Failure _`: `p.error` "Search failed. Please try again."
  - `Success []`: `p.search-empty` "No books found matching your search."
  - `Success books`: `div.search-results` containing `viewBookResult` for each book
  - Each result: `div.search-result` with `h3.search-result__title`, `p.search-result__author`, `p.search-result__year`
- **ARIA attributes**: N/A (no explicit ARIA on search results beyond standard HTML)
- **CSS classes**: `page page--search`, `page__title`, `search-hint`, `loading`, `error`, `search-empty`, `search-results`, `search-result`, `search-result__title`, `search-result__author`, `search-result__year`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/search", method="GET"}` | Phoenix.Telemetry | Counter | Increment per request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/search", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/search", status=422}` | Phoenix.Telemetry | Counter | Increment per 422 (missing query param) response | Informational |
| `db.query.count{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Counter | Increment per full-text search query | 1 per search request |
| `db.query.duration{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Histogram (ms) | Full-text search query execution time (GIN index on `title_tsv`) | p50 < 20ms, p95 < 100ms |
| `search.result_count` | API response | Histogram | `count` field in search response | Informational |
| `error.rate{endpoint="/api/search"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `search.query_latency` | Elm Performance API | Histogram (ms) | Time from `DebounceExpired` (API call) to `SearchCompleted (Ok _)` | p50 < 200ms, p95 < 500ms |
| `search.time_to_results` | Elm Performance API | Histogram (ms) | Time from first keystroke to results visible (includes 300ms debounce + API round trip + render) | p50 < 600ms, p95 < 1000ms |
| `search.queries_per_session` | Elm event tracking | Counter per session | Count of `DebounceExpired` msgs that trigger API calls | Informational (engagement) |
| `search.empty_result_rate` | API response | Gauge (%) | Percentage of searches returning `count: 0` | Informational (content coverage) |
| `user.sort_changes_per_session` | Elm event tracking | Counter per session | Increment on each `SortChanged` msg | Informational (feature usage) |
| `user.filter_toggles_per_session` | Elm event tracking | Counter per session | Increment on each `ToggleFilterPanel`, `YearFromChanged`, `YearToChanged` msg | Informational (feature usage) |
| `search.abandoned_rate` | Elm event tracking | Gauge (%) | Searches where user navigates away before clicking a result | Informational (UX quality) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of search queries | Full-text search with `plainto_tsquery` uses PostgreSQL CPU. Single query per request with GIN index lookup. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Full-text search queries against `title_tsv` GIN index | GIN index scans are more CPU-intensive than B-tree lookups. Cost scales with corpus size and query complexity. Preloads (author, editions) add JOIN cost. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Visibility filtering | `Visibility.can_view?` filtering applied in-query. Adds WHERE clause complexity. |
| Fly.io compute (core) | CPU-ms per request | Query sanitisation | `String.replace(query, ~r/[^\w\s]/, "")` regex runs on every search. Negligible cost. |
