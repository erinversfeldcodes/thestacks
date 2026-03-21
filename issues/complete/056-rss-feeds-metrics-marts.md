# Issue #056: RSS Feeds + Metrics Dashboard Backend

## Summary
Build Atom feed generation per public shelf and the metrics dashboard backend that reads from dbt marts. The last backend sub-phase before the Elm frontend catches up.

## User Stories
US-6.1 (RSS feeds), US-5.1 (metrics dashboard)

## Goal
Each public shelf has an Atom feed that RSS readers can subscribe to. The metrics dashboard surfaces real operational data: system health, job stats, data freshness, costs, GDPR compliance.

## Technical Requirements

**`Stacks.Feeds` context:**
- `generate_atom/2` — builds Atom XML for a given shelf (must be public visibility)
- `StacksWeb.FeedController.show/2` — serves XML with `Content-Type: application/atom+xml`
- Cache with ETag / Last-Modified headers
- `RegenerateFeedJob` (Oban) — event-driven, subscribes to `shelf.book_placed`, `shelf.book_moved`, `shelf.book_removed`
- Feed entries: "Erin moved The Secret History to Library" — title, author, cover thumbnail, timestamp
- OPDS catalogue support (deferred — Atom first)

**`Stacks.Admin.Metrics` context:**
- `get_system_health/0` — uptime, API latency (from PromEx/Telemetry), DB size
- `get_job_stats/0` — per-queue: running, queued, failed counts, next scheduled run
- `get_data_freshness/0` — percentage of prices/reviews/author/events within SLA
- `get_cost_breakdown/0` — reads from `mart_cost_tracking` or `Stacks.Costs`
- `get_gdpr_status/0` — images pending deletion, consent status
- `StacksWeb.MetricsController` — JSON API consumed by Elm metrics page
- Public endpoint: `/api/metrics` (rate limit: 60/min, cacheable)

**PromEx integration:**
- Configure PromEx dashboards for: Phoenix, Ecto, Oban, BEAM
- Custom Telemetry events: `[:stacks, :api, :request]` with duration + endpoint
- API latency P50/P95/P99 per endpoint — read from Telemetry and surface in metrics API

**dbt mart consumption (ADR 010 — this issue is the named consumer for metrics marts):**
- Metrics context reads from `wh.mart_*` views (Issue #052). Per ADR 010, every mart has a named consumer — this issue is the consumer for: `mart_system_health`, `mart_job_stats`, `mart_data_freshness`, `mart_cost_tracking`, `mart_gdpr_compliance`, `mart_data_quality_trend`, `mart_enrichment_gaps`, `mart_llm_faithfulness`, `mart_marketplace_activity`, `mart_transaction_volume`, `mart_blog_activity`
- If marts don't exist yet, gracefully return empty/placeholder data (allows #056 to run in Wave D alongside #052)

**Data quality dashboard enhancements (see `docs/data-quality.md`):**
- `get_quality_trends/0` — reads from `mart_data_quality_trend`, returns 12-week sparkline data per category
- `get_source_health/0` — reads from `int_source_health`, returns per-source status table (name, type, last success, consecutive failures, status)
- `get_enrichment_gaps/0` — reads from `mart_enrichment_gaps`, returns gap counts with drill-down capability
- `get_llm_faithfulness/0` — reads from `mart_llm_faithfulness`, returns confirm/dismiss ratios + confidence distributions
- Metrics API endpoints: `/api/metrics/quality-trends`, `/api/metrics/source-health`, `/api/metrics/enrichment-gaps`
- Per-book quality context in book detail API: "Prices last checked N days ago from M stores" — read from `int_source_health` + `price_snapshots`

## Definition of Done
- [ ] Atom feed per public shelf returns valid XML (validate with feed parser)
- [ ] Feed regenerates when shelf changes (event-driven)
- [ ] ETag/Last-Modified caching headers set correctly
- [ ] Metrics API returns system health, job stats, freshness, costs, GDPR status
- [ ] PromEx exports Prometheus metrics
- [ ] API latency tracked via Telemetry
- [ ] `mix test` passes
- [ ] RSS feed validates as Atom 1.0
- [ ] Metrics API returns quality trend sparkline data
- [ ] Metrics API returns source health table with status per source
- [ ] Metrics API returns enrichment gap counts
- [ ] Book detail API includes per-book quality context (price freshness, source count)

## Dependencies
Issue #046 (shelf data must exist for feeds), Issue #052 (dbt marts for metrics — graceful fallback if not ready)

## Agent Assignment
elixir-agent

## Progress Notes
