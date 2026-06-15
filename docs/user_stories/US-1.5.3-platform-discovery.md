# US-1.5.3 — Platform-Wide Discovery Search

## 1. User Story

> **As a** user, **I want** my searches to surface results beyond my own collection **so that** I can discover books available from other users, local partners, and the wider platform without leaving the search flow.

**What the user wants to accomplish:** When searching for a book, see not just their own bookshelves but also marketplace listings, partner inventory, other users' public bookshelves, and related Third Spaces events -- all in one place.

**How they accomplish it:**
1. The user types a query in the search bar (US-1.5.1).
2. Local results from the user's collection appear instantly (as before).
3. Concurrently, the system queries the backend for platform-wide matches.
4. Platform-wide results appear in a separate section below the user's collection results.
5. Clicking any result opens the book detail overlay (US-1.4.1).

**What they see on the page:**
- Search dropdown divided into "Your Collection" and "On the Platform" sections.
- External results show contextual labels (marketplace, partner inventory, public bookshelf, event).
- Results respect visibility rules: only public bookshelf content appears.

**Acceptance Criteria:**
- Platform-wide results appear alongside personal collection results.
- External results load asynchronously.
- Visibility rules enforced on all results.

---

## 2. UI Interaction Flow

### Happy Path
1. User types a query on the `/search` page.
2. Current implementation: `Api.searchBooks query token SearchCompleted` fires after 300ms debounce.
3. Results return from `GET /api/search?q=...` -- currently returns all visible books platform-wide (not scoped to user's collection).
4. Results render in `div.search-results`.

### Current Implementation Status
The `SearchController` currently queries all visible books via `Books.search_books/2` (full-text on `title_tsv`) with visibility filtering. It does NOT scope to the user's own collection -- it already returns platform-wide book results. However, it does not yet return marketplace listings, partner inventory, or Third Spaces events.

The frontend `Page.Search` does not yet split results into "Your Collection" vs "On the Platform" sections, nor does it show contextual labels.

### Sad Paths
- Same as US-1.5.1.

### Elm State Machine
- **Page module**: `Page.Search` (same as US-1.5.1)
- **Model fields involved**: Same as US-1.5.1. No separate platform-wide results field exists yet.
- **Msg flow**: Same as US-1.5.1.
- **RemoteData states**: Same as US-1.5.1.
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/search?q=...` (current implementation)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.SearchController.index/2`
- **Request body**: N/A
- **Response (success)**: `{ query: "...", count: N, results: [{ id, title, visibility_tier, author, editions, ... }] }` -- HTTP 200

### `GET /api/catalogue` (related -- public catalogue browsing)
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.CatalogueController.index/2`
- Provides platform-wide book catalogue browsing.

### `GET /api/listings` (related -- marketplace listings)
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.ListingController.index/2`
- Provides marketplace listing search.

### Planned Enhancement
A unified search endpoint or parallel API calls would return:
- Books matching the query (already implemented)
- Active marketplace listings matching the query
- Partner inventory matches
- Public bookshelf placements from other users
- Third Spaces events with matching ISBNs/descriptions

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` (search), `SecurityHeaders` -> `OptionalAuthPipeline` (catalogue/listings)
- **Visibility checks**: `Visibility.can_view?(book, viewer)` filters all results. Public bookshelf placements would additionally filter by bookshelf visibility and placement visibility.
- **Age gate**: Not enforced on search results.
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Read: Full-text search
- **Table(s)**: `op.books`
- **Query**: `title_tsv @@ plainto_tsquery('english', ?)` with preloads and limit
- **Indexes used**: GIN index on `title_tsv`
- **Schema module**: `Stacks.Books.Book`

### Read: Platform-wide discovery (planned)
Additional queries against:
- `op.listings` (marketplace) -- filter by `status = 'active'` and title/author match
- Partner inventory tables (future)
- `op.bookshelf_placements` JOIN `op.bookshelves` -- filter by `bookshelf.visibility = 'platform'` and `placement.visibility = 'platform'`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- read-only operation.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A

---

## 8. External Service Calls

N/A currently. Future implementation might query:
- Partner APIs for real-time inventory checks
- SearXNG / Brave Search for broader web results (as described in the enrichment architecture)

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A currently. Future platform-wide search would likely leverage `dbt/models/marts/mart_platform_searchable.sql` (incremental mart of `int_book_detail_view`) for pre-aggregated, platform-visible book search records.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Search`
- **URL**: `/search`
- **Public or authenticated**: Authenticated for full results

### Init
Same as US-1.5.1.

### Update cycle
Same as US-1.5.1 in current implementation.

### Planned Elm changes
To implement this story fully:
- Add `platformResults : RemoteData Http.Error (List PlatformResult)` to Model
- Add `PlatformSearchCompleted (Result Http.Error (List PlatformResult))` Msg
- Fire parallel API calls: one for personal collection, one for platform-wide results
- Add `type PlatformResult = ListingResult Listing | PublicBookshelfResult BookshelfEntry | PartnerResult PartnerEntry | EventResult Event`
- Split view into "Your Collection" and "On the Platform" sections
- Add contextual labels: "Listed by [username] for R120", "In stock at [partner]", "On [username]'s bookshelf"
- Add shimmer placeholder while platform results load

### View
Same as US-1.5.1 in current implementation. See US-1.5.1 for full CSS class details.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/search", method="GET"}` | Phoenix.Telemetry | Counter | Increment per search request | N/A (volume baseline) |
| `http.request.count{endpoint="/api/catalogue", method="GET"}` | Phoenix.Telemetry | Counter | Increment per catalogue browse request | N/A (volume baseline) |
| `http.request.count{endpoint="/api/listings", method="GET"}` | Phoenix.Telemetry | Counter | Increment per marketplace listing request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/search", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `http.response.status{endpoint="/api/catalogue", status=200}` | Phoenix.Telemetry | Counter | Increment per 200 response | >= 99% of requests |
| `db.query.count{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Counter | Increment per full-text search query | 1 per search request |
| `db.query.duration{table="op.books", op="select", index="title_tsv"}` | Ecto.Telemetry | Histogram (ms) | Full-text search query execution time | p50 < 20ms, p95 < 100ms |
| `db.query.count{table="op.listings", op="select"}` | Ecto.Telemetry | Counter | Increment per marketplace listing query (planned) | Informational |
| `error.rate{endpoint="/api/search"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `search.query_latency{scope="platform"}` | Elm Performance API | Histogram (ms) | Time from API call to platform-wide results rendered (planned: parallel API calls) | p50 < 400ms, p95 < 1000ms (planned) |
| `search.personal_vs_platform_click_ratio` | Elm event tracking | Gauge (%) | Percentage of result clicks on "Your Collection" vs "On the Platform" results (planned) | Informational (feature value) |
| `search.platform_result_count` | API response | Histogram | Number of platform-wide results returned per search (planned) | Informational |
| `search.queries_per_session` | Elm event tracking | Counter per session | Count of search queries fired | Informational (engagement) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of platform discovery searches | Currently single search query. Planned: parallel API calls to search + catalogue + listings endpoints multiply server-side CPU cost per user search. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Full-text search queries + listing queries + public bookshelf queries | Current: single GIN index scan on `title_tsv`. Planned: additional queries against `op.listings` (active listings), `op.bookshelf_placements` (public bookshelf placements), and partner inventory tables. Each additional query source adds CU cost. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Visibility filtering across multiple tables | Platform-wide results require visibility checks on books, placements, bookshelves, and listings. More rows to filter than personal-only search. |
| Partner APIs (future) | API calls | Real-time inventory checks from partner bookshops | Planned: external HTTP calls to partner APIs for live inventory. Cost depends on partner API pricing and call volume. |
