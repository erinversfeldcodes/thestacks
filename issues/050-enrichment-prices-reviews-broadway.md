# Issue #050: Price + Review Enrichment with Broadway Pipelines

## Summary
Build the price tracking and review aggregation enrichment contexts with Broadway pipelines for backpressure-controlled ingestion. Wire price scraping to the Rust scraper. Wire review fetching to external sources (mocked in dev).

## User Stories
US-2.1.1 (review aggregation), US-2.2.1 (price tracking)

## Goal
When a book is created, enrichment jobs fan out via the event bus. Price data flows through a Broadway pipeline from the Rust scraper into `price_snapshots` (per edition). Review data flows through scrapers into `review_snapshots` (per work). Both pipelines respect rate limits and handle failures gracefully.

## Technical Requirements

**`Stacks.Enrichment.Prices` context:**
- `get_price_history/1` — returns price snapshots for a book's editions
- `TriggerPriceScrapeJob` (Oban) — signals Rust scraper with batch of ISBNs from editions
- `PricePipeline` (Broadway) — ingests batched price data from scraper response. Batch-inserts into `price_snapshots` (FK to `book_editions`). Backpressure: max 5 concurrent processors.
- Subscribe to `book.created` event → enqueue `TriggerPriceScrapeJob`

**`Stacks.Enrichment.Reviews` context:**
- `get_review_summary/1` — returns review snapshots for a work
- `FetchReviewsJob` (Oban) — per-work, scheduled with adaptive staleness
- Store `review_snapshots` with `source ENUM(goodreads, reddit, storygraph, other)`, `sentiment_score`, LLM-generated `summary`
- LLM summary: call Together AI (or mock) to generate one-sentence sentiment summary per source. Validate: no hallucinated URLs, max 500 chars, "AI-generated summary" label.

**Broadway pipeline requirements:**
- `handle_message/3` processes individual price/review records
- `handle_batch/4` bulk-inserts into PostgreSQL
- `handle_failed/2` logs failures, does not crash pipeline
- Rate limiting at the producer level (respect external API quotas)
- Telemetry events for monitoring: `[:enrichment, :price, :batch_insert]`, `[:enrichment, :review, :fetch]`

**Fuse circuit breakers:**
- `Fuse.install(:rust_scraper, ...)` — 5 failures in 60s → open for 5 min
- `Fuse.install(:together_ai, ...)` — 5 failures in 60s → open for 5 min

## Definition of Done
- [ ] `TriggerPriceScrapeJob` calls Rust scraper and stores price snapshots per edition
- [ ] `PricePipeline` (Broadway) ingests batched data with backpressure
- [ ] `FetchReviewsJob` fetches and stores review snapshots (mocked external sources in test)
- [ ] LLM review summary generated with validation (no hallucinated URLs)
- [ ] Circuit breakers installed for scraper and LLM calls
- [ ] `book.created` event triggers enrichment fan-out
- [ ] `mix test` passes with mocked external services
- [ ] `mix credo --strict` passes

## Dependencies
Issue #046 (works/editions contexts — editions must exist for price FK), Issue #049 (Rust scraper — can be mocked if not yet built)

## Agent Assignment
elixir-agent (Opus — external API integration, Broadway architecture)

## Progress Notes
