# Issue #068: Source Health Monitoring & LLM Faithfulness Tracking

## Summary
Add operational health tracking for every external data source (scraper configs, review sources, RSS feeds) and faithfulness metrics for LLM-generated content (review summaries, blog associations). This is the data collection layer — dbt models (Issue #052) and dashboard visualisation (Issues #056, #061) consume this data.

## User Stories
US-5.1 (metrics dashboard — data quality section), US-2.2.1 (price tracking — source health), US-2.1.1 (review aggregation — source health), US-2.3.1 (author intelligence — RSS liveness)

## Goal
When a scraper config stops producing results, the system detects it within days, not months. When a review source changes its HTML, the system flags the config as degraded. When an RSS feed dies, the system marks it and re-triggers discovery. When LLM-generated content quality drifts, the metrics dashboard surfaces it.

## Technical Requirements

**Source health recording (in enrichment workers):**
Each enrichment Oban worker records success/failure after every execution:
- `Stacks.Enrichment.SourceHealth.record_success/2` — `(source_name, source_type)` → inserts/updates `op.source_health_checks` row
- `Stacks.Enrichment.SourceHealth.record_failure/3` — `(source_name, source_type, reason)` → inserts/updates row, increments consecutive_failure_count
- Workers to instrument: `TriggerPriceScrapeJob` (per store), `FetchReviewsJob` (per source), `FetchAuthorRSSJob` (per feed), `DiscoverBookstoreEventsJob` (per bookstore)

**New table: `op.source_health_checks`:**
| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID | PK |
| `source_name` | TEXT | e.g., "exclusive_books", "goodreads", "author_rss:uuid" |
| `source_type` | ENUM | `scraper_config`, `review_source`, `rss_feed`, `event_source` |
| `last_success_at` | TIMESTAMPTZ | |
| `last_failure_at` | TIMESTAMPTZ | NULL |
| `last_failure_reason` | TEXT | NULL |
| `consecutive_failures` | INTEGER | Default 0, reset on success |
| `total_successes` | INTEGER | Lifetime count |
| `total_failures` | INTEGER | Lifetime count |
| `status` | ENUM | `healthy`, `degraded`, `broken`. Computed: 0 failures = healthy, 3+ = degraded, 7+ = broken. |
| `updated_at` | TIMESTAMPTZ | |

**HTML structure change detection (scraper configs):**
- In the Rust scraper: after each scrape, hash the DOM paths that matched CSS selectors
- Return `selector_match_rate` in the scrape response (0.0–1.0: what percentage of configured selectors found matches)
- `TriggerPriceScrapeJob` records `selector_match_rate` in source health check
- If `selector_match_rate < 0.5` for 3+ consecutive scrapes: flag config as degraded

**RSS feed liveness checks:**
- `Stacks.Workers.RSSLivenessJob` (Oban, weekly) — HTTP HEAD each registered RSS feed URL
- If HTTP 404/410 for 2+ consecutive weeks: clear `authors.rss_feed_url`, emit `author.rss_dead` event, enqueue `DiscoverAuthorSourcesJob` to re-discover
- Record result in `source_health_checks`

**LLM faithfulness tracking:**
- Review summaries: `FetchReviewsJob` already validates URLs. Add: log confidence score distribution in `source_health_checks` (source_name = "llm_review_summary", source_type = "llm_output")
- Blog associations: `PostBookAssociationWorker` records: total suggestions, mean confidence, count of high-confidence (>0.8) suggestions. Logged per run.
- Confirm/dismiss tracking: when users confirm or dismiss blog associations (in `Stacks.Blog.BookAssociations`), increment counters that feed `mart_llm_faithfulness`

**Migration:** Add `create_source_health_checks` to the migration sequence (can be added after Issue #043 tables).
**dbt staging model:** `stg_source_health_checks` (feeds `int_source_health` in Issue #052).

## Definition of Done
- [ ] Every enrichment worker records success/failure to `source_health_checks`
- [ ] Consecutive failure count resets on success; increments on failure
- [ ] Status auto-computed: healthy (0 failures) → degraded (3+) → broken (7+)
- [ ] Rust scraper returns `selector_match_rate`; low rate flags config as degraded
- [ ] `RSSLivenessJob` checks feed URLs weekly; dead feeds cleared and re-discovered
- [ ] LLM faithfulness: confidence distributions logged, confirm/dismiss ratios tracked
- [ ] `stg_source_health_checks` dbt staging model exists
- [ ] `mix test` passes
- [ ] Migration creates `source_health_checks` table

## Dependencies
Issues #050-051 (enrichment workers must exist to instrument), Issue #049 (Rust scraper must return selector_match_rate)

## Agent Assignment
elixir-agent + rust-agent (scraper selector_match_rate)

## Progress Notes
