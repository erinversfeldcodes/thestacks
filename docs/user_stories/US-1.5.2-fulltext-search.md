# US-1.5.2 — Full-Text Search Across Reviews and Descriptions

## 1. User Story

> **As a** user, **I want to** search across book descriptions and review summaries **so that** I can find books based on themes, topics, or sentiments mentioned in reviews.

**What the user wants to accomplish:** Discover books in their collection based on deeper content than just title and author.

**How they accomplish it:**
1. The user enters a query in the search bar and toggles the scope to "Deep search."
2. The system queries the backend API for full-text search across stored descriptions, review summaries, and subjects.
3. Results return with highlighted matching snippets.

**What they see on the page:**
- Results include a snippet of matching text with the search term highlighted in a warm amber.
- A subtle indicator distinguishes instant local results from API-fetched deep results (e.g., a small "via deep search" label).

**Acceptance Criteria:**
- Full-text search queries descriptions and review summaries.
- Results include matching text snippets.
- Differentiated from title-only search results.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/search` and types a query.
2. The current implementation uses `plainto_tsquery('english', ?)` on the `title_tsv` column -- full-text search across descriptions and reviews is not yet implemented.
3. Results return book titles matching the tsvector index.

### Current Implementation Status
The backend `SearchController` and `Books.search_books/2` currently search only on `title_tsv`. Full-text search across descriptions, review summaries, and subjects is a planned enhancement. The frontend `Page.Search` does not yet have a "Deep search" toggle.

### Sad Paths
- Same as US-1.5.1 -- API errors, empty results, missing query.

### Elm State Machine
- **Page module**: `Page.Search` (same as US-1.5.1)
- **Model fields involved**: Same as US-1.5.1. No `deepSearch` toggle field exists yet.
- **Msg flow**: Same as US-1.5.1. No separate deep search Msg exists yet.
- **RemoteData states**: Same as US-1.5.1.
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/search?q=...` (current implementation)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.SearchController.index/2`
- **Request body**: N/A (query params: `q` required, `limit` optional)
- **Response (success)**: `{ query: "...", count: N, results: [...] }` -- HTTP 200
- **Response (error)**: `{ error: "query parameter 'q' is required" }` -- HTTP 422

### Planned Enhancement
A future `GET /api/search?q=...&scope=deep` or separate endpoint would:
- Search `title_tsv` (already implemented)
- Search `description` text (planned)
- Search review summary text (planned, once review enrichment is stored)
- Search `subjects` array (planned)
- Return `ts_headline` snippets with highlighted matches (planned)

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: `Visibility.can_view?(book, viewer)` filters results.
- **Age gate**: Not enforced on search results.
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Read: Full-text search (current)
- **Table(s)**: `op.books`
- **Query**: `fragment("title_tsv @@ plainto_tsquery('english', ?)", ^safe_query)` with `preload([:author, :editions])` and `limit(^limit)`
- **Indexes used**: GIN index on `title_tsv`
- **Schema module**: `Stacks.Books.Book`

### Read: Full-text search (planned extension)
- **Table(s)**: `op.books`, potentially `op.review_summaries` (future table)
- **Query**: Would add `OR description_tsv @@ plainto_tsquery(...)` and join review summary tables
- **Indexes used**: Would need GIN indexes on `description_tsv` and review summary text columns

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- read-only operation.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A for search itself. Review summaries that would be searched are populated by:
- `Stacks.Enrichment.Handlers.BookCreatedHandler` (triggers enrichment pipeline)
- `Stacks.Workers.DbtRefreshHandler` (refreshes analytics models after enrichment events)

---

## 8. External Service Calls

N/A -- search queries local database only.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A -- search results are not cached.

---

## 11. dbt Model Dependencies

N/A currently. Future deep search might query dbt-materialised views that aggregate review data.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Search` (same page as US-1.5.1)
- **URL**: `/search`
- **Public or authenticated**: Authenticated

### Init
Same as US-1.5.1.

### Update cycle
Same as US-1.5.1. No deep search toggle exists in the current implementation.

### Planned Elm changes
To implement this story fully, the following would be needed:
- Add `searchScope : SearchScope` to `Page.Search.Model` with `type SearchScope = TitleOnly | DeepSearch`
- Add `ToggleSearchScope` Msg
- Pass `scope=deep` query parameter to the API when `DeepSearch` is active
- Render matching snippets in results (new `snippet` field on each result)
- Add a "via deep search" badge on results that matched description/review content rather than title

### View
Same as US-1.5.1 in current implementation. See US-1.5.1 for full CSS class and ARIA details.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/search", method="GET", scope="deep"}` | Phoenix.Telemetry | Counter | Increment per deep search request (planned; currently same as US-1.5.1) | N/A (volume baseline) |
| `http.response.status{endpoint="/api/search", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `db.query.count{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Counter | Increment per full-text search query (current) | 1 per search request |
| `db.query.duration{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Histogram (ms) | Current title-only full-text search query execution time | p50 < 20ms, p95 < 100ms |
| `db.query.duration{table="op.books", op="select", index="description_tsv"}` | Ecto.Telemetry | Histogram (ms) | Planned: description full-text search query execution time | p95 < 150ms (planned, wider corpus) |
| `error.rate{endpoint="/api/search"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `search.query_latency{scope="deep"}` | Elm Performance API | Histogram (ms) | Time from API call to `SearchCompleted (Ok _)` for deep search queries | p50 < 300ms, p95 < 800ms (planned; broader corpus than title-only) |
| `search.time_to_results{scope="deep"}` | Elm Performance API | Histogram (ms) | Time from keystroke to results visible (includes 300ms debounce + API + render) | p50 < 700ms, p95 < 1200ms (planned) |
| `search.snippet_render_time` | Elm Performance API | Histogram (ms) | Time to render `ts_headline` snippets with highlighted matches (planned) | p95 < 50ms |
| `search.deep_vs_title_usage` | Elm event tracking | Gauge (%) | Percentage of searches using deep search toggle vs title-only (planned) | Informational (feature adoption) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of deep search queries | Currently same as US-1.5.1 (title-only search). When description/review search is added, CPU cost increases due to broader GIN index scans. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Full-text search across multiple tsvector columns | Current: single GIN index on `title_tsv`. Planned: additional GIN indexes on `description_tsv` and review summary columns. Multi-column tsvector search is more CPU-intensive. `ts_headline` snippet generation adds CPU cost per matched row. |
| Neon DB (PostgreSQL) | Storage (GiB) | GIN index storage for additional tsvector columns | Planned: new GIN indexes on `description_tsv` and review text columns will increase index storage. |
