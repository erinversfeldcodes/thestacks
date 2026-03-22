# Issue #052: dbt Intermediate + Mart Models

## Summary
Create all dbt intermediate and mart models following the **contract-first derived data** pattern (ADR 010). Each model has a named consumer, a refresh strategy (event-triggered or daily cron catch-all), and an explicit materialisation choice (view, incremental, or materialized_view).

## User Stories
US-2.1.1 (reviews), US-2.2.1 (prices), US-5.1 (metrics), US-18.1.1 (community wear), US-1.5.3 (platform search)

## Goal
The `wh` schema contains pre-computed views for all analytical and aggregation queries. No controller reads directly from `op` for analytical data. The metrics dashboard, community wear state, and platform search all read from marts.

## Technical Requirements

**Intermediate models (`dbt/models/intermediate/`):**
- `int_price_trends.sql` — price over time per edition per store
- `int_review_sentiment.sql` — unified reviews with sentiment scores
- `int_author_activity.sql` — author + recent RSS posts + events
- `int_event_matches.sql` — events matched to user book/author graph
- `int_book_engagement.sql` — wear level computation from placement history
- `int_book_detail_view.sql` — pre-joined work + editions + latest prices + reviews
- `int_source_approval_rate.sql` — discovery agent effectiveness
- `int_partner_availability.sql` — partner stock per edition (placeholder — partners deferred)
- `int_blog_engagement.sql` — which books users write about most
- `int_visibility_resolution.sql` — audit/debugging view for visibility decisions

**Mart models (`dbt/models/marts/`):**
- `mart_book_reviews.sql` — consumer-facing review summary per work
- `mart_book_prices.sql` — consumer-facing price comparison per edition
- `mart_community_read_count.sql` — `book_id, read_count` (distinct users with book on Library shelf). **Refreshes every 5 min** via Oban-triggered `dbt run --select mart_community_read_count`.
- `mart_platform_searchable.sql` — denormalised search index across all public content. **Refreshes every 5 min**.
- `mart_system_health.sql` — uptime, latency, DB size
- `mart_job_stats.sql` — Oban job health per queue
- `mart_data_freshness.sql` — percentage of data within SLA per category
- `mart_cost_tracking.sql` — itemised costs from billing APIs
- `mart_gdpr_compliance.sql` — images pending deletion, consent status
- `mart_marketplace_activity.sql` — listing velocity, sale count
- `mart_transaction_volume.sql` — revenue tracking
- `mart_blog_activity.sql` — post count, association count

**Data quality models (see `docs/data-quality.md`):**
- `int_source_health.sql` — per external source: `source_name`, `source_type`, `last_success_at`, `last_failure_at`, `consecutive_failures`, `selector_match_rate`, `status ENUM(healthy, degraded, broken)`. Thresholds: 3+ consecutive failures → degraded, 7+ → broken.
- `mart_data_quality_trend.sql` — weekly rollup per enrichment category: price freshness %, review freshness %, author completeness %, event match rate %. 12-week rolling window. Alert if any category drops >10 percentage points week-over-week.
- `mart_enrichment_gaps.sql` — books with zero prices (grouped by cause: no config, config broken, store doesn't stock), books with zero reviews, authors with no RSS/website. Exposed on metrics dashboard with drill-down.
- `mart_llm_faithfulness.sql` — review summary: URL validation pass rate, confidence distribution. Blog associations: confirm/dismiss ratio per week, mean confidence. Source discovery: approval rate for high-confidence suggestions.

**`DbtRefreshJob` — event-triggered selective refresh (ADR 010):**

`Stacks.Workers.DbtRefreshJob` is an Oban worker on the `dbt_refresh` queue (concurrency 1) that supports two trigger modes:

1. **Event-triggered selective rebuild.** Register in `Events.Registry` for enrichment completion events. On receipt, run `dbt run --select <model_list>` for only the affected models:

   | Event | Emitted by | Models rebuilt |
   |-------|-----------|---------------|
   | `shelf.book_placed`, `shelf.book_moved` | Shelving context (#046) | `mart_community_read_count`, `mart_platform_searchable` |
   | `enrichment.prices_scraped` | `PricePipeline` (#050) | `int_price_history`, `mart_book_prices` |
   | `enrichment.reviews_scraped` | `FetchReviewsJob` (#050) | `int_review_sentiment`, `mart_book_reviews` |
   | `enrichment.author_updated` | `FetchAuthorRSSJob` (#051) | `int_author_activity` |
   | `enrichment.events_discovered` | `DiscoverBookstoreEventsJob` (#051) | `int_event_matches` |
   | `source_health.recorded` | `SourceHealth` (#068) | `int_source_health`, `mart_data_quality_trend` |
   | `post.published`, `post.updated` | Blog context (#053) | `int_blog_engagement`, `mart_blog_activity` |

2. **Daily cron catch-all.** Oban.Cron triggers a full `dbt run` once daily to ensure eventual consistency. Catches any models not covered by event triggers.

- Event-to-model mapping centralised in a `@model_mapping` module attribute inside `DbtRefreshJob` — not scattered across event handlers
- Job uniqueness: use `Oban.Job` unique constraint on `(event_type, period: 300)` to coalesce rapid-fire events into a single dbt run per 5-minute window
- Hot-path marts (`mart_community_read_count`, `mart_platform_searchable`) target ≤ 5 min latency
- `dbt_refresh` Oban queue: concurrency 1 (sequential dbt runs — no parallel dbt execution)

**Materialisation strategy (ADR 010):**
- Staging: `VIEW` (already complete)
- `int_price_history`: `incremental` (unbounded growth: editions × stores × days)
- `mart_community_read_count`, `mart_platform_searchable`: `incremental` or `materialized_view` with `REFRESH CONCURRENTLY` (5-min refresh, non-locking)
- `mart_data_quality_trend`: `incremental` (12-week rolling window — append new, drop oldest)
- All others: `VIEW` or daily `table` depending on query complexity

**Schema tests:**
- `schema.yml` for all intermediate and mart models with column descriptions
- `dbt-assertions` row-level checks where applicable (e.g., `mart_community_read_count.read_count >= 0`)

## Definition of Done
- [ ] `dbt run` succeeds for all intermediate + mart models
- [ ] `dbt test` passes with schema + row-level assertions
- [ ] `mart_community_read_count` returns correct counts (verified against test data)
- [ ] `mart_platform_searchable` contains expected public content
- [ ] `DbtRefreshJob` Oban worker registered in `Events.Registry` for all enrichment events
- [ ] Event-to-model mapping in `@model_mapping` covers all event types from table above
- [ ] Event-triggered selective refresh: emitting `enrichment.prices_scraped` triggers only `int_price_history` + `mart_book_prices` (not a full run)
- [ ] Job uniqueness coalesces rapid-fire events within 5-minute window
- [ ] Daily cron catch-all runs full `dbt run` and succeeds
- [ ] 5-minute refresh configured for hot-path marts
- [ ] Incremental models (`int_price_history`, `mart_data_quality_trend`): test that new data appends correctly without full rebuild
- [ ] Incremental models: `dbt run --full-refresh` works as escape hatch
- [ ] Hot-path marts: verify non-locking refresh (either dbt incremental or `REFRESH CONCURRENTLY`)
- [ ] All models documented in `schema.yml`
- [ ] `int_source_health` correctly identifies broken scraper configs (test with a config that has 7+ consecutive failures)
- [ ] `mart_data_quality_trend` shows 12-week rolling history
- [ ] `mart_enrichment_gaps` correctly groups gaps by cause
- [ ] `mart_llm_faithfulness` tracks confirm/dismiss ratios

## Dependencies
Issues #042-044 (tables + staging models), Issues #050-051 (enrichment data populates staging)

## Agent Assignment
database-agent (dbt specialist)

## Progress Notes
