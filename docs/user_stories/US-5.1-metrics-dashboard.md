# US-5.1 — View the Metrics Dashboard

> **SUPERSEDED (Issue #267).** The in-app `/admin/metrics` operational-metrics dashboard
> described below has been **removed** and replaced by the Grafana observability stack
> (ADR-021, #236–240). `Page.Admin.Metrics`, `Stacks.Admin.Metrics`, `StacksWeb.MetricsController`,
> and the `/api/metrics*` routes no longer exist. The source-health slice survives as
> `StacksWeb.SourceAdminController.source_health/2` (`GET /api/admin/source-health`) feeding the
> scraper-health page (US-2.2.2). This document is retained as prior art for the future
> personal-insights dashboards (#268); do not treat it as describing a live surface.

## 1. User Story

> **As a** user, **I want to** view a transparent operational dashboard **so that** I can see exactly how The Stacks is running, what it costs, and whether all systems are healthy.

The user clicks "Metrics" in the top navigation. The Metrics Dashboard loads -- a custom Elm page with a curator's desk aesthetic. It displays:

- **Source Health**: Per-source operational status table (healthy/degraded/broken)
- **Data Quality**: Cover, price, and review coverage percentages with trend indicators
- **Enrichment Gaps**: Counts of books missing prices, covers, or reviews
- **Cost Tracking**: Itemised cost breakdown by service
- **GDPR**: Images pending deletion count
- **Philosophy**: Closing statement about transparency

The dashboard fetches from 4 API endpoints in parallel, each section using RemoteData independently.

---

## 2. UI Interaction Flow

### Happy Path
1. Owner navigates to `/admin/metrics`.
2. The page fires 4 parallel API calls on init.
3. Each section renders independently as its data arrives.
4. Source Health shows a table of external data sources with status badges (green/amber/red).
5. Data Quality shows coverage percentage cards with trend arrows.
6. Enrichment Gaps shows counts of books with missing data.
7. Cost Tracking shows a ledger-style table of services and amounts.
8. GDPR section shows images pending deletion.

### Sad Paths
- **Individual section failure**: Each section renders its own error independently ("Failed to load X.").
- **All sections fail**: All show error messages; page skeleton still renders.
- **Not authenticated / wrong role**: Auth pipeline blocks with 401/403 before the page loads.

### Elm State Machine
- **Page module**: `Page.Admin.Metrics`
- **Model fields involved**: `dashboard : RemoteData Http.Error MetricsDashboard`, `qualityTrends : RemoteData Http.Error QualityTrends`, `sourceHealth : RemoteData Http.Error (List SourceHealth)`, `enrichmentGaps : RemoteData Http.Error EnrichmentGaps`
- **Msg flow**: 4 parallel `Received` messages, each updating its respective field
- **RemoteData states**: All 4 fields start as `Loading`, transition independently to `Success`/`Failure`
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/metrics`
- **Auth**: Required (MFA-verified admin session)
- **Pipeline**: `:api` -> `:admin` -> `:rate_limit_admin` (the `:admin` pipeline runs `AdminAuthPipeline` + `RequireMFA` + `AuditAdminCall`)
- **Controller**: `StacksWeb.MetricsController.index/2`
- **Response (success)**: `{ data: MetricsDashboard }` — includes `coverPercentage`, `pricePercentage`, `reviewPercentage`, `costs` (list of `{ name, category, amountZar }`), `gdprImagesPending` — HTTP 200
- **Response (error)**: HTTP 401/403

### `GET /api/metrics/quality-trends`
- **Auth**: Required (MFA-verified admin session)
- **Pipeline**: `:api` -> `:admin` -> `:rate_limit_admin` (the `:admin` pipeline runs `AdminAuthPipeline` + `RequireMFA` + `AuditAdminCall`)
- **Controller**: `StacksWeb.MetricsController.quality_trends/2`
- **Response (success)**: `{ data: QualityTrends }` — includes `coverTrend`, `priceTrend`, `reviewTrend` (each "up"/"down"/"stable") — HTTP 200

### `GET /api/metrics/source-health`
- **Auth**: Required (MFA-verified admin session)
- **Pipeline**: `:api` -> `:admin` -> `:rate_limit_admin` (the `:admin` pipeline runs `AdminAuthPipeline` + `RequireMFA` + `AuditAdminCall`)
- **Controller**: `StacksWeb.MetricsController.source_health/2`
- **Response (success)**: `{ data: [SourceHealth] }` — each has `name`, `sourceType`, `status` ("healthy"/"degraded"/"broken"), `consecutiveFailures`, `lastSuccess`, `lastFailure` — HTTP 200

### `GET /api/metrics/enrichment-gaps`
- **Auth**: Required (MFA-verified admin session)
- **Pipeline**: `:api` -> `:admin` -> `:rate_limit_admin` (the `:admin` pipeline runs `AdminAuthPipeline` + `RequireMFA` + `AuditAdminCall`)
- **Controller**: `StacksWeb.MetricsController.enrichment_gaps/2`
- **Response (success)**: `{ data: EnrichmentGaps }` — includes `booksWithoutPrices`, `booksWithoutCovers`, `booksWithoutReviews` (integers) — HTTP 200

### `GET /api/costs` (public cost transparency)
- **Auth**: None
- **Pipeline**: `:api` -> `:rate_limit_public`
- **Controller**: `StacksWeb.CostController.index/2`
- **Response (success)**: `{ data: CostBreakdown }` — includes `total_cents`, `currency`, `cost_per_book`, `categories` (with items), `metrics`, `monthly_totals`, `generated_at` — HTTP 200

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AdminAuthPipeline` -> `RequireMFA` -> `AuditAdminCall` -> `RateLimiter(bucket: :admin)`
- **Visibility checks**: N/A — admin-only
- **Age gate**: N/A
- **Ownership checks**: Role-based via the `:admin` pipeline (admin session + MFA required)

---

## 5. Database Interactions

### Read: Dashboard metrics
- **Table(s)**: Multiple — aggregated by `Stacks.Admin.Metrics.dashboard/0`
- **Query**: Computes coverage percentages, GDPR pending counts, cost aggregations
- **Schema module**: Various — cross-context aggregation

### Read: Source health checks
- **Table(s)**: `op.source_health_checks`
- **Query**: All source health records
- **Schema module**: `Stacks.Monitoring.SourceHealthCheck`

### Read: Quality trends
- **Table(s)**: Computed from historical enrichment data
- **Query**: `Stacks.Admin.Metrics.quality_trends/0`

### Read: Enrichment gaps
- **Table(s)**: `op.books`, `op.price_snapshots`, `op.review_snapshots`
- **Query**: `Stacks.Admin.Metrics.enrichment_gaps/0` — counts books missing prices, covers, reviews
- **dbt model**: ~~`mart_enrichment_gaps` provides the same data for the dbt layer~~ — deleted 2026-10-15 (see §11); nothing provides this for the dbt layer today

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — the metrics dashboard is read-only; it does not emit events.

### Event Handlers Triggered
N/A — dashboard reads are not event-driven. However, the underlying data is populated by event handlers:
- `source_health.recorded` events update `SourceHealthCheck` records
- `enrichment.prices_scraped`, `enrichment.reviews_scraped` events trigger dbt refreshes that feed the dashboard

---

## 7. Background Jobs (Oban)

N/A — the dashboard itself does not enqueue jobs. It reads data populated by:
- `TriggerPriceScrapeJob` (prices)
- `FetchReviewsJob` (reviews)
- `FetchAuthorRSSJob` (author data)
- `DiscoverBookstoreEventsJob` (events)
- `WritingAssistantNudgeWorker` (proactive nudge generation)
- `EmbedPostWorker` / `EmbedShelfPlacementWorker` / `EmbedBookContentWorker` (RAG embedding pipeline)
- `WritingAssistantDataPurgeWorker` (consent revocation purge)
- Monitoring records from all of the above

---

## 8. External Service Calls

N/A — the dashboard reads only from the local database.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A — metrics are computed on each request. No caching layer for dashboard data.

---

## 11. dbt Model Dependencies — SIX OF SEVEN DELETED 2026-10-15

⚠️ This story's consumer (`MetricsController` and the in-app metrics dashboard) was removed when
Grafana superseded it. Every mart below except `mart_cost_tracking` was therefore unread, and all
six were deleted by owner ruling on 2026-10-15 after a verification pass confirmed no Elixir query,
no script, no dbt singular test, no E2E spec and no seed referenced any of them.

| Model | Was consumed by | Disposition |
|---|---|---|
| `mart_enrichment_gaps` | `GET /api/metrics/enrichment-gaps` (removed) | **deleted** — 169 rows, no reader. Its gap-by-cause grouping is the useful half and is recoverable from git history. |
| `mart_system_health` | source-health section of the dashboard | **deleted**. The operational view a person actually reads comes from `Monitoring.list_source_health/0`, which queries the `op.source_health_checks` TABLE directly and is unaffected. |
| `mart_data_freshness` | freshness indicators | **deleted** |
| `mart_data_quality_trend` | quality-trend sparklines | **deleted** — the weekly-rollup-over-12-weeks shape is likewise recoverable from history. |
| `mart_gdpr_compliance` | GDPR section | **deleted** |
| `mart_job_stats` | job-status section | **deleted** |
| `mart_cost_tracking` | cost section | **KEPT** — on forward-looking work that re-points it. ⚠️ It has no consumer today either, and its own `schema.yml` consumer claim was false (`CostController.index` reads the `op.platform_costs` Ecto context, never the mart). A weaker justification than the six deletions', stated rather than hidden. |

**The two with real logic** — `mart_data_quality_trend` and `mart_enrichment_gaps` — were the
mechanism for the "data nutrition label" idea: publish a quality profile per data product
(completeness, freshness, distributions, gaps grouped by cause) rather than a green/amber/red score.
The ruling deleted them and filed that goal as its own work, because the label needs a public
surface that was never built, and keeping two unread marts would not have preserved the goal.

**Also deleted with them:** `int_blog_engagement` (fed only `mart_blog_activity`) and
`int_source_health` (fed only `mart_data_quality_trend`).

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.AdminMetrics`
- **URL**: `/admin/metrics`
- **Public or authenticated**: Authenticated, MFA-verified admin session required

### Init
- **`initPage` branch**: Fires 4 parallel API calls via `Cmd.batch`
- **API calls on init**: `Api.getMetrics`, `Api.getQualityTrends`, `Api.getSourceHealth`, `Api.getEnrichmentGaps`
- **Initial model state**: All 4 fields set to `Loading`; if no token, all set to `NotAsked`

### Update cycle
- **Msg**: `DashboardReceived (Result Http.Error MetricsDashboard)` -> updates `dashboard`
- **Msg**: `QualityTrendsReceived (Result Http.Error QualityTrends)` -> updates `qualityTrends`
- **Msg**: `SourceHealthReceived (Result Http.Error (List SourceHealth))` -> updates `sourceHealth`
- **Msg**: `EnrichmentGapsReceived (Result Http.Error EnrichmentGaps)` -> updates `enrichmentGaps`
- Each updates its field to `Success data` or `Failure err`, no further Cmds.

### View
- **Key elements**:
  - Title: "Metrics Dashboard" with subtitle "The curator's desk..."
  - **Source Health section**: Table with columns: Source, Type, Status (badge: `status-badge--healthy/degraded/broken`), Consecutive Failures
  - **Data Quality section**: Cards for Cover Coverage, Price Coverage, Review Coverage — each shows percentage + trend arrow (up/down/stable)
  - **Enrichment Gaps section**: Cards for "Without Prices", "Without Covers", "Without Reviews" — each shows integer count
  - **Cost Tracking section**: Ledger-style table with columns: Service, Category, Amount (ZAR) — formatted as "R X.XX"
  - **GDPR section**: Card showing "N images pending deletion"
  - **Philosophy**: Italic closing text about measurement and service
  - Each section renders independently based on its RemoteData state
- **ARIA attributes**: N/A
- **CSS classes**: `page page--admin metrics-dashboard`, `metrics-section`, `metrics-section__title`, `metrics-table`, `metrics-cards`, `metrics-card`, `metrics-card__label`, `metrics-card__value`, `metrics-card__trend`, `metrics-philosophy`, `status-badge`

---

## 13. Operational Metrics

- **Oban job counts across all workers**: the dashboard itself aggregates job statistics from `mart_job_stats` — enqueued, completed, failed, retried counts per worker (FetchReviewsJob, TriggerPriceScrapeJob, FetchAuthorRSSJob, DiscoverBookstoreEventsJob, SourceDiscoveryJob, ScoreSourceJob, RegenerateFeedJob, DbtRefreshJob, ListingExpiryJob, WritingAssistantNudgeWorker, EmbedPostWorker, EmbedShelfPlacementWorker, EmbedBookContentWorker, WritingAssistantDataPurgeWorker)
- **External API call counts and latencies**: aggregated from `op.source_health_checks` — per-source status (healthy/degraded/broken), consecutive failures, last success/failure timestamps
- **Circuit breaker states**: `:scraper_fuse`, Together AI fuse, Brave daily budget — all visible via the Source Health table
- **dbt refresh job duration and model counts**: `DbtRefreshJob` execution times and models rebuilt per run — tracked in `mart_job_stats`
- **Dashboard API response times**: 4 parallel endpoints (`/api/metrics`, `/api/metrics/quality-trends`, `/api/metrics/source-health`, `/api/metrics/enrichment-gaps`) — each should respond within 200ms

---

## 14. Performance & Usability Metrics

- **Metrics dashboard load time**: wall-clock time from navigation to all 4 sections rendered — measured by the slowest of the 4 parallel API calls. Target: <1 second total.
- **Enrichment data freshness**: `mart_data_freshness` model provides `last_event_at` per aggregate type — surfaces stale sources
- **Data quality trends**: `mart_data_quality_trend` provides cover/price/review coverage changes over time — trend arrows (up/down/stable) in the UI
- **Enrichment gap trends**: `mart_enrichment_gaps` counts (books without prices, covers, reviews) — should decrease over time as enrichment workers run
- **Source health distribution**: ratio of healthy/degraded/broken sources — target: >80% healthy at all times
- **Cost per book**: `GET /api/costs` provides `cost_per_book` — total platform cost divided by book count

---

## 15. Cost Tracking

- **Fly.io compute** (core app): the dashboard itself is a read-only page — cost is the API response computation. The 4 parallel queries aggregate data from multiple tables and dbt views. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: dashboard queries hit `op.source_health_checks`, `op.books`, `op.price_snapshots`, `op.review_snapshots`, and multiple dbt mart views. Each page load triggers 4 concurrent queries. At low visit frequency (owner-only), cost is negligible. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Public cost endpoint** (`GET /api/costs`): rate-limited but unauthenticated — potential for higher query volume. `mart_cost_tracking` dbt view should be lightweight.
- **dbt model rebuild cost**: the dashboard depends on 7+ dbt models (`mart_enrichment_gaps`, `mart_system_health`, `mart_data_freshness`, `mart_data_quality_trend`, `mart_cost_tracking`, `mart_gdpr_compliance`, `mart_job_stats`). Each rebuild consumes Neon compute. Event-triggered refreshes (not time-based) keep costs proportional to actual data changes.
- **Together AI** (writing assistant): per-token cost for `Llama-3.3-70B-Instruct-Turbo` dialogue + `Meta-Llama-3-8B-Instruct-Lite` classification. Tracked separately from the association worker (`Llama-3-8b-chat-hf`) in `mart_cost_tracking` under category `writing_assistant`.
- **Modal** (writing assistant service): per-invocation compute cost for `apps/writing_assistant`. Tracked in `mart_cost_tracking` under category `writing_assistant`.
- **Neon** (embeddings): GIN index maintenance and vector similarity query compute for `op.embeddings` and `op.book_content_chunks`. Scales with corpus size.
- **Total platform cost visibility**: the dashboard's Cost Tracking section itself tracks all other stories' costs — it is the meta-cost-tracking layer. The `mart_cost_tracking` model aggregates Fly.io, Together AI (by use case), Brave, Modal (by service), and Neon costs into a single ledger view.
