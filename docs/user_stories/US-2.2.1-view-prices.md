# US-2.2.1 — View Prices Across Bookshops

## 1. User Story

> **As a** user, **I want to** see current prices for a book across multiple South African bookshops **so that** I can find the best deal.

The user opens a book detail overlay. The "Where to Buy (ZAR)" section lists all configured stores with current prices. A vertically stacked list of bookshop cards, sorted by price (lowest first). Each card shows: store name/logo, current price in ZAR, a price trend sparkline covering the last 6 months, and a "Buy" link that opens the store page in a new tab. If a store doesn't stock the book, it shows "Not available" in grey italics. A note at the bottom: "Prices checked by The Stacks' scraping service. Last updated: [timestamp]."

---

## 2. UI Interaction Flow

### Happy Path
1. User opens a book detail overlay.
2. The "Where to Buy (ZAR)" section renders within the overlay.
3. If price data exists (`Success` state), edition groups display with per-store price cards sorted lowest-first.
4. Each card shows store name, price in ZAR (formatted as "R X.XX"), trend indicator (up/down/stable arrow), and a "Buy" button linking to the external store page.
5. Footer shows "Prices checked by The Stacks -- last updated [timestamp]."

### Sad Paths
- **No price data**: When `NotAsked` or `Success` with empty editions, displays "No price data yet."
- **Fetch failure**: When `Failure`, displays "Could not load prices."
- **Loading**: Spinner with "Checking prices..."

### Elm State Machine
- **Component module**: `Components.PriceInfo`
- **Model fields involved**: `RemoteData e PriceData` (passed as a prop)
- **Msg flow**: No messages — pure view component (`view : RemoteData e PriceData -> Html msg`)
- **RemoteData states**: NotAsked / Loading / Success / Failure
- **OutMsg pattern**: N/A — stateless component

---

## 3. API Calls

Price data is fetched as part of the book detail endpoint. The price snapshots are populated by the `TriggerPriceScrapeJob` worker via the `PricePipeline` Broadway pipeline.

### `GET /api/books/:id`
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Response (success)**: Book detail JSON including price snapshot data — HTTP 200
- **Response (error)**: `{ error: "Not found" }` — HTTP 404

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Visibility checks**: Inherits from book detail visibility
- **Age gate**: `AgeGate.enforce/2` if the book is `age_gated`
- **Ownership checks**: N/A — price data is read-only

---

## 5. Database Interactions

### Read: Latest prices for a book
- **Table(s)**: `op.price_snapshots`
- **Query**: `Prices.latest_prices(book_id)` — `WHERE book_id = ? ORDER BY scraped_at DESC`
- **Indexes used**: Composite unique index on `(book_id, store_id)`
- **Schema module**: `Stacks.Enrichment.PriceSnapshot`

### Read: All bookstores
- **Table(s)**: `op.bookstores`
- **Query**: `Prices.all_stores()` — `SELECT * FROM op.bookstores`
- **Schema module**: `Stacks.Enrichment.Bookstore`

### Read: Stale ISBNs needing price refresh
- **Table(s)**: `op.book_editions` LEFT JOIN `op.price_snapshots`
- **Query**: `Prices.stale_isbns(7)` — finds editions with no snapshot or `scraped_at < cutoff` (7-day window)
- **Schema module**: `Stacks.Enrichment.PriceSnapshot`

### Write: Upsert price snapshot
- **Table(s)**: `op.price_snapshots`
- **Operation**: INSERT ON CONFLICT UPDATE
- **Changeset validations**: Required: `book_id`, `store_id`, `price_cents` (>= 0), `scraped_at`. Optional: `currency` (default "ZAR"), `in_stock`, `url`
- **Transaction**: Batched via Broadway `PricePipeline`
- **Denormalization**: None

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `enrichment.prices_scraped`
- **Aggregate**: `enrichment` + first book_id from the batch
- **Payload**: `{ count: N, book_ids: [uuid, ...] }`
- **Emitted by**: `Stacks.Enrichment.PricePipeline.handle_batch/4`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: On `enrichment.prices_scraped`, enqueues `DbtRefreshJob` for models `["int_price_trends", "mart_book_prices"]`
- **Downstream effects**: dbt price models refreshed

### Trigger Chain: book.created -> price scrape
- **Handler**: `Stacks.Enrichment.Handlers.BookCreatedHandler`
- **Action**: On `book.created`, extracts ISBN from payload and enqueues `TriggerPriceScrapeJob`
- **Downstream effects**: Prices scraped for the new book automatically

---

## 7. Background Jobs (Oban)

### TriggerPriceScrapeJob
- **Worker**: `Stacks.Workers.TriggerPriceScrapeJob`
- **Queue**: `:scraper`
- **Args**: `%{"isbn" => isbn, "book_id" => uuid}` (single) or `%{"batch" => true}` (batch)
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Batch mode: calls `Prices.stale_isbns(7)` and `Prices.all_stores()`
  2. Checks `:scraper_fuse` circuit breaker — if blown, returns `{:error, :circuit_open}`
  3. For each (isbn, store) pair: calls `scraper_client.scrape(isbn, store_name)`
  4. Successful results pushed as Broadway messages to `PricePipeline`
  5. Records source health via `Monitoring.record_success/2` or `Monitoring.record_failure/3`
  6. On failure: calls `:fuse.melt(:scraper_fuse)` to increment the circuit breaker
- **On success**: Messages pushed to PricePipeline for batched persistence
- **On failure**: Circuit breaker incremented; if all scrapes fail, returns `{:error, "all scrape requests failed"}`

### PricePipeline (Broadway)
- **Worker**: `Stacks.Enrichment.PricePipeline`
- **Processor concurrency**: 2
- **Batcher**: `:insert` with batch_size=50, batch_timeout=5000ms, concurrency=1
- **What it does**:
  1. `handle_message`: Validates price data (requires `book_id`, `store_id`, `price_cents`)
  2. `handle_batch`: Calls `Prices.upsert_snapshot/1` for each message, emits `enrichment.prices_scraped` event for the batch
  3. `handle_failed`: Logs failed messages

---

## 8. External Service Calls

### Rust scraper service
- **Service**: Rust scraper microservice (`apps/scraper/`)
- **Endpoint**: `POST /scrape`
- **Client module**: `Stacks.Enrichment.ScraperClient`
- **Auth**: HMAC (`X-Internal-Token` header) — timestamp-based `<unix_ts>.<HMAC-SHA256(SCRAPER_HMAC_SECRET, "<ts>.POST./scrape")>`
- **Circuit breaker**: `:scraper_fuse` — melted on each failure, checked before each batch
- **Fallback**: Job returns error; prices not updated for that ISBN/store combination
- **Mock in test**: `Stacks.Enrichment.MockScraperClient` (configured via `Application.get_env(:core, :scraper_client)`)

---

## 9. Storage (R2 / Local)

N/A — price snapshots are stored in the database.

---

## 10. Cache Interactions

N/A — price data served directly from the database.

---

## 11. dbt Model Dependencies

### `int_price_trends`
- **Model**: `int_price_trends`
- **Trigger**: `enrichment.prices_scraped` via `DbtRefreshHandler`
- **Materialisation**: Intermediate model with `recency_rank` for latest-per-store calculation
- **Consumer**: `mart_book_prices`, `mart_enrichment_gaps`

### `mart_book_prices`
- **Model**: `mart_book_prices` (view)
- **Trigger**: `enrichment.prices_scraped` via `DbtRefreshHandler`
- **Materialisation**: View — `SELECT book_id, store_name, price_cents, currency, in_stock, scraped_at FROM int_price_trends WHERE recency_rank = 1`
- **Consumer**: Metrics dashboard price coverage data

### `mart_enrichment_gaps`
- **Model**: `mart_enrichment_gaps` (view)
- **Trigger**: Indirectly refreshed when price data changes
- **Materialisation**: View — identifies books with `missing_prices`
- **Consumer**: the `/api/metrics/enrichment-gaps` endpoint was removed in #267 (in-app metrics dashboard superseded by Grafana); the `mart_enrichment_gaps` mart is retained for the Grafana observability surface

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: N/A — component within the book detail overlay
- **URL**: N/A
- **Public or authenticated**: Inherits from parent context

### Init
- **`initPage` branch**: N/A — component receives data as a prop
- **API calls on init**: None — data comes from the parent book detail fetch
- **Initial model state**: Typically `NotAsked`

### Update cycle
N/A — `Components.PriceInfo` is a pure view function with no messages or state.

### View
- **Key elements**:
  - `NotAsked` / `Success` (empty): "No price data yet"
  - `Loading`: Spinner with "Checking prices..."
  - `Success` (data): Per-edition groups, each with format label + ISBN, then store listings sorted by price. Each store row: name, "R X.XX" price, trend arrow (up/down/stable), "Buy" button (opens external link in new tab). Footer: "Prices checked by The Stacks -- last updated [timestamp]"
  - `Failure`: "Could not load prices."
- **ARIA attributes**: `role="region"`, `aria-labelledby="section-prices"` on the section
- **CSS classes**: `book-detail__section`, `book-detail__prices`, `book-detail__price-edition`, `book-detail__price-store`, `book-detail__price-amount`, `btn btn--sm btn--secondary book-detail__price-buy`

---

## 13. Operational Metrics

- **Oban job counts for `TriggerPriceScrapeJob`**: enqueued, completed, failed, retried — tracked via `mart_job_stats` dbt model and Oban telemetry
- **Rust scraper call counts and latencies**: per-store `POST /scrape` duration and success/failure rates recorded via `Monitoring.record_success/2` and `Monitoring.record_failure/3`
- **Circuit breaker state**: `:scraper_fuse` open/closed transitions — melt events tracked per failed scrape call, visible in `op.source_health_checks` (source_type: `"scraper"`)
- **Broadway pipeline throughput**: `PricePipeline` messages/sec, batch sizes (configured: batch_size=50, batch_timeout=5000ms), processor concurrency=2, batcher concurrency=1
- **Event handler execution times**: `DbtRefreshHandler` processing time for `enrichment.prices_scraped` events; `BookCreatedHandler` latency for triggering price scrape on new books
- **dbt refresh job duration**: time to rebuild `int_price_trends` and `mart_book_prices` models

---

## 14. Performance & Usability Metrics

- **Enrichment data freshness**: time since last price scrape per book/edition — derived from `price_snapshots.scraped_at` vs `NOW()`. Stale threshold: 7 days (configurable via `Prices.stale_isbns/1`)
- **Price scrape success rate per store**: percentage of `(isbn, store)` pairs that return a valid price vs those that fail — derivable from `op.price_snapshots` and `op.source_health_checks`
- **Price coverage**: percentage of book editions with at least one price snapshot — reported via `mart_enrichment_gaps.missing_prices`
- **Broadway batch efficiency**: ratio of messages successfully processed vs failed in `handle_batch/4`
- **Per-store availability**: percentage of books marked `in_stock: true` per bookstore — derivable from `op.price_snapshots`

---

## 15. Cost Tracking

- **Rust scraper** (Fly.io compute): scraper microservice runs on Fly.io. Cost per scrape batch depends on machine size and duration. Fly.io shared-cpu-1x: ~$1.94/month base. Auto-stop enabled (`auto_stop_machines = true`), so cost scales with scrape frequency.
- **Fly.io compute** (core app): Oban worker running `TriggerPriceScrapeJob` and Broadway `PricePipeline` consume core app machine time.
- **Neon compute**: database queries for `Prices.stale_isbns/1`, `Prices.all_stores/0`, snapshot upserts, and dbt model rebuilds. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Network egress**: Rust scraper makes outbound HTTP requests to bookstore websites. Fly.io includes 100GB outbound/month on the free tier; $0.02/GB after.
