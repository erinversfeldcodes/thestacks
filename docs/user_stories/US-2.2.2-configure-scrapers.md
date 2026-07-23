# US-2.2.2 — Configure Bookshop Scrapers

## 1. User Story

> **As a** user (self-hoster), **I want to** add or modify bookshop scrapers via TOML config files **so that** I can track prices from stores relevant to my country or region.

The user creates or edits a TOML configuration file in the designated scrapers directory (`apps/scraper/scrapers/<country>/<store>.toml`). Each file defines a store using `[source]` (name, type, country, url, currency), `[search]` (method, path, query_param, query_template), `[selectors]` (CSS selectors for price/title/in_stock/currency), and `[rate_limit]` (requests_per_minute, retry_after_seconds, respect_robots_txt) blocks. The Rust scraping microservice reads these configs (hot-reloadable via `POST /config/reload`) and begins scraping on the next scheduled run. After adding a new store config, the store appears in the "Where to Buy" section on book detail overlays once prices have been fetched. The Metrics Dashboard shows the new source in its "Configured Sources" count.

---

## 2. UI Interaction Flow

### Happy Path
1. Self-hoster creates/edits a TOML file in the Rust scraper's config directory.
2. Self-hoster also inserts a corresponding row in `op.bookstores` (name, website_url, search_template, scraper_module, country_code).
3. On the next scheduled `TriggerPriceScrapeJob` batch run, the new store is picked up via `Prices.all_stores()`.
4. Self-hoster navigates to `/admin/scrapers` to monitor scraper health.
5. The `Page.Admin.ScraperConfig` page shows a read-only health dashboard with per-source status.

### Sad Paths
- **Invalid TOML config**: Rust scraper fails to parse; health check records failure via `Monitoring.record_failure/3`; source shows as "degraded" or "broken" in the health table.
- **Store not in database**: If the `op.bookstores` row is missing, no scrape is attempted (store won't appear in `Prices.all_stores()`).
- **Source health load failure**: Page shows "Failed to load source health. Please try again."

### Elm State Machine
- **Page module**: `Page.Admin.ScraperConfig`
- **Model fields involved**: `sourceHealth : RemoteData Http.Error (List SourceHealth)`
- **Msg flow**: `init` -> `Api.getSourceHealth` -> `SourceHealthReceived` -> `Success/Failure`
- **RemoteData states**: NotAsked (no token) / Loading / Success / Failure
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/admin/source-health`
- **Auth**: Required (MFA-verified admin session)
- **Pipeline**: `:api` -> `:admin` -> `:rate_limit_admin`
- **Controller**: `StacksWeb.SourceAdminController.source_health/2` (relocated from the removed `MetricsController` by #267)
- **Request body**: N/A (GET)
- **Response (success)**: `{ data: [{ name, source_type, status, consecutive_failures, last_success, last_failure }] }` — HTTP 200
- **Response (error)**: HTTP 401/403 for auth/role failures
- **FallbackController handling**: Standard auth error tuples

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` -> `RequireRole(role: "owner")`
- **Visibility checks**: N/A — admin-only endpoint
- **Age gate**: N/A
- **Ownership checks**: Role-based (`RequireRole` plug ensures `role: "owner"`)

---

## 5. Database Interactions

### Read: All bookstores
- **Table(s)**: `op.bookstores`
- **Query**: `Prices.all_stores()` — `SELECT * FROM op.bookstores`
- **Schema module**: `Stacks.Enrichment.Bookstore`
- **Schema fields**: `name`, `website_url`, `search_template`, `has_physical`, `country_code` (default "ZA"), `scraper_module`

### Read: Source health checks
- **Table(s)**: `op.source_health_checks` (via `Stacks.Monitoring`)
- **Query**: Filtered by `source_type = "scraper_config"` for scraper-specific health
- **Schema module**: `Stacks.Monitoring.SourceHealthCheck` (generated)

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `source_health.recorded`
- **Aggregate**: `source_health_check` + check ID
- **Payload**: `{ source_name, source_type: "scraper_config", status, consecutive_failures }`
- **Emitted by**: `Stacks.Monitoring.record_success/2` and `Stacks.Monitoring.record_failure/3`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: On `source_health.recorded`, enqueues `DbtRefreshJob` for `["mart_system_health"]`

---

## 7. Background Jobs (Oban)

### TriggerPriceScrapeJob (batch mode)
- **Worker**: `Stacks.Workers.TriggerPriceScrapeJob`
- **Queue**: `:scraper`
- **Args**: `%{"batch" => true}`
- **Max attempts**: 3
- **What it does**: See US-2.2.1 for full details. The new bookstore rows are automatically picked up by `Prices.all_stores()`.
- **On success**: New store prices appear in `PricePipeline` output
- **On failure**: Source health recorded; store appears as degraded/broken in admin

---

## 8. External Service Calls

### Rust scraper service
- **Service**: Rust scraper microservice (`apps/scraper/`)
- **Endpoints**: `GET /health`, `POST /scrape`, `POST /config/reload` (hot-reload TOML configs without restart)
- **Client module**: `Stacks.Enrichment.ScraperClient`
- **Auth**: HMAC (`X-Internal-Token`)
- **Circuit breaker**: `:scraper_fuse`
- **Fallback**: Scrape skipped for blown circuit
- **Mock in test**: `Stacks.Enrichment.MockScraperClient`

---

## 9. Storage (R2 / Local)

N/A — scraper configs are TOML files on disk in the Rust microservice. Bookstore metadata is in the database.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

### `mart_system_health`
- **Model**: `mart_system_health`
- **Trigger**: `source_health.recorded` via `DbtRefreshHandler`
- **Materialisation**: View
- **Consumer**: Metrics dashboard source health section

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.AdminScraperConfig`
- **URL**: `/admin/scrapers`
- **Public or authenticated**: Authenticated, owner role required

### Init
- **`initPage` branch**: Calls `Api.getSourceHealth token SourceHealthReceived`
- **API calls on init**: `GET /api/admin/source-health`
- **Initial model state**: `{ sourceHealth = Loading }`

### Update cycle
- **Msg**: `SourceHealthReceived (Result Http.Error (List SourceHealth))`
- **Model change**: `sourceHealth` transitions to `Success sources` or `Failure err`
- **Cmd**: None
- **OutMsg**: N/A

### View
- **Key elements**:
  - `Loading`: "Loading source health..."
  - `Success` (empty): "No sources configured."
  - `Success` (data): Table with columns: Source, Type, Status (badge), Consecutive Failures, Last Success, Last Failure
  - `Failure`: "Failed to load source health. Please try again."
- **ARIA attributes**: N/A
- **CSS classes**: `page page--admin`, `admin__title`, `metrics-table`, `status-badge--healthy/degraded/broken`

---

## 13. Operational Metrics

- **Oban job counts for `TriggerPriceScrapeJob`** (batch mode): enqueued, completed, failed, retried — new store configs are automatically picked up by batch runs
- **Rust scraper call counts and latencies**: per-store scrape success/failure rates visible in `op.source_health_checks` with `source_type: "scraper_config"`
- **Circuit breaker state**: `:scraper_fuse` events — if a new store config is malformed, repeated failures will trip the fuse affecting all stores
- **Source health recording**: `Monitoring.record_success/2` and `Monitoring.record_failure/3` calls per scraper config, feeding the admin health dashboard
- **dbt refresh job duration**: time to rebuild `mart_system_health` after `source_health.recorded` events

---

## 14. Performance & Usability Metrics

- **Price scrape success rate per store**: critical for new scraper configs — percentage of scrapes returning valid prices vs parse failures (bad CSS selectors, changed page layouts)
- **Source discovery yield**: newly configured stores should produce price data within one batch cycle (cron-dependent)
- **Time to first price**: elapsed time from inserting a new `op.bookstores` row to the first `price_snapshot` appearing for that store
- **Health dashboard load time**: `GET /api/admin/source-health` response latency — single API call, typically <100ms for small source counts

---

## 15. Cost Tracking

- **Rust scraper** (Fly.io compute): each additional store config increases scrape batch size, proportionally increasing compute time. Fly.io shared-cpu-1x: ~$1.94/month base with auto-stop.
- **Neon compute**: additional bookstore rows increase the result set of `Prices.all_stores/0` and the number of `(isbn, store)` pairs processed — more snapshot upserts per batch. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Network egress**: each new store adds outbound HTTP requests from the scraper to the store's website. Fly.io includes 100GB outbound/month free; $0.02/GB after.
- **Marginal cost per store**: approximately linear — each store adds ~N scrape requests per batch (where N = number of stale ISBNs).
