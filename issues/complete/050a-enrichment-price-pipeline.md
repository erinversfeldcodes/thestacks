# Issue #050a: Price Enrichment Pipeline

## Summary
Build the price scraping pipeline: Broadway-backed ingestion from the Rust scraper, price snapshot persistence, and circuit breaker protection.

## User Stories
US-5.1 — "As a user, I want to see what a book costs at local bookshops so I can decide where to buy."

## Goal
When a book is added to the system, its ISBNs are automatically sent to the Rust scraper for price lookups. Results flow through a Broadway pipeline into `op.price_snapshots`. The pipeline handles backpressure, retries, and circuit-breaks when the scraper is down.

## Scope Check
- 1 context (`Stacks.Enrichment.Prices`)
- 1 Oban worker (`TriggerPriceScrapeJob`)
- 1 Broadway pipeline (`PricePipeline`)
- 0 new endpoints
- ~400 LOC

## Wiring
- [x] This issue is implementation only. Price data surfaces via existing catalogue/book detail endpoints in a future issue.

## Technical Requirements

1. **Add Broadway dependency** to `apps/core/mix.exs`
2. **`Stacks.Enrichment.Prices` context**:
   - `upsert_snapshot/1` — insert or update `op.price_snapshots` (keyed on `book_id + store_id`)
   - `latest_prices/1` — returns latest price per store for a given book_id
   - `stale_isbns/1` — returns ISBNs not scraped in the last N days
3. **`TriggerPriceScrapeJob`** (Oban worker, queue: `:scraper`):
   - Accepts `%{isbn: isbn, store_ids: [store_id, ...]}` or `%{batch: true}` for bulk
   - Calls Rust scraper `POST /scrape` with HMAC auth
   - Parses `ScrapeResponse` (price_cents, currency, in_stock, url, selector_match_rate)
   - Passes results to `PricePipeline` for batched persistence
   - On failure: log, return `{:error, reason}` for Oban retry
4. **`PricePipeline`** (Broadway):
   - Producer: receives scrape results from `TriggerPriceScrapeJob` via Broadway.push_messages
   - Processor: validates price data, maps to snapshot struct
   - Batcher: bulk-inserts via `Repo.insert_all`
   - `handle_failed/2`: logs failures, does not retry (Oban handles job-level retry)
5. **Fuse circuit breaker** for Rust scraper:
   - Name: `:scraper_fuse`
   - Strategy: `{:standard, 5, 60_000}` (5 failures in 60s → blow)
   - Check fuse before calling scraper; skip with warning if blown
6. **Event emission**: `enrichment.prices_scraped` via `Events.emit_safe/1` after successful batch
7. **Subscriber**: register for `book.created` events to auto-trigger price scrape for new books

## Reviewer Context
- The Rust scraper at `apps/scraper/src/main.rs` already returns `selector_match_rate` in `ScrapeResponse`
- HMAC auth uses `x-internal-token` header — see existing `Stacks.AI.Client` for the pattern
- Fuse is in deps but not yet used anywhere — this is the first circuit breaker
- Broadway is NOT in deps yet — must be added

## Definition of Done
- [ ] Broadway added to deps and compiles
- [ ] `Stacks.Enrichment.Prices` context with upsert_snapshot, latest_prices, stale_isbns
- [ ] `TriggerPriceScrapeJob` calls Rust scraper and processes response
- [ ] `PricePipeline` batches inserts into `op.price_snapshots`
- [ ] Fuse circuit breaker protects scraper calls
- [ ] `enrichment.prices_scraped` event emitted on success
- [ ] Tests cover: context CRUD, worker success/failure, fuse blown path, Broadway pipeline
- [ ] `just verify` passes

## Dependencies
- Issue #046 (works/editions — complete)
- Issue #049 (Rust scraper — can mock via `TEST_TARGET`)

## Agent Assignment
elixir-agent

## Progress Notes
