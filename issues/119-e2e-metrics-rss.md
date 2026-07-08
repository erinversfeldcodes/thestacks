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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #119)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #119 covers two user stories —
US-5.1 (View the Metrics Dashboard, `docs/user_stories/US-5.1-metrics-dashboard.md`)
and US-6.1 (Subscribe to Shelf RSS Feeds, `docs/user_stories/US-6.1-rss-feeds.md`).
The matrix is therefore 13 layers × 2 US, happy/sad per cell (52 cells).
The assertion inventory is taken from Issue #119's per-category Technical
Requirements (§1–§12) cross-referenced against each US's §3–§15.

**Feature status:** both features ARE implemented — this is not a greenfield
audit. Existing server surface:
- **Metrics:** `Stacks.Admin.Metrics` (`apps/core/lib/stacks/admin/metrics.ex`),
  `Stacks.Costs` (`apps/core/lib/stacks/costs.ex`),
  `StacksWeb.MetricsController` + `StacksWeb.CostController`, guarded by the
  `:admin` pipeline (`AdminAuthPipeline` + MFA + `AuditAdminCall`) — routes at
  `router.ex:258-264` (`/api/metrics{,/quality-trends,/source-health,/enrichment-gaps}`)
  and public `/api/costs` at `router.ex:87-88`. `Stacks.Workers.RefreshCostsJob`
  (cron `"0 6 * * *"`, `config.exs:52`) populates cost data. Elm page
  `Page.Admin.Metrics` (`frontend/src/Page/Admin/Metrics.elm`), route
  `Route.AdminMetrics` → `/admin/metrics`.
- **RSS:** `Stacks.Feeds` (`apps/core/lib/stacks/feeds.ex`),
  `StacksWeb.FeedController` (`/api/feeds/:user_id/:bookshelf_name`,
  `router.ex:101-102`, public + rate-limited), `Stacks.Feeds.Handlers.PlacementHandler`,
  `Stacks.Workers.RegenerateFeedJob`, Elm `Components.RSSLink`
  (`frontend/src/Components/RSSLink.elm`).

**Auth-model note (US-5.1):** the US doc and implementation use the `:admin`
pipeline (MFA-verified admin session) — *not* a plain `RequireRole("owner")`
plug as Issue #119 §2/Reviewer-Context phrases it. The implemented sad path
returns **401** for a non-MFA owner JWT, not 403. Tests must assert the real
behaviour; the punch list flags the missing "authenticated non-owner → 403"
and per-endpoint unauthenticated-401 cells.

---

### Framework-layer summary

| Layer       | US-5.1 (Metrics) | US-6.1 (RSS) |
|-------------|------------------|--------------|
| Elixir      | ⚠️ (controllers 200/401 covered; context tests fallback-heavy — real-data aggregation, per-endpoint 401, non-owner 403 gaps) | ✅ (feed controller 200/304/404/403, feeds context, PlacementHandler, RegenerateFeedJob all covered) |
| Elm unit    | ❌ (proto decoders only — `ProtoDecoderTest.elm`; zero `Page.Admin.Metrics` state-machine tests) | ⚠️ (`RSSLink` init state appears in `UpdateTest.elm` fixture only; no `ToggleUrl`/visibility-gate test) |
| Elm program | ⚠️ (`CostTransparencyProgramTest.elm` covers the `/costs` sub-surface; the 4-parallel-call `/admin/metrics` dashboard has none) | n/a — RSS is a component, no program/route |
| Python      | n/a — vision service not involved | n/a — feed generation is local |
| E2E         | ❌ (only `costs.spec.ts`; no `/admin/metrics` dashboard/guard spec) | ❌ (no RSS icon/popover/feed-API Playwright spec) |
| dbt         | ⚠️ (all 7 marts exist with generic `not_null`/`unique`; no `accepted_values`/`relationships`) | n/a — feeds read op tables, not dbt |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/controllers/metrics_controller_test.exs` — 11 tests (4 endpoints × 200 + 401 variants)
- `apps/core/test/stacks_web/cost_controller_test.exs` — 2 tests (200 no-auth, no-user-data)
- `apps/core/test/stacks/admin/metrics_test.exs` — 10 tests (per-section + `dashboard/0`, mostly fallback-when-mart-missing)
- `apps/core/test/stacks/costs_test.exs` — 9 tests (upsert, current_period, breakdown, usage_metrics, book_count)
- `apps/core/test/stacks/workers/refresh_costs_job_test.exs` — 3 tests (insert, idempotent, emits `costs.refreshed`)
- `apps/core/test/stacks/ai/budget_tracker_test.exs` — 8 tests (check_budget/record_cost/current_state)
- `apps/core/test/stacks/monitoring/source_health_check_test.exs` — changeset + record_success/failure + unique constraint
- `apps/core/test/stacks/observability_telemetry_test.exs` — fuse + BudgetTracker + Costs cost-recording telemetry
- `apps/core/test/core/prom_ex_custom_metrics_test.exs` — SLO-gate `stacks_*` metric export
- `apps/core/test/stacks_web/controllers/feed_controller_test.exs` — 4 tests (200 Atom, 304, 404, 403)
- `apps/core/test/stacks/feeds_test.exs` — 8 tests (`generate_atom/2` variants + `compute_etag/1`)
- `apps/core/test/stacks/feeds/handlers/placement_handler_test.exs` — 12 tests (created/moved/removed/catch-all/missing)
- `apps/core/test/stacks/workers/regenerate_feed_job_test.exs` — 6 tests (regen, non-existent, owner-skip, missing args)
- `e2e/tests/costs.spec.ts` — 2 tests (public page load w/ `hasCostData` conditional, `/api/costs` no-auth)
- `frontend/tests/ProtoDecoderTest.elm` — `MetricsDashboard`/`EnrichmentGaps`/`SourceHealthCheck` decoder round-trips
- `frontend/tests/Page/CostTransparencyProgramTest.elm` — 7 tests (`/costs` page load/loading/error/banner/story/philosophy/trend)
- `dbt/models/marts/schema.yml` — `mart_{enrichment_gaps,system_health,cost_tracking,data_freshness,data_quality_trend,gdpr_compliance,job_stats}` with `not_null`/`unique` on key columns only

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **15** |
| ⚠️ shallow | **12** |
| ❌ missing | **4** |
| n/a (covered higher up / not applicable / by-design) | **21** |

Split by story: US-5.1 (Metrics) = 4 ✅ / 8 ⚠️ / 3 ❌ / 11 n/a;
US-6.1 (RSS) = 11 ✅ / 4 ⚠️ / 1 ❌ / 10 n/a.

52 cells total (13 layers × 2 US × happy/sad). This is the pre-implementation
baseline; Issue #119's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ✅ metrics_controller_test.exs — "returns 200 with dashboard data for admin-MFA JWT", "returns 200 with quality trends for admin JWT", "returns 200 with source health for admin JWT", "returns 200 with enrichment gaps for admin JWT"; cost_controller_test.exs — "returns 200 with cost breakdown — no auth required" (asserts `data.categories` array). | ✅ | ⚠️ metrics_controller_test.exs — "returns 401 for unauthenticated request" exists ONLY for `GET /api/metrics`; "returns 401 for regular owner JWT (no MFA)" exists on all 4. Missing: per-endpoint unauthenticated-401 for quality-trends/source-health/enrichment-gaps, and an authenticated-non-owner **403** (Issue §3 asks "403 without owner role" — untested; only no-MFA 401 is). | ⚠️ |
| 6.1 | ✅ feed_controller_test.exs — "returns 200 with Atom XML for a platform-visible bookshelf" (asserts `content-type: application/atom+xml`, `etag` header, `<feed xmlns=`, and the seeded book title in body). | ✅ | ✅ feed_controller_test.exs — "returns 404 for nonexistent bookshelf" (`{"error" => "Bookshelf not found"}`), "returns 403 for non-platform-visible bookshelf" (error contains "platform-visible"), "returns 304 Not Modified when ETag matches". Empty-placements-valid-Atom is covered at context level (feeds_test — "returns valid XML with empty bookshelf"). | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ✅ metrics_controller_test.exs — admin-MFA JWT passes the `:admin` pipeline for all 4 endpoints; cost_controller_test.exs — "returns 200 ... no auth required" exercises the public `:rate_limit_public` path. | ✅ | ⚠️ Only the `:admin`-pipeline 401 (missing MFA) is tested ("returns 401 for regular owner JWT (no MFA)"). The Issue §2 E2E guards — non-owner authenticated user at `/admin/metrics` → 401/403, and unauthenticated → login page — are **not** tested in Playwright (no `metrics.spec.ts`). No authenticated-non-owner 403 at HTTP level either. | ⚠️ |
| 6.1 | ✅ feed_controller_test.exs — bare unauthenticated conn reaches `FeedController.show/2` (public endpoint, `router.ex:101-102`); visibility guard exercised. | ✅ | ✅ feed_controller_test.exs — "returns 403 for non-platform-visible bookshelf"; feeds_test.exs — "returns {:error, :not_public} for owner-visibility bookshelf" + "... for group-visibility bookshelf" (both non-`platform` visibilities blocked). | ✅ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ⚠️ admin/metrics_test.exs — "dashboard/0 returns aggregated dashboard with all sections", "source_health/0 returns a list of source health entries", "job_stats/0 returns a list"; costs_test.exs — "current_period_costs/0 returns costs for the current month", "cost_breakdown/0 returns a complete breakdown map"; source_health_check_test.exs covers `op.source_health_checks` reads/writes. BUT most `Admin.Metrics` per-section tests assert the **fallback-when-mart-missing** branch, not real aggregation. Issue §4's "enrichment gaps count over seeded books missing prices/covers/reviews matches dashboard response" is NOT asserted (enrichment_gaps/0 only tests "returns fallback map when mart does not exist"). | ⚠️ | n/a — the dashboard is read-only; the only DB "sad path" is empty/missing-mart, which is the fallback branch already covered under happy. No mutation to roll back. |
| 6.1 | ✅ feed_controller_test.exs seeds real bookshelf + author + book + edition + placement and asserts the title renders in the feed; feeds_test.exs — "generate_atom/2 returns {:ok, xml, etag}" reads bookshelf + placements with preloaded book/author/editions via `Shelving.get_bookshelf_books/2`. | ✅ | ✅ feeds_test.exs — "returns {:error, :not_found} for nonexistent bookshelf", "returns valid XML with empty bookshelf" (no placements), and the visibility-rejection variants. | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 5.1 | n/a — the metrics dashboard is read-only and emits no events (US-5.1 §6). Upstream events that *populate* the data (`source_health.recorded`, enrichment events) are audited under their own stories. | n/a — same. |
| 6.1 | ✅ placement_handler_test.exs — "placement.created extracts bookshelf name and enqueues RegenerateFeedJob (string keys)" + "(atom keys)"; "placement.moved enqueues jobs for both source and destination bookshelves (string + atom keys)" + "deduplicates when source and destination are the same". | ✅ placement_handler_test.exs — "placement.removed handles nil bookshelf name gracefully (no job enqueued)", "catch-all returns :ok for unrelated events" + "for events with no event_type key", "returns :ok when aggregate_id does not match a placement". |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ✅ refresh_costs_job_test.exs — "perform/1 inserts cost line items and returns :ok" (populates the cost section the dashboard reads). | ✅ | ⚠️ refresh_costs_job_test.exs — "is idempotent — running twice does not duplicate records" + "emits costs.refreshed event". BUT the cron registration `{"0 6 * * *", Stacks.Workers.RefreshCostsJob}` (`config.exs:52`) has no test asserting the crontab entry (analogous to the marketplace cron gap). | ⚠️ |
| 6.1 | ✅ regenerate_feed_job_test.exs — "perform/1 — platform-visible bookshelf regenerates feed and returns :ok". RegenerateFeedJob is event-triggered (via PlacementHandler), not cron — no crontab entry to assert. | ✅ | ✅ regenerate_feed_job_test.exs — "returns {:cancel, _} when user/bookshelf not found", "returns :ok and skips feed generation for non-public shelf", "returns {:cancel, _} for empty args" + missing-`bookshelf_name` + missing-`user_id`. | ✅ |

#### Layer 6: External Service Calls

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 5.1 | n/a — the dashboard reads only the local database (US-5.1 §8); no vision/ISBN/scraper calls. | n/a — same. |
| 6.1 | n/a — feed generation is entirely local (US-6.1 §8); no external APIs. | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 5.1 | n/a — no object storage in the dashboard path (US-5.1 §9). | n/a — same. |
| 6.1 | n/a — feed XML is generated on-demand / by job; no persistent storage of feed content (US-6.1 §9). | n/a — same. |

#### Layer 8: Cache Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | n/a — metrics are computed on each request; no caching layer for dashboard data (US-5.1 §10). | n/a | n/a — same. | n/a |
| 6.1 | ⚠️ ETag mechanism covered: feed_controller_test.exs — "returns 200 ... etag header present"; feeds_test.exs — "compute_etag/1 returns consistent MD5 hash for same content" + "returns different hash for different content" (proxy for cache invalidation on placement change). BUT the `Cache-Control: public, max-age=300` header (US-6.1 §10, Issue §9) is **never asserted** in any test, and there is no controller-level "ETag changes when placements change" test. | ⚠️ | ✅ feed_controller_test.exs — "returns 304 Not Modified when ETag matches" (the cache-hit path: first request captures ETag, second sends `If-None-Match`). | ✅ |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ⚠️ All 7 dashboard marts exist and are registered in `dbt/models/marts/schema.yml`: `mart_enrichment_gaps`, `mart_system_health`, `mart_cost_tracking`, `mart_data_freshness`, `mart_data_quality_trend`, `mart_gdpr_compliance`, `mart_job_stats`, each with `not_null`/`unique` on its key column(s). | ⚠️ | ❌ Zero `accepted_values` tests anywhere in the marts schema (`grep -c accepted_values` = 0) — `mart_system_health.status` (healthy/degraded/broken) and `mart_cost_tracking.category` (Issue §10 names `writing_assistant` vs `post_association`) are unconstrained; no `relationships` test `mart_enrichment_gaps.book_id → stg_books.id`; no singular test under `dbt/tests/singular/` references any dashboard mart. (Caveat for the fix: `stg_*` schema.yml is proto-generated by `mix proto.sync`; mart schema.yml is hand-authored, so mart tests can be added directly, but singular tests are the safest home for cross-mart assertions.) | ❌ |
| 6.1 | n/a — feed generation reads operational tables directly, not dbt models (US-6.1 §11). | n/a | n/a — same. | n/a |

#### Layer 10: Elm Frontend State Machine

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ❌ `Page.Admin.Metrics` (`frontend/src/Page/Admin/Metrics.elm`) exists but has **zero** state-machine tests. `ProtoDecoderTest.elm` covers only the wire decoders (`MetricsDashboard`, `EnrichmentGaps`, `SourceHealthCheck` — encode/decode round-trips), not init/update. Issue §11 assertions (init fires 4 parallel `Api.get*` via `Cmd.batch`; all 4 fields `Loading`, `NotAsked` if no token; each `*Received (Ok _)` → `Success` independently) are untested. `CostTransparencyProgramTest.elm` covers the `/costs` sub-surface only ("load_costs", "total_banner", "story_cards", "monthly_trend"). | ❌ | ❌ No per-section failure tests: `DashboardReceived (Err _)` / `QualityTrendsReceived (Err _)` etc. rendering their own error independently, nor the "page skeleton renders even when all sections fail". `CostTransparencyProgramTest.elm` — "error_state: shows error message on HTTP failure" covers only `/costs`. | ❌ |
| 6.1 | ⚠️ `Components.RSSLink` (`frontend/src/Components/RSSLink.elm`) exists; its init state `{ showUrl = False }` appears only as a fixture field in `UpdateTest.elm:26`. No test drives `ToggleUrl` (toggles `showUrl`) or asserts the popover renders the feed URL + "Subscribe in your RSS reader:" when `visibility == "platform"`. | ⚠️ | ❌ No test that `RSSLink` renders nothing (`text ""`) when `visibility /= "platform"` (US-6.1 §2 sad path / Issue §1 "RSS hidden for private shelf"). | ❌ |

#### Layer 11: Operational Metrics

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ⚠️ The dashboard IS the operational-metrics surface, and the aggregators are tested shallowly: admin/metrics_test.exs — "job_stats/0 returns a list", "source_health/0 returns a list of source health entries". BUT Issue §12 requires the enumerated workers (`WritingAssistantNudgeWorker`, `EmbedPostWorker`, `EmbedShelfPlacementWorker`, `EmbedBookContentWorker`, `WritingAssistantDataPurgeWorker`) to be visible in `mart_job_stats` and the `writing_assistant` cost category distinct from `post_association` — none of these specific rows is asserted. Per-route latency/SLI is covered by the SLO gate (prom_ex_custom_metrics_test.exs — "PromEx exports custom stacks_* metrics the SLO gate scraper reads"; `scripts/check-slo-gate.sh` scrapes `/internal/metrics`). | ⚠️ | ⚠️ observability_telemetry_test.exs covers fuse + BudgetTracker + Costs cost-recording telemetry, but there is no instrumentation/test for the dashboard-specific counters Issue §12 lists (dashboard endpoint response-time firing, per-worker job counts). Feature-adjacent gap. | ⚠️ |
| 6.1 | ⚠️ Generic Oban telemetry for `RegenerateFeedJob` (enqueued/completed/failed) flows through the SLO gate + automatic Oban telemetry — no per-US firing test needed there. BUT Issue §12 "feed request counts: 200/304/403/404 breakdown" and "ETag cache hit rate tracked" require dedicated instrumentation that does not exist in `FeedController` and is untested. | ⚠️ | ⚠️ Same — feed-request-outcome and ETag-hit-rate counters are neither instrumented nor tested (feature gap, not merely a test gap). | ⚠️ |

#### Layer 12: Performance & Usability Metrics

| US    | Happy Path | Sad Path |
|-------|------------|----------|
| 5.1 | n/a — covered by the SLO gate, not unit tests; Issue §12 "each endpoint under 200ms" and US-5.1 §14 "<1s load" are in-test SLA bounds, an anti-pattern under variable CI timing. Freshness/trend are dashboard concerns derived from `mart_data_freshness` / `mart_data_quality_trend`. | n/a — same. |
| 6.1 | n/a — SLO gate territory; US-6.1 §14 targets (<100ms feed gen, feed size, subscriber count) are operational SLIs, not unit assertions. | n/a — same. |

#### Layer 13: Cost Tracking

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|------------|---------|----------|---------|
| 5.1 | ✅ **at unit/context level:** costs_test.exs — "cost_breakdown/0 returns a complete breakdown map with categories and metrics", "usage_metrics/0 returns aggregate platform metrics without user data", "book_count/0"; refresh_costs_job_test.exs — "inserts cost line items", "is idempotent", "emits costs.refreshed event"; `BudgetTracker.record_cost` feeds cost data (budget_tracker_test.exs — "accumulates costs across multiple calls", "tracks costs per provider"). **❌ at E2E-with-data:** `e2e/tests/costs.spec.ts` gates ALL cost-value assertions (banner amount, category cards, story cards) behind `const hasCostData = (await page.getByTestId('costs-category-card').count()) > 0` (lines 25-28). On preview deploys there is **no cost data** — the boot-time `Task.start` seed was removed in #101, and `RefreshCostsJob` only runs on the `"0 6 * * *"` cron. So the with-data assertions never execute on preview. **BLOCKED on #110's cost-data fixture** — landing that fixture flips this cell to ✅ once the `hasCostData` conditional is removed and the costs E2E test is un-conditionalised. | ⚠️ (blocked on #110 for the E2E-with-data path) | ✅ costs_test.exs — "rejects invalid category", "rejects negative amount"; budget_tracker_test.exs — "returns daily_limit_exceeded when over daily limit", "returns monthly_limit_exceeded when over monthly limit". | ✅ |
| 6.1 | n/a — feed generation has no external API costs (US-6.1 §15 — "No external API costs"); Fly/Neon compute is covered by the cost dashboard, no per-call spend to record. | n/a | n/a — same. | n/a |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-5.1 sad | Per-endpoint unauthenticated-401 for `/api/metrics/quality-trends`, `/source-health`, `/enrichment-gaps` (currently only `/api/metrics` has it); plus an authenticated-non-owner **403** test — note the implemented guard returns 401 for missing MFA, so decide whether "non-owner with MFA → 403" is a real path and assert the actual status. | `apps/core/test/stacks_web/controllers/metrics_controller_test.exs` |
| 2 | L2 US-5.1 sad (E2E) | Playwright: non-owner authenticated user at `/admin/metrics` gets 401/403; unauthenticated user sees login page (Issue §2). | new `e2e/tests/metrics.spec.ts` |
| 3 | L3 US-5.1 happy | Real-data aggregation: seed books missing prices/covers/reviews and assert `Admin.Metrics.enrichment_gaps/0` (and the dashboard response) counts match (Issue §4) — not just the fallback-when-mart-missing branch. | `apps/core/test/stacks/admin/metrics_test.exs` |
| 4 | L5 US-5.1 sad | Assert `RefreshCostsJob` is registered in the Oban cron plugin config (`"0 6 * * *"`, `config.exs:52`). | `apps/core/test/stacks/workers/refresh_costs_job_test.exs` |
| 5 | L9 US-5.1 happy/sad | `accepted_values` on `mart_system_health.status` (healthy/degraded/broken) and `mart_cost_tracking.category` (incl. `writing_assistant` vs `post_association`); `relationships` `mart_enrichment_gaps.book_id → stg_books.id`. Mart schema.yml is hand-authored (not proto-generated), so add directly or as singular tests under `dbt/tests/singular/`. | `dbt/models/marts/schema.yml` and/or `dbt/tests/singular/` |
| 6 | L10 US-5.1 happy | Elm state-machine tests for `Page.Admin.Metrics`: init fires 4 parallel `Api.getMetrics/getQualityTrends/getSourceHealth/getEnrichmentGaps` via `Cmd.batch`; all 4 fields start `Loading` (`NotAsked` when no token); each `*Received (Ok _)` → `Success` independently. | new `frontend/tests/Page/AdminMetricsProgramTest.elm` |
| 7 | L10 US-5.1 sad | Elm failure-state tests: each `*Received (Err _)` renders its own error independently; page skeleton renders when all 4 sections fail. | same file as #6 |
| 8 | L11 US-5.1 | Assert `mart_job_stats` surfaces the enumerated workers (`WritingAssistantNudgeWorker`, `EmbedPostWorker`, `EmbedShelfPlacementWorker`, `EmbedBookContentWorker`, `WritingAssistantDataPurgeWorker`) and that the `writing_assistant` cost category is distinct from `post_association` (Issue §12); tighten `job_stats/0`/`source_health/0` beyond "returns a list". | `apps/core/test/stacks/admin/metrics_test.exs` + `dbt` mart tests |
| 9 | L1/L10 US-5.1 (E2E) | Playwright metrics-dashboard UI (Issue §1): 4 sections render independently; Source Health status badges (`status-badge--healthy/degraded/broken`); Data Quality trend arrows; Enrichment Gaps integer cards; Cost Tracking ledger with ZAR ("R X.XX"); GDPR "N images pending deletion"; individual-section-failure (one errors, others render). | new `e2e/tests/metrics.spec.ts` |
| 10 | L13 US-5.1 happy (E2E) | **BLOCKED on #110.** `e2e/tests/costs.spec.ts` gates all cost-value assertions behind `hasCostData` (lines 25-28) because preview deploys have no cost data (boot `Task.start` seed removed in #101; `RefreshCostsJob` only runs `"0 6 * * *"`). Once #110's cost-data fixture lands, remove the `hasCostData` conditional and assert banner amount / category cards / story cards unconditionally — this flips the cell to ✅. Do NOT un-conditionalise before the fixture exists. | `e2e/tests/costs.spec.ts` (after #110) |
| 11 | L8 US-6.1 happy | Assert `Cache-Control: public, max-age=300` header on the feed response (US-6.1 §10, Issue §9 — currently unasserted); add a controller-level "ETag changes when placements change" test. | `apps/core/test/stacks_web/controllers/feed_controller_test.exs` |
| 12 | L10 US-6.1 happy | `Components.RSSLink` Elm test: `ToggleUrl` toggles `showUrl`; when `visibility == "platform"` the popover renders the feed URL (`/api/feeds/{userId}/{bookshelfName}`) + "Subscribe in your RSS reader:" help text. | new `frontend/tests/RSSLinkTest.elm` |
| 13 | L10 US-6.1 sad | `Components.RSSLink` renders nothing (`text ""`) when `visibility /= "platform"` (Issue §1 "RSS hidden for private shelf"). | same file as #12 |
| 14 | L11 US-6.1 | Decide + implement: instrument feed-request outcome counts (200/304/403/404) and ETag cache-hit rate (Issue §12/§13), then add firing tests (pattern: `upload_telemetry_test.exs`); or formally descope §12 and reclassify n/a. **Partially blocked on feature implementation** — no such counters exist in `FeedController` yet. | `apps/core/lib/stacks_web/controllers/feed_controller.ex` + new telemetry test |
| 15 | L1/L10 US-6.1 (E2E) | Playwright RSS flow (Issue §1/§2): RSS icon renders on a `platform`-visible bookshelf, popover shows feed URL, hidden for private shelf; feed API via `request` — 200 `application/atom+xml`, 304 on `If-None-Match`, 404 unknown bookshelf, 403 non-platform. | new `e2e/tests/rss.spec.ts` (or fold into `metrics.spec.ts`) |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 2-US matrix (52 cells): **15 ✅ / 12 ⚠️ / 4 ❌ / 21 n/a.**

**Headline findings:**
1. **US-6.1 (RSS) is in genuinely good server-side shape** — 11 ✅: the feed
   controller (200 Atom / 304 / 404 / 403), the `generate_atom/2` + `compute_etag/1`
   context, `PlacementHandler` fan-out (created/moved/removed, source+dest dedup),
   and `RegenerateFeedJob` (happy + all cancel paths) are all covered. The gaps
   are the un-asserted `Cache-Control: max-age=300` header and the **entirely
   untested `Components.RSSLink`** (no `ToggleUrl`, no visibility gate).
2. **US-5.1 (Metrics) is the weaker story** — the controller returns are tested
   but the `Admin.Metrics` context tests are **fallback-heavy** (they assert the
   "mart does not exist" branch rather than real aggregation over seeded data),
   the **Elm dashboard has zero state-machine tests** (only proto decoders +
   the separate `/costs` program test), and there is **no Playwright coverage**
   of the dashboard UI or its owner-only/unauthenticated guards.
3. **dbt marts exist but are loosely constrained** — all 7 dashboard marts are
   present with `not_null`/`unique` only; **zero `accepted_values` and zero
   `relationships`** across the entire marts schema.
4. **Auth-model mismatch to flag during implementation:** Issue #119 speaks of
   `RequireRole("owner")` and "403 without owner role", but the shipped guard is
   the `:admin` MFA pipeline returning **401**. Tests must assert reality.

**Layer 13 / #110 dependency (explicit):** the cost-tracking cells are ✅ at the
unit/context level (`costs_test.exs`, `refresh_costs_job_test.exs`,
`budget_tracker_test.exs`), but the **costs-dashboard-WITH-DATA E2E path is
blocked**: `e2e/tests/costs.spec.ts` conditionally skips every cost-value
assertion via `hasCostData` (lines 25-28) because preview deploys carry no cost
data (boot `Task.start` seed removed in #101; `RefreshCostsJob` fires only on the
`"0 6 * * *"` cron). **Issue #110's cost-data fixture is the unblocker** — once it
lands, the `hasCostData` conditional is removed and the costs E2E test is
un-conditionalised, flipping punch-list item #10 (L13 US-5.1 happy) to ✅. Until
then it is correctly marked ⚠️/blocked, not ❌-for-missing-feature.

**Test runner totals at baseline (metrics/RSS-related):** Elixir ~63 tests
across 12 files (metrics/costs/feeds/handlers/jobs/monitoring/telemetry), Elm
7 proto-decoder + 7 `/costs` program tests (0 dashboard/RSSLink tests),
Playwright 2 costs tests (0 metrics/RSS specs), dbt generic column tests on 7
marts (0 `accepted_values`/`relationships`). Punch list: **15 items**, of which
#10 is blocked on #110's fixture and #14 is partially blocked on feed telemetry
instrumentation.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires metrics dashboard implementation, feed controller, dbt mart models.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
