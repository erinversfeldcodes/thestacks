# Plan: Issue #050a — Price Enrichment Pipeline

## Context

The Rust scraper at `apps/scraper/` is production-ready with `POST /scrape` accepting `{isbn, store}` and returning `{price_cents, currency, in_stock, url, selector_match_rate}`. The `op.price_snapshots` and `op.bookstores` tables exist. No Elixir schemas, contexts, or workers exist yet for price enrichment.

## Key Decisions

1. **Broadway for batched persistence** — scrape jobs may produce many results; Broadway handles backpressure and batched `insert_all`.
2. **Fuse on scraper calls** — 5 failures in 60s blows the circuit. Pattern matches `isbn_resolver.ex`.
3. **Scraper client as a behaviour** — swappable for tests via `TEST_TARGET` / application env. Same pattern as `HttpClient` and `AI.Client`.
4. **Event-driven trigger** — register handler for `book.created` to auto-enqueue price scrape.

## Implementation Steps

### Step 1: Add Broadway dependency
- Add `{:broadway, "~> 1.1"}` to `apps/core/mix.exs`
- Run `mix deps.get`

### Step 2: Create Ecto schemas
- `Stacks.Enrichment.PriceSnapshot` — schema for `op.price_snapshots` (read-only, matches migration)
- `Stacks.Enrichment.Bookstore` — schema for `op.bookstores` (read-only)
- Location: `apps/core/lib/stacks/enrichment/price_snapshot.ex`, `bookstore.ex`

### Step 3: Create `Stacks.Enrichment.Prices` context
- `upsert_snapshot/1` — `Repo.insert` with `on_conflict: {:replace, [:price_cents, :currency, :in_stock, :url, :scraped_at]}`, conflict target `[:book_id, :store_id]`
- `latest_prices/1` — query latest per store for a book_id
- `stale_isbns/1` — join books → editions, find ISBNs not scraped in N days
- `all_stores/0` — list all bookstores for batch scraping

### Step 4: Create scraper client
- `Stacks.Enrichment.ScraperClient` behaviour + implementation
- `scrape/2` — accepts `isbn`, `store_name`, returns `{:ok, ScrapeResponse}` or `{:error, reason}`
- HMAC auth using same pattern as `Stacks.AI.Client.auth_token/2`
- Finch HTTP call to scraper service URL (configurable via `:scraper_service_url`)
- Mock client for tests: `Stacks.Enrichment.MockScraperClient`

### Step 5: Add Fuse circuit breaker
- Name: `:scraper_fuse`
- Check with `:fuse.ask(:scraper_fuse, :sync)` before each scrape call
- On HTTP error: `:fuse.melt(:scraper_fuse)`
- When blown: return `{:error, :circuit_open}`, log warning

### Step 6: Create `TriggerPriceScrapeJob` (Oban worker)
- Queue: `:scraper`, max_attempts: 3
- Args: `%{isbn: isbn, store_ids: [id, ...]}` or `%{batch: true}`
- Batch mode: calls `Prices.stale_isbns/1` and `Prices.all_stores/0`
- For each ISBN × store pair: call `ScraperClient.scrape/2`
- Collect results, push to Broadway pipeline
- On complete failure: return `{:error, reason}` for Oban retry

### Step 7: Create `PricePipeline` (Broadway)
- Producer: `Broadway.DummyProducer` (messages pushed via `Broadway.push_messages/2`)
- Processor: validate price data, build snapshot struct
- Batcher: `:insert` batcher, batch size 50, batch timeout 5_000ms
- `handle_batch/4`: `Repo.insert_all` for the batch
- `handle_failed/2`: log failures
- Start in application supervision tree (after Repo)

### Step 8: Event handler for `book.created`
- Create `Stacks.Enrichment.Handlers.BookCreatedHandler`
- Implements `Stacks.Events.Handler` behaviour
- On `book.created`: extract ISBN from payload, enqueue `TriggerPriceScrapeJob`
- Register in `Stacks.Events.Registry`: `"book.created" => [Stacks.Enrichment.Handlers.BookCreatedHandler]`

### Step 9: Event emission
- After successful Broadway batch: `Events.emit_safe(%{event_type: "enrichment.prices_scraped", ...})`

### Step 10: Oban cron for batch refresh
- Add `{"0 4 * * *", Stacks.Workers.TriggerPriceScrapeJob}` to cron config (4 AM UTC)
- Batch mode: scrapes all stale ISBNs

### Step 11: Configuration
- Add to `config.exs`: `config :core, :scraper_service_url, "http://localhost:3001"`
- Add to `config.exs`: `config :core, :scraper_client, Stacks.Enrichment.ScraperClient`
- Add to `runtime.exs`: `SCRAPER_HMAC_SECRET` env var (required in prod)
- Add to `test.exs`: `config :core, :scraper_client, Stacks.Enrichment.MockScraperClient`

## File Inventory

### New files
- `apps/core/lib/stacks/enrichment/price_snapshot.ex`
- `apps/core/lib/stacks/enrichment/bookstore.ex`
- `apps/core/lib/stacks/enrichment/prices.ex`
- `apps/core/lib/stacks/enrichment/scraper_client.ex`
- `apps/core/lib/stacks/enrichment/mock_scraper_client.ex`
- `apps/core/lib/stacks/enrichment/price_pipeline.ex`
- `apps/core/lib/stacks/enrichment/handlers/book_created_handler.ex`
- `apps/core/lib/stacks/workers/trigger_price_scrape_job.ex`
- `apps/core/test/stacks/enrichment/prices_test.exs`
- `apps/core/test/stacks/workers/trigger_price_scrape_job_test.exs`
- `apps/core/test/stacks/enrichment/price_pipeline_test.exs`

### Modified files
- `apps/core/mix.exs` — add Broadway dep
- `apps/core/lib/stacks/events/registry.ex` — register book.created handler
- `apps/core/config/config.exs` — scraper URL, client config, cron entry
- `apps/core/config/test.exs` — mock scraper client
- `apps/core/config/runtime.exs` — SCRAPER_HMAC_SECRET
- `apps/core/lib/core/application.ex` — add PricePipeline to supervision tree
- `apps/core/test/support/factory.ex` — add price_snapshot and bookstore factories

## Verification
1. `mix test` — all tests pass including new enrichment tests
2. `mix credo --strict` — clean
3. Fuse blown path tested — scraper down returns `{:error, :circuit_open}`
4. Broadway batch insert tested with mock data
5. Event handler registered and triggered on `book.created`
6. `just verify` passes
