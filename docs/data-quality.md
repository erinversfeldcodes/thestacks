# The Stacks — Data Quality Framework

> **Version:** 1.0
> **Created:** 2026-03-19
> **Status:** Living document
> **Owner:** Principle engineer / database agent

This document defines quality dimensions, SLAs, and monitoring specifications for all enrichment data products on The Stacks. It is the operational contract that the data pipeline must satisfy, and the reference for the source health monitoring implementation in Issue #068.

---

## Table of Contents

1. [Quality Dimensions](#1-quality-dimensions)
2. [Data Products and SLAs](#2-data-products-and-slas)
3. [Source Health Monitoring](#3-source-health-monitoring)
4. [Metrics Dashboard Requirements](#4-metrics-dashboard-requirements)
5. [dbt Model Scope Reference](#5-dbt-model-scope-reference)

---

## 1. Quality Dimensions

The following quality dimensions apply to all data products. Each SLA section specifies which dimensions are relevant and what the threshold is.

| Dimension | Definition | How measured |
|-----------|-----------|-------------|
| **Freshness** | How recent is the newest data point for an active book? | `MAX(scraped_at)` for the most recently refreshed record in the last N days |
| **Completeness** | What fraction of active books have at least one data point? | `COUNT(DISTINCT book_id with data) / COUNT(active books)` |
| **Accuracy** | Does the data match the source of truth? | Spot checks, user reports, validation against Open Library |
| **Validity** | Are the values in expected ranges? | dbt tests: `not_null`, `accepted_values`, range checks |
| **Consistency** | Are related fields consistent with each other? | dbt tests: referential integrity, foreign key presence |
| **LLM Faithfulness** | For AI-generated content, does the output faithfully represent the input? | URL presence validation, hallucination detection via `mart_llm_faithfulness` |

---

## 2. Data Products and SLAs

### 2.1 Price Data

**Source:** Rust scraper, TOML-configured per bookshop. Data in `op.price_snapshots`.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Freshness — WishList books | Refreshed within 24 hours | Alert if any WishList book's prices are > 48 hours old |
| Freshness — Library books | Refreshed within 7 days | Alert if > 20% of Library books have prices > 14 days old |
| Freshness — other shelves | Refreshed within 30 days | No alert — lower priority |
| Completeness | > 80% of active books have at least one price | Alert if < 60% |
| Validity | `price_cents > 0`, `price_cents < 100_000_00` (R1,000,000 max) | dbt test fails → immediate alert |
| Validity | `in_stock` is boolean, not null | dbt test |

**Known issues and accepted trade-offs:**
- Bookshops may block the scraper — an affected store will show gaps. See `docs/runbooks/scraper-config-broken.md`.
- Prices are point-in-time snapshots, not real-time. A book may sell out between snapshots — `in_stock` may be stale.
- Some stores do not expose structured price data (JavaScript-rendered pages). These stores may have lower completeness.

**dbt models:**
- `stg_price_snapshots` — staging (1:1 with `op.price_snapshots`, proto-generated)
- `int_price_trends` — price over time per edition per store
- `mart_book_prices` — current and historical prices surfaced to users

### 2.2 Review Data

**Source:** Web scraping of GoodReads, Reddit, StoryGraph. Data in `op.review_snapshots`. LLM summarisation via Together AI.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Freshness — books in Library | Reviews refreshed within 30 days | Alert if > 10% of Library books have reviews > 60 days old |
| Freshness — books in Reading Pile | Reviews refreshed within 7 days | Alert if any Reading Pile book has reviews > 14 days old |
| Completeness | > 60% of active books have at least one review source | Alert if < 40% (many obscure books have no GoodReads entry — this is expected) |
| LLM Faithfulness | All URLs in summaries exist in the source data | dbt test in `mart_llm_faithfulness` |
| LLM Attribution | Every summary has "AI-generated summary" label in the UI | Not a data quality check — enforced in Elm renderer |
| Validity | `rating` between 0.0 and 5.0 (GoodReads scale) | dbt test |
| Validity | `rating_count > 0` when `rating` is not null | dbt test |

**LLM faithfulness definition:** A review summary is "faithful" if every URL cited in the summary was present in the raw scraped data provided to the LLM. A summary with a fabricated URL is a faithfulness failure. This is tracked in `mart_llm_faithfulness` (see `docs/technical-architecture.md` section 29).

**dbt models:**
- `stg_review_snapshots` — staging (1:1 with `op.review_snapshots`, unified across GoodReads / Reddit / StoryGraph via `source` column)
- `int_review_sentiment` — aggregated sentiment per work across sources
- `mart_book_reviews` — review summaries surfaced to users
- `mart_llm_faithfulness` — per-summary faithfulness tracking

### 2.3 Author Intelligence

**Source:** Open Library API, web scraping of author websites and RSS feeds, Brave Search. Data in `op.authors`.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Freshness | Author data refreshed within 30 days | Alert if any author attached to a Reading Pile book has data > 60 days old |
| Completeness — website | > 40% of authors have a website URL | Informational — many authors lack websites |
| Completeness — bio | > 70% of authors from Open Library have a bio | Alert if < 50% (Open Library data quality issue) |
| Completeness — RSS | > 20% of authors with websites have a detected RSS feed | Informational |

**dbt models:**
- `stg_authors` (from `op.authors`, proto-generated)
- `int_author_activity` — upcoming events and recent releases per author

### 2.4 Events

**Source:** Web scraping of bookstore event pages and RSS feeds. Data in `op.bookstore_events` and `op.third_space_events`.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Freshness | Event calendar refreshed within 7 days | Alert if any bookstore's events are > 14 days stale |
| Validity | `event_date > NOW()` for all "active" events | dbt test — past events should be marked historical |
| Completeness | > 60% of verified bookstores have at least one event in the next 90 days | Informational — not all bookstores run events |

**dbt models:**
- `stg_bookstore_events`, `stg_third_space_events` (proto-generated from `op.bookstore_events`, `op.third_space_events`)
- `int_event_matches` — events matched to authors and books in user's collection
- `int_author_activity` — events rolled up per author

### 2.5 LLM Outputs (Blog Post Associations)

**Source:** Oban job processes blog post body against the user's book catalogue. Data in `op.post_book_associations`.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Faithfulness | `confidence >= 0.7` associations only surfaced to users | Enforced at the context layer (`Stacks.Blog`), not a data quality metric |
| Latency | Association job completes within 60 minutes of post publication | Alert if any association job is > 2 hours old and still pending |
| Completeness | > 90% of published blog posts with > 200 words have at least one association generated | Alert if < 70% |

**dbt models:**
- `stg_post_book_associations` (proto-generated from `op.post_book_associations`)
- `int_blog_engagement` — post views, comments, association quality
- `mart_blog_activity` — post engagement surfaced to author dashboards

### 2.6 Scraper Configs (TOML)

**Source:** `scrapers/<country>/<store>.toml` files. Health tracked in source health monitoring.

| Dimension | Target SLA | Alert threshold |
|-----------|-----------|----------------|
| Validity | All TOML files parse without errors | Rust scraper returns non-zero exit on invalid TOML → CI fails |
| Liveness | Each active scraper config produces at least one price snapshot per 7 days | Alert if a config produces 0 results for 7 consecutive days |
| HTML structure | CSS selectors still resolve on the target page | HTML change detection via `int_source_health` (delivered by Issue #068) |

---

## 3. Source Health Monitoring

Source health monitoring tracks whether each external data source is healthy. This was implemented by Issue #068 — staging in `stg_source_health_checks`, rollup in `int_source_health`.

### Source health record structure

Each source (scraper config, review site, author feed) has a health record updated after each scrape attempt:

```sql
-- Captured in int_source_health (dbt intermediate model, materialized)
source_id         UUID or TEXT (e.g., 'exclusive_books_za')
source_type       TEXT ('price_scraper', 'review_scraper', 'author_rss', 'event_scraper')
last_success_at   TIMESTAMPTZ  -- When last produced valid data
last_attempt_at   TIMESTAMPTZ  -- When last attempted
consecutive_failures  INTEGER  -- Reset to 0 on success
error_signature   TEXT         -- Hash of the error message to detect recurring patterns
html_structure_hash TEXT       -- Hash of CSS selector matches; change indicates site redesign
status            TEXT         -- 'healthy', 'degraded', 'broken', 'excluded'
```

### HTML structure change detection

For price scrapers, after each successful scrape:
1. Hash the set of CSS selectors that matched (`sort(selector_names.join(','))` + match count per selector).
2. Compare to the stored hash in `int_source_health`.
3. If the hash changed: flag the source as `degraded` and emit a `source.html_structure_changed` event.
4. The event triggers an Oban job that notifies the operator (email or metrics dashboard alert).

This detects site redesigns before they cause a full pricing gap — the alert fires on the first scrape after the HTML changes, not days later when someone notices stale prices.

### RSS liveness

For author RSS feeds:
1. Fetch the RSS feed URL.
2. Check that the feed is valid XML.
3. Check that the most recent item's publication date is within the expected window (authors who published in the last year should have entries within 365 days).
4. If the feed returns 404 or invalid XML: mark as `broken`, stop fetching, email the operator.

### Scraper config validity

TOML configs are validated at two points:
1. CI: `cargo run -- validate-configs scrapers/` — fails if any TOML is syntactically invalid.
2. Runtime: After each scrape run, if a config consistently returns 0 results, it is flagged as `broken`.

The distinction between "scraper config broken" (config issue) and "source blocked" (HTTP 403) is important: both should alert but require different responses. The error type is tracked in `int_source_health.error_signature`.

---

## 4. Metrics Dashboard Requirements

The metrics dashboard (US-5.1.1, Phase 4 (Polish) — since superseded by the Grafana stack, ADR-021) must include the following data quality panels:

### Panel: Data Freshness Overview

| Widget | Data source | Alert |
|--------|------------|-------|
| Price freshness by shelf | `MAX(scraped_at)` per shelf category | Yellow if WishList > 48h, Red if > 7 days |
| Review freshness by shelf | `MAX(scraped_at)` per shelf category | Yellow if Library > 30 days |
| Author data freshness | `MAX(updated_at)` per author attached to Reading Pile | Yellow if > 60 days |
| dbt last run time | `oban_jobs` where `queue = 'dbt_refresh' AND state = 'completed'` | Red if > 6 hours since last completion |

### Panel: Source Health Table

One row per active scraper config / review source / author feed:

| Column | Value |
|--------|-------|
| Source name | e.g., "Exclusive Books (ZA)" |
| Type | price_scraper, review_scraper, author_rss, event_scraper |
| Status | healthy / degraded / broken |
| Last success | Relative timestamp |
| Consecutive failures | Count |
| Action link | "View config" or "Open runbook" |

### Panel: Enrichment Gaps

Books that are active (on a user's shelf) but missing enrichment:

| Widget | Query |
|--------|-------|
| Books with no prices (ever) | Active books with no `price_snapshots` rows |
| Books with no reviews | Active books with no `review_snapshots` rows |
| Books with no author data | Active books where `books.author_id` is null or author has no bio |

This highlights systematic gaps (a whole bookshop's books missing prices) vs. isolated gaps (a single obscure book with no GoodReads entry).

### Panel: LLM Faithfulness Trend

Time-series chart of:
- Review summaries generated per day
- Faithfulness failures per day (URL hallucinations detected)
- Rolling 7-day faithfulness rate

Alert if 7-day faithfulness rate drops below 95%.

---

## 5. dbt Model Scope Reference

The following dbt models support the data quality framework. The intermediate and mart layers were delivered by Issue #052; source health and quality-trend marts by Issue #068. Staging models are proto-generated (`mix proto.sync`) per ADR-009 / ADR-010 — see `dbt/models/staging/` for the full list of 30+ staging views.

| dbt model | Layer | Purpose |
|-----------|-------|---------|
| `stg_price_snapshots` | staging | Clean price data (proto-generated) |
| `stg_review_snapshots` | staging | Clean review data (proto-generated) |
| `stg_books` / `stg_book_editions` | staging | Work and edition data (proto-generated) |
| `stg_authors` | staging | Author data (proto-generated) |
| `stg_event_log` | staging | Event log (proto-generated) |
| `stg_source_health_checks` | staging | Per-source health probe results (proto-generated) |
| `int_price_trends` | intermediate | Price over time per edition per store |
| `int_review_sentiment` | intermediate | Aggregated review sentiment across sources |
| `int_source_health` | intermediate | Per-source health tracking |
| `int_book_detail_view` | intermediate | Book + all metadata joined |
| `int_author_activity` | intermediate | Recent events and releases per author |
| `int_event_matches` | intermediate | Events matched to authors/books in user collections |
| `mart_book_prices` | mart | Current and historical prices surfaced to users |
| `mart_book_reviews` | mart | Review summaries surfaced to users |
| `mart_community_read_count` | mart | Aggregate read count per work |
| `mart_platform_searchable` | mart | Cross-user search index |
| `mart_data_freshness` | mart | Freshness panel data per source/shelf |
| `mart_data_quality_trend` | mart | Quality metric trends over time |
| `mart_enrichment_gaps` | mart | Books missing enrichment |
| `mart_llm_faithfulness` | mart | Per-summary faithfulness tracking |
| `mart_cost_tracking` | mart | LLM / infra cost rollups |
| `mart_system_health` | mart | Job stats and platform health rollup |

**Note on Tier 3/4 data exclusion:** dbt models must never include Tier 3 (sensitive) or Tier 4 (external personal) data. The `wh` schema is available to `stacks_dbt` and `stacks_readonly` roles — any PII that reaches these models would be accessible to analytics queries. The staging models enforce this with column-level exclusions. The following columns are explicitly excluded from all warehouse models:
- `users.password_hash`
- `users.email` (hashed or excluded entirely)
- `bookshelf_placements.notes` (encrypted, not decrypted in dbt)
- `audit_log.metadata` (encrypted)
- `ip_address` fields (hashed in `audit_log`)
