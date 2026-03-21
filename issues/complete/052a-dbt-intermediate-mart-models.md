# Issue #052a: dbt Intermediate + Core Mart Models

## Summary
Create all dbt intermediate models (semantic aggregates, joins, computations) and core mart models (consumer-optimised read models) following ADR 010 contract-first derived data pattern.

## User Stories
N/A — data engineering infrastructure.

## Goal
The dbt intermediate and mart layers are built, tested, and documented. Each model has a named consumer, correct materialisation, and schema.yml entries with tests.

## Scope Check
- 0 endpoints, 0 Elixir contexts
- 10 intermediate models + 12 mart models (SQL only)
- Each model ~20-30 lines of SQL
- schema.yml entries for all models
- ~500-600 lines of SQL + YAML

## Wiring
- [x] This issue is implementation only. Models are consumed by API endpoints in future issues.

## Technical Requirements

### Intermediate Models (dbt/models/intermediate/)
All materialised as VIEWs unless noted:

1. `int_price_trends` — latest price per book per store, price change direction
2. `int_review_sentiment` — average rating + sentiment per book, review count
3. `int_author_activity` — latest RSS entries, website status per author
4. `int_event_matches` — upcoming events matched to user location preferences
5. `int_book_engagement` — placement count, reread count, abandonment rate per book
6. `int_book_detail_view` — denormalised book + primary edition + author for API
7. `int_source_approval_rate` — approval/dismissal ratio for discovered sources
8. `int_partner_availability` — book availability across partner stores
9. `int_blog_engagement` — post views, book associations per post
10. `int_visibility_resolution` — pre-computed visibility state per resource

### Mart Models (dbt/models/marts/)
1. `mart_book_reviews` — consumer: BookController.show (review tab)
2. `mart_book_prices` — consumer: BookController.show (price comparison)
3. `mart_community_read_count` — consumer: BookController.show (social proof)
4. `mart_platform_searchable` — consumer: CatalogueController.index (full-text search)
5. `mart_system_health` — consumer: MetricsController (admin dashboard)
6. `mart_job_stats` — consumer: MetricsController (job monitoring)
7. `mart_data_freshness` — consumer: MetricsController (data staleness)
8. `mart_cost_tracking` — consumer: CostController.index (operational costs)
9. `mart_gdpr_compliance` — consumer: MetricsController (consent rates, erasure stats)
10. `mart_marketplace_activity` — consumer: MetricsController (listing stats)
11. `mart_transaction_volume` — consumer: MetricsController (sales volume)
12. `mart_blog_activity` — consumer: MetricsController (post stats)

### Configuration
- Update `dbt_project.yml` with intermediate and marts layer config
- Intermediate: `+materialized: view`, `+schema: intermediate`
- Marts: `+materialized: table`, `+schema: marts` (or view where appropriate)
- Add schema.yml entries for all models with column descriptions and tests

## Reviewer Context
- ADR 010 specifies contract-first derived data pattern
- Staging layer is complete (22 models, 1,104 lines of schema.yml)
- `int_price_trends` and `mart_community_read_count` will eventually be incremental (#052c)
- For now, all models can be VIEWs — incremental tuning is deferred

## Definition of Done
- [ ] `dbt run` succeeds for all intermediate + mart models
- [ ] `dbt test` passes with schema tests
- [ ] All models documented in schema.yml with column descriptions
- [ ] `dbt-checkpoint` quality gates pass
- [ ] Models follow naming conventions (int_ prefix, mart_ prefix)
- [ ] `just verify` passes

## Dependencies
- Issues #042-044 (tables + staging — complete)
- Issues #050-051 (enrichment data — complete)

## Agent Assignment
database-agent

## Progress Notes
