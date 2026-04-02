# Issue #119: E2E Test Suite — Metrics Dashboard & RSS Feeds

## Summary
Comprehensive E2E test coverage for the owner-only metrics dashboard (US-5.1) and per-shelf Atom RSS feeds (US-6.1).

## User Stories
US-5.1 (View the Metrics Dashboard), US-6.1 (Subscribe to Shelf RSS Feeds)

## Goal
Validate the metrics dashboard's 4-endpoint parallel load with owner-only access, and RSS feed generation with ETag caching and event-driven regeneration.

## Scope Check
- Does this issue touch more than 3 controllers? No (MetricsController, CostController, FeedController).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (both are read-only public-facing data surfaces).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Metrics dashboard load**: Navigate to `/admin/metrics` -> 4 sections render independently
- **Source Health table**: Status badges (healthy/degraded/broken) with correct CSS classes
- **Data Quality cards**: Coverage percentages with trend arrows (up/down/stable)
- **Enrichment Gaps cards**: Integer counts for books without prices/covers/reviews
- **Cost Tracking ledger**: Service/Category/Amount table with ZAR formatting ("R X.XX")
- **GDPR section**: "N images pending deletion" card
- **Individual section failure**: One section shows error, others render normally
- **RSS icon on bookshelf**: RSS button renders when bookshelf has `visibility: "platform"`
- **RSS popover**: Click RSS button -> popover with feed URL and help text
- **RSS hidden for private shelf**: RSS button does not render when `visibility != "platform"`

### 2. Playwright Navigation & Visual Tests
- **Owner-only guard**: Non-owner authenticated user at `/admin/metrics` gets 401/403
- **Unauthenticated guard**: Unauthenticated user at `/admin/metrics` sees login page
- **Dashboard skeleton**: Page skeleton renders even when all sections fail

### 3. API Endpoint Tests
- `GET /api/metrics` — 200 with `coverPercentage`, `pricePercentage`, `reviewPercentage`, `costs`, `gdprImagesPending`
- `GET /api/metrics/quality-trends` — 200 with `coverTrend`, `priceTrend`, `reviewTrend` (each "up"/"down"/"stable")
- `GET /api/metrics/source-health` — 200 with list of `{ name, sourceType, status, consecutiveFailures, lastSuccess, lastFailure }`
- `GET /api/metrics/enrichment-gaps` — 200 with `booksWithoutPrices`, `booksWithoutCovers`, `booksWithoutReviews`
- All 4 metrics endpoints — 401 without auth, 403 without owner role
- `GET /api/costs` — 200 without auth (public), includes `total_cents`, `currency`, `categories`, `generated_at`
- `GET /api/feeds/:user_id/:bookshelf_name` — 200 with `Content-Type: application/atom+xml` and valid Atom 1.0 XML
- `GET /api/feeds/:user_id/:bookshelf_name` — 304 when `If-None-Match` matches ETag
- `GET /api/feeds/:user_id/:bookshelf_name` — 404 for non-existent bookshelf
- `GET /api/feeds/:user_id/:bookshelf_name` — 403 for non-platform-visible bookshelf
- Feed with no placements — valid Atom XML with no `<entry>` elements
- Feed `Cache-Control: public, max-age=300` header present

### 4. Database Assertion Tests
- `op.source_health_checks` records queried correctly for dashboard
- Enrichment gaps query: count of books missing prices/covers/reviews matches dashboard response
- Feed query: `Shelving.get_bookshelf_books/2` returns placements with preloaded book, author, editions
- Bookshelf visibility check: `bookshelf.visibility == "platform"` required for feed generation

### 5. Event Flow Tests
- N/A for metrics dashboard (read-only)
- Feed regeneration events: `placement.created`, `placement.moved`, `placement.removed` trigger `PlacementHandler`
- `PlacementHandler` enqueues `RegenerateFeedJob` for affected bookshelves
- `placement.moved` enqueues two `RegenerateFeedJob` instances (source + destination)

### 6. Background Job Tests
- N/A for metrics dashboard
- `RegenerateFeedJob` — enqueued with correct `user_id` and `bookshelf_name`
- Job regenerates Atom XML for the specified bookshelf
- Job failure: feed regenerated on-demand by `FeedController`

### 7. External Service Tests
- N/A — both features read from local database only

### 8. Storage Tests
- N/A

### 9. Cache Tests
- N/A for metrics (no caching layer)
- Feed ETag: MD5 of generated XML matches `ETag` response header
- `Cache-Control: public, max-age=300` present
- ETag changes when placements change (new feed content)

### 10. dbt Model Tests
- `mart_enrichment_gaps` view joins `int_book_detail_view` with price/review data
- `mart_system_health` refreshed on `source_health.recorded` events
- `mart_data_freshness` computes `MAX(occurred_at)` per aggregate type
- `mart_data_quality_trend` provides sparkline data
- `mart_cost_tracking` provides cost ledger data — includes `writing_assistant` category covering Together AI dialogue (`Llama-3.3-70B-Instruct-Turbo`) and Modal compute for `apps/writing_assistant`, tracked separately from `post_association` Together AI costs
- `mart_gdpr_compliance` provides GDPR section data
- `mart_job_stats` provides job status counts — includes `WritingAssistantNudgeWorker`, `EmbedPostWorker`, `EmbedShelfPlacementWorker`, `EmbedBookContentWorker`, `WritingAssistantDataPurgeWorker`
- N/A for RSS feeds

### 11. Elm State Machine Tests
- `Page.Admin.Metrics` init: 4 parallel API calls fired via `Cmd.batch`
- All 4 fields start as `Loading`; if no token, all set to `NotAsked`
- `DashboardReceived (Ok data)` -> `dashboard = Success data`
- `QualityTrendsReceived`, `SourceHealthReceived`, `EnrichmentGapsReceived` — same pattern
- Each field transitions independently to `Success` or `Failure`
- `Components.RSSLink` init: `{ showUrl = False }`
- `ToggleUrl` toggles `showUrl` between True and False
- RSS button only renders when `config.visibility == "platform"`

### 12. Metrics & Telemetry Tests
- Dashboard API response times: each of 4 endpoints under 200ms
- `RegenerateFeedJob` Oban counts: enqueued, completed, failed
- Writing assistant worker counts: `WritingAssistantNudgeWorker`, `EmbedPostWorker`, `EmbedShelfPlacementWorker`, `EmbedBookContentWorker`, `WritingAssistantDataPurgeWorker` — all visible in `mart_job_stats`
- Cost ledger: `writing_assistant` category present with Together AI dialogue + Modal compute line items, distinct from `post_association` Together AI costs
- Feed request counts: 200, 304, 403, 404 breakdown
- ETag cache hit rate tracked
- Rate limiter activity for public feed and cost endpoints

## Reviewer Context
- The metrics dashboard uses `RequireRole(role: "owner")` plug — only the platform owner can access it.
- The public cost endpoint (`GET /api/costs`) is unauthenticated and rate-limited separately.
- Feed Atom XML structure uses `urn:stacks:feed:{bookshelf_id}` for feed IDs and `urn:stacks:placement:{placement_id}` for entry IDs.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires metrics dashboard implementation, feed controller, dbt mart models.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
