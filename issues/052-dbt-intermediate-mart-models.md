# Issue #052: dbt Intermediate + Mart Models

## Summary
Create all dbt intermediate and mart models for enrichment data, community read count, platform search index, marketplace analytics, blog activity, and system health metrics.

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

**dbt scheduling (Oban integration):**
- `Stacks.Workers.DbtRefreshJob` — configurable dbt run triggered by Oban.Cron
- Frequency config: `mart_community_read_count` and `mart_platform_searchable` every 5 min; all others daily
- `dbt_refresh` Oban queue: concurrency 1 (sequential dbt runs)

**Schema tests:**
- `schema.yml` for all intermediate and mart models with column descriptions
- `dbt-assertions` row-level checks where applicable (e.g., `mart_community_read_count.read_count >= 0`)

## Definition of Done
- [ ] `dbt run` succeeds for all intermediate + mart models
- [ ] `dbt test` passes with schema + row-level assertions
- [ ] `mart_community_read_count` returns correct counts (verified against test data)
- [ ] `mart_platform_searchable` contains expected public content
- [ ] `DbtRefreshJob` Oban worker runs on schedule
- [ ] 5-minute refresh configured for hot-path marts
- [ ] All models documented in `schema.yml`

## Dependencies
Issues #042-044 (tables + staging models), Issues #050-051 (enrichment data populates staging)

## Agent Assignment
database-agent (dbt specialist)

## Progress Notes
