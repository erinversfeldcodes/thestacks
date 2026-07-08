# US-2.5.1 — Automatic Discovery of New Sources

## 1. User Story

> **As a** user, **I want** the system to automatically find new bookshops, review sites, and communities **so that** my enrichment data stays fresh and comprehensive without manual configuration.

When a new book is added, the Source Discovery Agent is triggered automatically to find sources relevant to that specific book. The agent uses Brave Search API (primary) and self-hosted SearXNG (fallback). An LLM evaluates each discovered source, assigning a confidence score. High-confidence suggestions are queued for user approval. Periodic broad sweeps (quarterly) search for entirely new source types.

The user sees a notification badge: "3 new sources discovered." Clicking through shows suggested sources with name, URL, type, confidence score, and a sample. The user can "Approve" (adds the source) or "Dismiss" each suggestion.

---

## 2. UI Interaction Flow

### Happy Path
1. A book is created, triggering background source discovery.
2. `SourceDiscoveryJob` searches via Brave/SearXNG, creates `DiscoveredSource` records with `status: :pending_review`.
3. `ScoreSourceJob` scores each source via LLM (0.0-1.0 confidence).
4. Platform owner navigates to `/admin/sources`.
5. `Page.Admin.SourceApproval` shows a filterable, paginated table of sources.
6. Owner clicks "Approve" or "Reject" for each pending source.
7. Approved sources begin appearing in enrichment data on subsequent scraping runs.

### Sad Paths
- **Brave budget exhausted**: Falls back to SearXNG automatically.
- **Both search backends fail**: Job returns error, retries up to 3 times.
- **Duplicate URL**: `Discovery.create_source/1` returns `{:error, :duplicate}` — source skipped.
- **LLM scoring failure**: Source retains default confidence (0.5); logged as warning.
- **Source list load failure**: Page shows "Failed to load sources. Please try again."
- **Approve/reject failure**: Error toast "Action failed. Please try again."

### Elm State Machine
- **Page module**: `Page.Admin.SourceApproval`
- **Model fields involved**: `sources : RemoteData Http.Error AdminSourcesResponse`, `statusFilter : StatusFilter`, `page : Int`, `actionInProgress : Maybe String`, `actionError : Maybe String`
- **Msg flow**: `SetStatusFilter` / `PageChanged` -> refetch; `ApproveClicked` -> `Api.approveSource` -> `ApproveCompleted`; `RejectClicked` -> `Api.rejectSource` -> `RejectCompleted`
- **RemoteData states**: Loading / Success / Failure
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/admin/sources`
- **Auth**: Required (owner role)
- **Pipeline**: `:api` -> `:authenticated` -> `:require_owner`
- **Controller**: `StacksWeb.SourceAdminController.index/2`
- **Request params**: `?status=pending&type=bookshop&page=1&per_page=50`
- **Response (success)**: `{ sources: [{ id, name, type, url, confidence, discovered_via, discovered_at, status, approved_at, created_at }], total: N, page: N }` — HTTP 200

### `PUT /api/admin/sources/:id/approve`
- **Auth**: Required (owner role)
- **Pipeline**: `:api` -> `:authenticated` -> `:require_owner`
- **Controller**: `StacksWeb.SourceAdminController.approve/2`
- **Response (success)**: `{ source: { ... } }` — HTTP 200
- **Response (error)**: `{ error: "not_found" }` — HTTP 404; `{ error: "invalid_transition" }` — HTTP 422

### `PUT /api/admin/sources/:id/reject`
- **Auth**: Required (owner role)
- **Pipeline**: `:api` -> `:authenticated` -> `:require_owner`
- **Controller**: `StacksWeb.SourceAdminController.reject/2`
- **Response (success)**: `{ source: { ... } }` — HTTP 200
- **Response (error)**: Same as approve

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` -> `RequireRole(role: "owner")`
- **Visibility checks**: N/A — admin-only
- **Age gate**: N/A
- **Ownership checks**: Role-based via `RequireRole` plug

---

## 5. Database Interactions

### Read: List sources with filtering and pagination
- **Table(s)**: `op.discovered_sources`
- **Query**: `Discovery.list_sources(opts)` — supports `:status`, `:type`, `:page`, `:per_page` filters. Returns `{sources, total_count}`. Ordered by `created_at DESC`.
- **Schema module**: `Stacks.Enrichment.DiscoveredSource`

### Read: Check for duplicate by URL
- **Table(s)**: `op.discovered_sources`
- **Query**: `Discovery.get_source_by_url(url)` — `WHERE url = ?`
- **Indexes used**: Unique constraint on `url`

### Write: Create discovered source
- **Table(s)**: `op.discovered_sources`
- **Operation**: INSERT
- **Changeset validations**: Required: `name`, `type` (enum: bookshop/review_site/community/event_source), `url` (unique), `discovered_at`, `status`. Optional: `confidence` (0.0-1.0)
- **Transaction**: No

### Write: Approve/reject source
- **Table(s)**: `op.discovered_sources`
- **Operation**: UPDATE
- **Changeset validations**: `status_changeset` — validates required `status`, casts `approved_at`/`excluded_at`/`exclusion_email`
- **Transaction**: No — single update + event emission
- **Status lifecycle**: `pending_review -> approved | dismissed | excluded`

### Write: Update confidence score
- **Table(s)**: `op.discovered_sources`
- **Operation**: UPDATE
- **Changeset validations**: `confidence_changeset` — requires `confidence` (0.0-1.0 range)

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### Source discovery
- **Event type**: `enrichment.sources_discovered`
- **Aggregate**: `discovered_source` + first source ID
- **Payload**: `{ count, query, source_ids }`
- **Emitted by**: `Stacks.Workers.SourceDiscoveryJob`
- **Emission method**: `Events.emit_safe/1`

#### Source approved
- **Event type**: `source.approved`
- **Aggregate**: `discovered_source` + source ID
- **Payload**: `{ status: "approved" }`
- **Emitted by**: `Stacks.Discovery.approve_source/1`
- **Emission method**: `Events.emit_safe/1`

#### Source rejected
- **Event type**: `source.rejected`
- **Aggregate**: `discovered_source` + source ID
- **Payload**: `{ status: "dismissed" }`
- **Emitted by**: `Stacks.Discovery.reject_source/1`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
N/A — no handlers currently subscribe to `source.approved` or `enrichment.sources_discovered` events.

---

## 7. Background Jobs (Oban)

### SourceDiscoveryJob
- **Worker**: `Stacks.Workers.SourceDiscoveryJob`
- **Queue**: `:default`
- **Args**: `%{"query" => query}` or `%{"query" => query, "location" => %{"city" => ..., "country_code" => ...}}`
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Calls `BraveClient.search(query, limit: 10)`
  2. If Brave fails or budget exhausted: falls back to `SearxngClient.search(query, limit: 10)`
  3. Filters out duplicate URLs via `Discovery.get_source_by_url/1`
  4. Creates new `DiscoveredSource` records with `status: :pending_review`
  5. Infers source type from title/description keywords (bookshop, community, review_site, event_source)
  6. Sets `discovered_via` to `"search:<query>"` or `"search:<query> location:<city>,<cc>"`
  7. Enqueues `ScoreSourceJob` for each new source
  8. Emits `enrichment.sources_discovered` event
- **On success**: Sources created and scoring enqueued
- **On failure**: Logged; retries up to 3 times

### ScoreSourceJob
- **Worker**: `Stacks.Workers.ScoreSourceJob`
- **Queue**: `:default`
- **Args**: `%{"source_id" => uuid}`
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Fetches source via `Discovery.get_source/1`
  2. Builds a prompt asking Together AI to rate confidence (0.0-1.0) for the source
  3. Calls `together_client.complete/2` with `max_tokens: 64, temperature: 0.1`
  4. Parses numeric confidence from LLM response (clamped to 0.0-1.0, defaults to 0.5 on parse failure)
  5. Updates via `Discovery.update_confidence/2`
  6. Sources scoring > 0.8 are logged for platform owner review
- **On success**: Confidence score persisted
- **On failure**: Logged; source retains nil confidence

---

## 8. External Service Calls

### Brave Search API
- **Service**: Brave Search API
- **Endpoint**: `GET https://api.search.brave.com/res/v1/web/search?q=...&count=...`
- **Client module**: `Stacks.Discovery.BraveClient`
- **Auth**: `X-Subscription-Token` header with API key from `Application.get_env(:core, :brave_search_api_key)`
- **Circuit breaker**: `:brave_fuse` (managed by `Stacks.CircuitBreakers`). Also enforces a daily budget of 67 queries (2000/month free tier) via `:persistent_term` + `:counters`, returning `{:error, :daily_budget_exhausted}` when exceeded.
- **Fallback**: Falls back to SearXNG
- **Mock in test**: Configurable via `Application.get_env(:core, :brave_client)`

### SearXNG (self-hosted)
- **Service**: Self-hosted SearXNG instance
- **Endpoint**: `GET {searxng_url}/search?q=...&format=json&pageno=1&number_of_results=...`
- **Client module**: `Stacks.Discovery.SearxngClient`
- **Auth**: None (self-hosted, unlimited)
- **Circuit breaker**: `:searxng_fuse` (managed by `Stacks.CircuitBreakers`)
- **Fallback**: If also fails, job returns error
- **Mock in test**: Configurable via `Application.get_env(:core, :searxng_client)`

### Together AI (source scoring)
- **Service**: Together AI
- **Endpoint**: `together_client.complete/2`
- **Client module**: `Stacks.AI.TogetherClient`
- **Auth**: API key
- **Circuit breaker**: Standard Together AI circuit breaker
- **Fallback**: Default confidence of 0.5 on failure

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

### `int_source_approval_rate`
- **Model**: `int_source_approval_rate`
- **Trigger**: Manual/periodic dbt run
- **Materialisation**: Intermediate model
- **Consumer**: Metrics dashboard source discovery section

### `int_source_health`
- **Model**: `int_source_health`
- **Trigger**: `source_health.recorded` event
- **Materialisation**: Intermediate model
- **Consumer**: Metrics dashboard source health section

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.AdminSourceApproval`
- **URL**: `/admin/sources`
- **Public or authenticated**: Authenticated, owner role required

### Init
- **`initPage` branch**: Calls `Api.getAdminSources { status, page } token SourcesReceived`
- **API calls on init**: `GET /api/admin/sources`
- **Initial model state**: `{ sources = Loading, statusFilter = All, page = 1, actionInProgress = Nothing, actionError = Nothing }`

### Update cycle
- **Msg**: `SetStatusFilter filter` -> model updates filter + page=1, refetches
- **Msg**: `PageChanged newPage` -> model updates page, refetches
- **Msg**: `ApproveClicked sourceId` -> sets `actionInProgress`, calls `Api.approveSource`
- **Msg**: `ApproveCompleted sourceId result` -> updates the source in the list in-place, clears `actionInProgress`
- **Msg**: `RejectClicked` / `RejectCompleted` -> same pattern as approve

### View
- **Key elements**:
  - Filter tabs: All / Pending / Approved / Rejected
  - `Loading`: "Loading sources..."
  - `Failure`: "Failed to load sources. Please try again."
  - `Success` (empty): "No sources found."
  - `Success` (data): Table with columns: Name, URL, Type, Confidence, Status (badge), Actions (Approve/Reject buttons for pending)
  - Pagination: Previous/Next buttons with "Page N of M"
  - Action error: Red error message
- **ARIA attributes**: N/A
- **CSS classes**: `page page--admin`, `admin__tabs`, `admin__tab--active`, `metrics-table`, `status-badge--healthy/degraded/broken`, `btn btn--primary btn--sm`, `btn btn--danger btn--sm`, `admin__pagination`

---

## 13. Operational Metrics

- **Oban job counts for `SourceDiscoveryJob`**: enqueued (per `book.created` event + quarterly sweeps), completed, failed, retried
- **Oban job counts for `ScoreSourceJob`**: enqueued (one per discovered source), completed, failed, retried
- **Brave Search API call counts and latencies**: per-query duration, daily budget usage (67/day from `:persistent_term` + `:counters`), budget exhaustion events
- **SearXNG call counts and latencies**: fallback query counts when Brave budget is exhausted
- **Together AI call counts and latencies**: `complete/2` calls for source scoring — per-call duration and success/failure
- **Circuit breaker state**: `:brave_fuse` and `:searxng_fuse` open/closed transitions; Brave daily budget exhaustion events; Together AI fuse for scoring failures
- **Duplicate detection rate**: percentage of search results filtered out by `Discovery.get_source_by_url/1` (already-known URLs)
- **dbt refresh job duration**: time to rebuild `int_source_approval_rate` and `int_source_health` models

---

## 14. Performance & Usability Metrics

- **Source discovery yield**: sources found per search query — derivable from `enrichment.sources_discovered` event payloads (`count`)
- **Source approval rate**: ratio of approved to total discovered sources — tracked via `int_source_approval_rate` dbt model
- **LLM scoring quality**: distribution of confidence scores (0.0-1.0) across discovered sources — sources >0.8 flagged for priority review
- **LLM scoring success rate**: percentage of `ScoreSourceJob` runs that produce a valid numeric confidence vs those that default to 0.5 on parse failure
- **Time to approval**: elapsed time from `discovered_at` to `approved_at` — measures platform owner review responsiveness
- **Source type distribution**: breakdown of discovered sources by type (bookshop, review_site, community, event_source)

---

## 15. Cost Tracking

- **Brave Search API**: 2000 free queries/month (67/day budget). Beyond free tier: Basic plan at $3/1000 queries, Pro plan at $5/1000 queries. Each `SourceDiscoveryJob` run consumes 1 query (limit: 10 results).
- **SearXNG**: self-hosted, no per-query API cost. Compute cost is the SearXNG instance on self-hoster infrastructure.
- **Together AI** (source scoring): ~$0.20 per 1M input tokens, ~$0.60 per 1M output tokens (Llama 3.1 8B). Each `ScoreSourceJob` uses ~200 tokens input + ~10 tokens output. Cost per score: <$0.0001. At 100 sources/month: <$0.01/month.
- **Fly.io compute**: core app machine time for `SourceDiscoveryJob` and `ScoreSourceJob` Oban workers. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: queries for duplicate checking (`Discovery.get_source_by_url/1`), source creation, confidence updates, and dbt refreshes. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
