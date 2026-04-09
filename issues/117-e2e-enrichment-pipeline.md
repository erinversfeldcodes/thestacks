# Issue #117: E2E Test Suite — Enrichment Pipeline

## Summary
Comprehensive end-to-end test coverage for the enrichment pipeline: price scraping, review fetching with LLM summaries, author RSS discovery, bookstore event scraping, source discovery (Brave/SearXNG), geographic sweeps, business opt-out, circuit breaker behaviour, and admin source approval.

## User Stories Covered
- [US-2.1.1 — View Aggregated Review Sentiments](../docs/user_stories/US-2.1.1-view-reviews.md)
- [US-2.2.1 — View Prices Across Bookshops](../docs/user_stories/US-2.2.1-view-prices.md)
- [US-2.2.2 — Configure Bookshop Scrapers](../docs/user_stories/US-2.2.2-configure-scrapers.md)
- [US-2.3.1 — View Author Information and Latest Activity](../docs/user_stories/US-2.3.1-author-activity.md)
- [US-2.4.1 — Discover Relevant Bookstore Events](../docs/user_stories/US-2.4.1-bookstore-events.md)
- [US-2.5.1 — Automatic Discovery of New Sources](../docs/user_stories/US-2.5.1-source-discovery.md)
- [US-2.5.2 — Geographic Discovery Sweep](../docs/user_stories/US-2.5.2-geographic-sweep.md)
- [US-2.5.3 — Business Opt-Out from Platform Listings](../docs/user_stories/US-2.5.3-business-optout.md)

## Scope Check
- Does this issue touch more than 3 controllers? Yes — but this is test-only and the enrichment pipeline spans multiple domains by nature. No production code changes.
- Does this issue add more than 2 new endpoints? No (test-only).
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all enrichment pipeline).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test infrastructure).

## Test Suites

### 1. Playwright UI Tests

#### Review Sentiments Display (US-2.1.1)
- Open book detail overlay for a book with review snapshots
- Verify "What People Think" section renders
- Verify per-source cards: source name, AI-generated summary, sentiment bar, optional rating
- Verify sentiment bar colour-coded: deep red (critical), warm amber (mixed), deep green (glowing)
- Verify "Last refreshed: [timestamp]" at bottom of section
- Verify clickable links to original review pages open in new tabs
- Empty reviews: verify "No reviews yet." message
- NotAsked state: verify placeholder cards for GoodReads, Storygraph, Reddit with "Sentiment data coming soon"
- Failure state: verify "Could not load reviews."
- ARIA: `role="region"`, `aria-labelledby="section-reviews"`

#### Price Display (US-2.2.1)
- Open book detail overlay for a book with price snapshots
- Verify "Where to Buy (ZAR)" section renders
- Verify per-store cards sorted by price (lowest first)
- Verify each card: store name, price in ZAR format ("R X.XX"), trend indicator (up/down/stable), "Buy" link
- Verify "Buy" links open external store pages in new tabs
- Verify footer: "Prices checked by The Stacks -- last updated [timestamp]."
- No price data: verify "No price data yet."
- Loading: verify "Checking prices..." spinner
- Failure: verify "Could not load prices."

#### Author Info Display (US-2.3.1)
- Open book detail overlay for a book with author data
- Verify author name in serif typeface with avatar initial
- Verify website link opens in new tab (if `website_url` present)
- Verify latest RSS post card: title, date, excerpt, "Read more" link (if enrichment data exists)
- Verify upcoming events count (if > 0): "N upcoming event(s) at bookstores near you."
- No author data: verify "Author information unavailable."
- No enrichment: verify "RSS feed coming soon", "Events coming soon."
- No recent posts: verify "No recent posts."
- No upcoming events: verify "No upcoming events."
- Verify "Auto-discovered" label and "Report an issue" link

#### Scraper Health Dashboard (US-2.2.2)
- Navigate to `/admin/scrapers` as platform owner
- Verify per-source health table renders: name, type, status, consecutive failures, last success, last failure
- Verify healthy sources show green status
- Verify degraded/broken sources show warning/error status
- Unauthenticated access: verify redirect/401
- Non-owner access: verify 403
- API failure: verify "Failed to load source health. Please try again."

#### Source Approval Admin (US-2.5.1)
- Navigate to `/admin/sources` as platform owner
- Verify filterable, paginated table of discovered sources
- Verify columns: name, type, URL, confidence, discovered_via, discovered_at, status
- Filter by status (pending, approved, rejected); verify list updates
- Click "Approve" on a pending source; verify status changes to approved
- Click "Reject" on a pending source; verify status changes to rejected
- Verify approve/reject show loading state during API call
- Mock API failure on approve: verify "Action failed. Please try again." toast

#### Business Opt-Out Form (US-2.5.3)
- On Third Spaces page or "Where to Buy" section, verify "Is this your business?" link on non-partner listings
- Click link; verify opt-out form opens (no auth required)
- Verify fields: URL (pre-filled), email, reason (remove/partner)
- Submit with valid data; verify success message
- Submit with invalid email; verify "The provided email address is not valid." error
- Submit with missing fields; verify "url and email are required" error
- Submit with non-existent URL; verify "No discovered source matches the provided URL." error

### 2. API Endpoint Tests

#### `GET /api/books/:id` (enrichment data embedded)
- Book with review snapshots: response includes review data with per-source summaries, sentiment scores, ratings
- Book with price snapshots: response includes price data per edition per store
- Book with author enrichment: response includes author RSS posts and event counts
- Book with no enrichment: response includes empty/null enrichment fields

#### `GET /api/metrics/source-health`
- Authenticated owner: returns 200 with `{ data: [{ name, source_type, status, consecutive_failures, last_success, last_failure }] }`
- Non-owner: returns 403
- Unauthenticated: returns 401

#### `GET /api/admin/sources`
- Authenticated owner: returns 200 with `{ sources: [...], total, page }`
- Supports query params: `?status=pending&type=bookshop&page=1&per_page=50`
- Non-owner: returns 403
- Unauthenticated: returns 401

#### `PUT /api/admin/sources/:id/approve`
- Authenticated owner: returns 200, source status changes to approved
- Non-owner: returns 403
- Non-existent source: returns 404

#### `PUT /api/admin/sources/:id/reject`
- Authenticated owner: returns 200, source status changes to rejected
- Non-owner: returns 403
- Non-existent source: returns 404

#### `POST /api/opt-out`
- Valid URL + email: returns 200, source marked `excluded`
- URL not found: returns 404
- Invalid email: returns 422
- Missing fields: returns 422
- No auth required (public endpoint)
- Rate limited via `:rate_limit_public`

#### `PUT /api/settings/location` (geographic sweep trigger)
- Valid city + country_code: returns 200, emits `user.location_updated` event
- Missing fields: returns 422
- Unauthenticated: returns 401

### 3. Database Assertion Tests

#### `op.review_snapshots`
- Upsert: INSERT ON CONFLICT UPDATE on `(book_id, source)` unique constraint
- Required fields: `book_id`, `source`, `source_url`, `scraped_at`
- Optional fields: `sentiment_score`, `summary` (max 500 chars), `rating`, `rating_count`, `stale_after`
- Stale query: `Reviews.stale_books(30)` finds books with no snapshot, expired `stale_after`, or `scraped_at < cutoff`

#### `op.price_snapshots`
- Price records created by `PricePipeline` Broadway pipeline
- Fields: book_id, store_id, price, currency, fetched_at

#### `op.bookstores`
- Store records: name, website_url, search_template, scraper_module, country_code
- Used by `Prices.all_stores()` to drive scraping

#### `op.bookstore_events`
- Event records: store_id, author_id, event_date, description, url
- Matched against user's collection via author_id

#### `op.discovered_sources`
- Source records: name, type, url, confidence, discovered_via, status, discovered_at
- Unique constraint on `url`
- Status enum: pending_review, approved, rejected, excluded
- Opt-out: `status = "excluded"`, `excluded_at`, `exclusion_email` set

#### `op.source_health_checks`
- Health tracking per source: `consecutive_failures`, `last_success`, `last_failure`
- Updated by `Monitoring.record_success/2` and `Monitoring.record_failure/3`

### 4. Event Flow Tests

#### Price Scrape Pipeline
- `book.created` event -> `BookCreatedHandler` -> enqueues `TriggerPriceScrapeJob`
- Price data flows through `PricePipeline` Broadway pipeline
- `enrichment.prices_scraped` event emitted on completion

#### Review Scrape Pipeline
- `book.created` event -> `BookCreatedHandler` -> enqueues `FetchReviewsJob`
- `enrichment.reviews_scraped` event emitted by `FetchReviewsJob` with `%{book_count: N}`
- `enrichment.reviews_scraped` triggers `DbtRefreshHandler` -> refreshes `int_review_sentiment`, `mart_book_reviews`

#### Author Discovery
- `book.created` event -> `AuthorDiscoveryHandler` -> enqueues `FetchAuthorRSSJob`
- Author metadata and RSS feed discovered

#### Source Discovery
- `book.created` event (or periodic trigger) -> `SourceDiscoveryJob`
- `SourceDiscoveryJob` creates `DiscoveredSource` records with `status: pending_review`
- `ScoreSourceJob` scores each source (0.0-1.0 confidence)

#### Geographic Sweep
- `user.location_updated` event -> `LocationUpdatedHandler` -> `GeographicDiscoveryJob`
- `GeographicDiscoveryJob` builds 5 search queries -> enqueues `SourceDiscoveryJob` for each
- Each `SourceDiscoveryJob` -> `ScoreSourceJob`

#### Business Opt-Out
- `POST /api/opt-out` -> `Discovery.exclude_source/2` -> source status = "excluded"
- Event: `source.opted_out` emitted (if instrumented)

### 5. Background Job Tests

#### `Stacks.Workers.TriggerPriceScrapeJob`
- Queue: `:default`
- Batch mode: iterates `Prices.all_stores()`, scrapes each store
- Single mode: args `%{"book_id" => uuid}` scrapes for specific book
- Scraper mock returns price data -> `PricePipeline` processes -> `price_snapshots` upserted
- Failure: recorded via `Monitoring.record_failure/3`, retries up to max attempts
- Store not found: returns `{:cancel, "store not found"}`

#### `Stacks.Workers.FetchReviewsJob`
- Queue: `:default`
- Batch mode: `Reviews.stale_books(30)` finds candidates
- Per-book: calls `review_fetcher().fetch_reviews(book_id)` for raw data
- LLM summary: calls `together_client.summarize_reviews/2`
- Validates summary: `Reviews.validate_summary/2` strips hallucinated URLs, truncates to 500 chars
- Upserts: `Reviews.upsert_snapshot/1`
- Records health: `Monitoring.record_success/2` or `record_failure/3`
- On success: emits `enrichment.reviews_scraped` event
- Max attempts: 3

#### `Stacks.Workers.FetchAuthorRSSJob`
- Fetches RSS feed for author
- Parses RSS XML -> stores latest post
- Mock RSS feed response

#### `Stacks.Workers.DiscoverBookstoreEventsJob`
- Batch or per-store mode
- Scrapes bookstore websites for events
- Parses events -> persists to `op.bookstore_events`
- Store fetch failure: logged, recorded in monitoring
- Store not found: `{:cancel, "store not found"}`

#### `Stacks.Workers.SourceDiscoveryJob`
- Searches Brave API (primary) and SearXNG (fallback)
- Creates `DiscoveredSource` records with `status: pending_review`
- Deduplicates by URL (returns `{:error, :duplicate}`)
- Enqueues `ScoreSourceJob` for each discovered source
- Max attempts: 3
- Brave budget exhausted: falls back to SearXNG automatically

#### `Stacks.Workers.ScoreSourceJob`
- Calls LLM to evaluate source (0.0-1.0 confidence)
- Updates `discovered_sources.confidence`
- LLM failure: retains default confidence (0.5), logs warning

#### `Stacks.Workers.GeographicDiscoveryJob`
- Triggered by `user.location_updated` event via `LocationUpdatedHandler`
- Builds 5 search queries: "bookshop {city}", "reading group {city}", "book club {city}", "literary festival {city}", "book cafe {city}"
- Enqueues `SourceDiscoveryJob` for each query
- No location set: no event emitted, no job enqueued

### 6. External Service Tests

#### Together AI (LLM)
- Mock `together_client.summarize_reviews/2` returns valid summary
- Mock returns empty/invalid summary -> `Reviews.validate_summary/2` strips/truncates
- Circuit breaker: fuse blown -> `{:error, :circuit_open}` -> summary set to nil, snapshot still persisted
- Mock for `ScoreSourceJob`: returns confidence score 0.0-1.0

#### Review Data Fetcher
- Mock `review_fetcher().fetch_reviews(book_id)` returns per-source review data (GoodReads, Reddit, Storygraph)
- Mock returns empty data for specific sources
- Mock returns failure -> source health recorded

#### Rust Scraper (Price Scraping)
**Mock tests (`TEST_TARGET=local`):**
- Mock scraper service returns price data per ISBN per store
- Mock returns "not stocked" -> store shows "Not available"
- Mock returns failure -> `Monitoring.record_failure/3`
- Invalid TOML config: health check records failure, source shows degraded

**Real scraper tests (`@tag :deployed_only`, `TEST_TARGET=deployed`):**
The Rust scraper must be deployed to `thestacks-scraper` on Fly.io before these tests can pass. See deployment prerequisites below.
- `GET https://thestacks-scraper.internal/health` returns 200 — scraper is reachable from core app
- `TriggerPriceScrapeJob` with a real ISBN (e.g. `9781250301697`) and store `za/exclusive_books` — real HTTP scrape returns `{:ok, %{price: _, currency: "ZAR", in_stock: _}}`
- `TriggerPriceScrapeJob` with a real ISBN and store `za/takealot` — real HTTP scrape returns valid price data
- Price written to `op.price_snapshots` — `fetched_at` is recent, `price > 0`, `currency = "ZAR"`
- HMAC auth round-trip: scraper rejects requests with wrong `SCRAPER_HMAC_SECRET`, accepts requests signed by core app
- Circuit breaker recovery: after scraper returns to health, `TriggerPriceScrapeJob` succeeds again

#### Brave Search API
- Mock returns search results for source discovery
- Mock returns rate limit / budget exhausted -> fallback to SearXNG
- Budget tracking per query

#### SearXNG (fallback)
- Mock returns search results when Brave fails
- Mock failure of both -> job returns error, retries

#### RSS Feed Fetcher
- Mock RSS XML response with recent posts
- Mock empty/malformed RSS -> graceful handling

#### Bookstore Event Scraper
- Mock HTML response with upcoming events
- Mock empty response -> no events created
- Mock fetch failure -> logged, monitoring updated

#### Circuit Breaker Behaviour (all services)
- Verify fuse blown after consecutive failures
- Verify fuse recovery after cooldown
- Verify fallback behaviour when fuse is open
- Verify `{:error, :circuit_open}` returned (not exception)

### 7. Storage Tests

N/A — enrichment data is stored in the database, not in object storage. No R2 operations.

### 8. Cache Tests

#### BookDetailCache
- After enrichment data arrives (reviews, prices, author info): cache invalidated for affected book
- Next `GET /api/books/:id` fetches fresh data including enrichment

### 9. dbt Model Tests

#### Review Models
- `int_review_sentiment`: intermediate model built from `op.review_snapshots`
- `mart_book_reviews`: aggregated view — `book_id`, `avg_rating`, `avg_sentiment_score`, `review_count`
- `mart_enrichment_gaps`: identifies books with `missing_reviews` by joining `int_book_detail_view` with `int_review_sentiment`
- Refresh triggered by `enrichment.reviews_scraped` event via `DbtRefreshHandler`

#### Price Models
- Staging models reflect `op.price_snapshots` data
- Refresh triggered by price scrape completion events

#### Source Health Models
- `mart_job_stats`: Oban job counts for enrichment workers (enqueued, completed, failed, retried)
- Reflects data from `op.source_health_checks`

#### Cost Tracking
- `mart_cost_tracking`: reflects AI API costs (Together AI, Modal)
- Updated when enrichment jobs complete

### 10. Elm State Machine Tests

#### Components.ReviewSummary (pure view)
- `view NotAsked`: renders 3 placeholder cards with "Sentiment data coming soon"
- `view Loading`: renders spinner with "Loading reviews..."
- `view (Success { sources = [] })`: renders "No reviews yet."
- `view (Success data)`: renders per-source cards with header, summary, sentiment bar, rating, timestamp
- `view (Failure _)`: renders "Could not load reviews."
- No messages — stateless component

#### Components.PriceInfo (pure view)
- `view NotAsked` or `view (Success { editions = [] })`: renders "No price data yet."
- `view Loading`: renders "Checking prices..." spinner
- `view (Success data)`: renders edition groups with per-store price cards (lowest first), "Buy" links
- `view (Failure _)`: renders "Could not load prices."
- No messages — stateless component

#### Components.AuthorCard (pure view)
- `view Nothing _`: renders "Author information unavailable."
- `view (Just author) Nothing`: renders name, avatar, "RSS feed coming soon", "Events coming soon"
- `view (Just author) (Just enrichment)` with posts: renders latest RSS post card
- `view (Just author) (Just enrichment)` with events: renders event count

#### Page.Admin.SourceApproval
- Init: `sources = Loading`, fires `Api.getAdminSources`
- `SourcesLoaded (Ok response)` -> `sources = Success response`
- `SetStatusFilter filter` -> refetch with new filter
- `PageChanged page` -> refetch with new page
- `ApproveClicked sourceId` -> `actionInProgress = Just sourceId`, calls `Api.approveSource`
- `ApproveCompleted (Ok _)` -> refetch sources, clear `actionInProgress`
- `ApproveCompleted (Err _)` -> `actionError = Just "Action failed."`
- `RejectClicked` / `RejectCompleted`: analogous to approve

#### Page.Admin.ScraperConfig
- Init: `sourceHealth = Loading`, fires `Api.getSourceHealth`
- `SourceHealthReceived (Ok data)` -> `sourceHealth = Success data`
- `SourceHealthReceived (Err err)` -> `sourceHealth = Failure err`

### 11. Metrics & Telemetry Tests

#### Oban Job Metrics
- `FetchReviewsJob`: enqueued/completed/failed counters via Oban telemetry
- `TriggerPriceScrapeJob`: enqueued/completed/failed counters
- `FetchAuthorRSSJob`: enqueued/completed/failed counters
- `DiscoverBookstoreEventsJob`: enqueued/completed/failed counters
- `SourceDiscoveryJob`: enqueued/completed/failed counters
- `ScoreSourceJob`: enqueued/completed/failed counters
- `GeographicDiscoveryJob`: enqueued/completed/failed counters

#### External Service Metrics
- Together AI call counts and latencies per `summarize_reviews/2` call
- Circuit breaker state transitions for Together AI, review fetcher, scraper
- Per-source (GoodReads, Reddit, Storygraph) success/failure rates in `op.source_health_checks`
- Brave Search API call counts and budget usage

#### Event Handler Metrics
- `DbtRefreshHandler` processing time for enrichment events
- dbt refresh job duration for `int_review_sentiment`, `mart_book_reviews`

#### Cost Tracking
- Together AI: ~$0.0002-$0.001 per book review summary tracked in `mart_cost_tracking`
- Brave Search: per-query cost tracked
- Review fetcher compute: Fly.io machine time
- Neon compute: query costs for upserts and stale book queries

#### Enrichment Freshness
- Time since last review scrape per book (derived from `review_snapshots.scraped_at`)
- Stale threshold: 30 days
- Review coverage: percentage of books with at least one snapshot (via `mart_enrichment_gaps`)

## Scraper Deployment Prerequisites (for `@tag :deployed_only` tests)

The `@tag :deployed_only` scraper tests require the Rust scraper to be running on Fly.io before they can pass. These steps are one-time setup:

1. **Build and deploy the scraper image:**
   ```bash
   fly deploy --config deploy/fly.scraper.toml --dockerfile deploy/Dockerfile.scraper
   ```

2. **Set secrets on the scraper app:**
   ```bash
   fly secrets set SCRAPER_HMAC_SECRET=<64-char secret> --app thestacks-scraper
   ```

3. **Set secrets on the core app** (same secret, plus the internal URL):
   ```bash
   fly secrets set SCRAPER_HMAC_SECRET=<same secret> --app stacks-core
   fly secrets set SCRAPER_SERVICE_URL=http://thestacks-scraper.internal:8080 --app stacks-core
   ```

4. **Seed bookstore records** in the core app database:
   ```sql
   INSERT INTO op.bookstores (id, name, website_url, scraper_module, country_code)
   VALUES
     (gen_random_uuid(), 'Exclusive Books', 'https://www.exclusivebooks.co.za', 'za/exclusive_books', 'ZA'),
     (gen_random_uuid(), 'Takealot', 'https://www.takealot.com', 'za/takealot', 'ZA');
   ```

5. **Verify** the scraper is reachable from within the Fly.io private network:
   ```bash
   fly ssh console --app stacks-core
   > curl http://thestacks-scraper.internal:8080/health
   ```

Until these steps are complete, all `@tag :deployed_only` scraper tests will be excluded from local and CI runs (via `ExUnit.configure(exclude: [:deployed_only])`). Mock-based tests cover the same code paths for local development.

## Dependencies
- Mock infrastructure for all external services:
  - `Stacks.Enrichment.MockReviewFetcher`
  - `Stacks.AI.MockClient` (Together AI)
  - `Stacks.Enrichment.MockScraperClient` (Rust scraper — local tests only)
  - Brave Search mock
  - SearXNG mock
  - RSS feed mock
  - Bookstore website mock
- **Rust scraper deployed to `thestacks-scraper` on Fly.io** — required for `@tag :deployed_only` price scrape tests
- **`SCRAPER_HMAC_SECRET` and `SCRAPER_SERVICE_URL` set as Fly.io secrets** on both apps
- **`op.bookstores` seeded** with at least `za/exclusive_books` and `za/takealot`
- Oban testing setup (`Oban.Testing`)
- Broadway testing setup for `PricePipeline`
- Seeded books, authors, stores, and source records
- Admin user with owner role for admin endpoint tests
- Playwright test harness with auth helpers
- `data-testid` attributes on enrichment UI elements (Issue #108)

## Definition of Done
- [ ] All mock-based test categories pass with `TEST_TARGET=local` (excludes `@tag :deployed_only`)
- [ ] `@tag :deployed_only` scraper tests pass with `TEST_TARGET=deployed` against a preview stack that has the scraper deployed
- [ ] Scraper deployment prerequisites documented above are met before attempting deployed tests
- [ ] No flaky tests
- [ ] `just verify` passes

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/job/external service tests, `elm-agent` for state machine tests, `dbt-agent` for model tests.

## Progress Notes
[Updated by agents during execution.]
