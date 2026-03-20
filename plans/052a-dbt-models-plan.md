# Plan: Issue #052a — dbt Intermediate + Core Mart Models

## Context

The staging layer is complete (22 models, 1,104 lines of schema.yml). The intermediate and mart directories exist with .gitkeep files. ADR 010 specifies the contract-first derived data pattern. All enrichment data from Wave C is available.

## Key Decisions

1. **All models start as VIEWs** — incremental materialisation deferred to #052c.
2. **Intermediate models join/aggregate staging** — no business logic, just semantic reshaping.
3. **Mart models are consumer-specific** — each has a named API consumer.
4. **Graceful fallback for missing data** — use LEFT JOIN and COALESCE so models work even when enrichment tables are empty.

## Implementation Steps

### Step 1: Update dbt_project.yml
Add intermediate and marts layer config with materialisation and schema settings.

### Step 2: Create intermediate models (10 files)
Each in `dbt/models/intermediate/`:
- `int_price_trends.sql` — join stg_price_snapshots + stg_bookstores, latest per book/store
- `int_review_sentiment.sql` — aggregate stg_review_snapshots by book
- `int_author_activity.sql` — join stg_authors + latest stg_event_log entries for author events
- `int_event_matches.sql` — join stg_bookstore_events + stg_third_space_events with location
- `int_book_engagement.sql` — aggregate stg_bookshelf_placements by book (count, reread, abandon)
- `int_book_detail_view.sql` — denormalised book + primary edition + author
- `int_source_approval_rate.sql` — aggregate stg_discovered_sources by status
- `int_partner_availability.sql` — join stg_price_snapshots + stg_bookstores for availability
- `int_blog_engagement.sql` — aggregate stg_post_book_associations by post
- `int_visibility_resolution.sql` — join stg_bookshelves + stg_bookshelf_placements visibility

### Step 3: Create mart models (12 files)
Each in `dbt/models/marts/`:
- `mart_book_reviews.sql` — from int_review_sentiment
- `mart_book_prices.sql` — from int_price_trends
- `mart_community_read_count.sql` — count distinct users with placement per book
- `mart_platform_searchable.sql` — denormalised book + editions + author for search
- `mart_system_health.sql` — from stg_source_health_checks
- `mart_job_stats.sql` — from Oban tables (job counts, durations)
- `mart_data_freshness.sql` — latest scraped_at per source
- `mart_cost_tracking.sql` — from stg_platform_costs
- `mart_gdpr_compliance.sql` — consent rates, erasure stats from stg_users + stg_audit_log
- `mart_marketplace_activity.sql` — from stg_listings + stg_transactions
- `mart_transaction_volume.sql` — aggregate stg_transactions by period
- `mart_blog_activity.sql` — from int_blog_engagement

### Step 4: Add schema.yml entries
Create `dbt/models/intermediate/schema.yml` and `dbt/models/marts/schema.yml` with model descriptions, column descriptions, and basic tests.

### Step 5: Verify
- `dbt run` succeeds
- `dbt test` passes
- `dbt-checkpoint` quality gates pass

## File Inventory

### New files
- 10 intermediate SQL files in `dbt/models/intermediate/`
- 12 mart SQL files in `dbt/models/marts/`
- `dbt/models/intermediate/schema.yml`
- `dbt/models/marts/schema.yml`

### Modified files
- `dbt/dbt_project.yml` — add intermediate + marts config
