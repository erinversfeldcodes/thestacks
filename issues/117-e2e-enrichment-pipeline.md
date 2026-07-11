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

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-2.1.1 — View Aggregated Review Sentiments | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.2.1 — View Prices Across Bookshops | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.2.2 — Configure Bookshop Scrapers | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.3.1 — View Author Information and Latest Activity | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.4.1 — Discover Relevant Bookstore Events | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.5.1 — Automatic Discovery of New Sources | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.5.2 — Geographic Discovery Sweep | ⬜ to verify | ⬜ to verify | ⬜ | — |
| US-2.5.3 — Business Opt-Out from Platform Listings | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #117)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #117's "User Stories Covered" section is the authoritative
list — it names **eight** stories (US-2.1.1, US-2.2.1, US-2.2.2, US-2.3.1,
US-2.4.1, US-2.5.1, US-2.5.2, US-2.5.3), so the matrix is 13 layers × 8 US with
happy/sad columns per cell. The assertion inventory for each layer is taken from
Issue #117's per-suite Technical Requirements (§1–§11 of
`issues/117-e2e-enrichment-pipeline.md`). This is the LARGEST audit in the
programme and, unlike #120, a large fraction of the pipeline is **partially or
un-wired** — mapping exactly which is the audit's core value (see Feature status).

---

### Feature status (verified against `apps/core/lib`, `frontend/src`, `apps/scraper/src`)

The enrichment *contexts and workers* are almost all implemented and unit-tested,
but three critical wiring gaps mean the pipeline is **not end-to-end functional**:

1. **`FetchReviewsJob` is orphaned.** `grep -rln FetchReviewsJob apps/core/lib`
   returns only the worker file itself. It is **not** in the Oban crontab
   (`config/config.exs:49-68`) and **not** enqueued by `BookCreatedHandler`
   (which only enqueues `TriggerPriceScrapeJob` —
   `book_created_handler.ex:16-30`). Issue §4 "book.created → BookCreatedHandler
   → FetchReviewsJob" is **not implemented**. The job itself is well tested via
   direct `perform/1`.

2. **`DiscoverBookstoreEventsJob` is orphaned.** Same finding — referenced only
   in its own file; no cron entry, no handler. Bookstore-event discovery
   (US-2.4.1) never runs in production. The job is unit-tested in isolation.

3. **No API surface exposes scraped reviews or prices.** `book_controller.ex`
   (`GET /api/books/:id`) contains **zero** review/price references, and
   `Api.elm` has no `getReviews`/`getPrices`. The Elm view components
   (`Components.ReviewSummary`, `PriceInfo`, `AuthorCard`) exist as pure views
   but have **no data feed and no tests**. Issue §2 "GET /api/books/:id
   (enrichment data embedded)" is **not implemented** for reviews/prices/author.
   (`GET /api/books/:id/availability` returns *partner inventory* stock, a
   different feature from scraped `price_snapshots`.)

4. **`AuthorDiscoveryHandler` is a deliberate no-op** (`author_discovery_handler.ex`
   — documented: per-book Brave calls blew the free-tier budget; author-source
   discovery moved to the `DiscoverAuthorSourcesJob %{batch: true}` daily cron).
   This is by design, and the no-op is tested.

5. **`SourceDiscoveryJob` is only triggered via the geographic sweep**
   (`GeographicDiscoveryJob`), not via `book.created` or a standalone periodic
   trigger. Issue §4 "book.created (or periodic) → SourceDiscoveryJob" is only
   partially wired.

6. **No frontend opt-out form.** `grep -ri opt.?out frontend/src` returns
   nothing — the US-2.5.3 opt-out UI (Issue §1) does not exist. The `POST
   /api/opt-out` backend endpoint is fully implemented and tested.

7. **No cost instrumentation for enrichment.** `record_cost`/`BudgetTracker`
   appear in none of `fetch_reviews_job.ex`, `score_source_job.ex`,
   `source_discovery_job.ex`, or `ai/together_client.ex`. `mart_cost_tracking`
   exists but no enrichment LLM/Brave spend is recorded (Layer 13 — mirrors the
   upload audit's Fix #12 for vision).

**What IS solidly implemented & wired:** price scrape (`TriggerPriceScrapeJob`
via `BookCreatedHandler` + daily cron + `PricePipeline` Broadway), author RSS
(`FetchAuthorRSSJob` daily cron), source discovery + scoring (`SourceDiscoveryJob`
→ `ScoreSourceJob`), geographic sweep (`user.location_updated` →
`LocationUpdatedHandler` → `GeographicDiscoveryJob`), source admin approval
(`SourceAdminController` + Elm `Page.Admin.SourceApproval` wired to
`Api.getAdminSources`/`approveSource`), scraper-health dashboard
(`MetricsController :source_health` + Elm `Page.Admin.ScraperConfig` wired to
`Api.getSourceHealth`), business opt-out backend (`OptOutController`), the Rust
price scraper (35+ cargo tests), and the full circuit-breaker fabric.

---

### Existing test inventory (verified by grep/read)

**Elixir — workers** (`apps/core/test/stacks/workers/`):
- `trigger_price_scrape_job_test.exs` — 7 tests (single/batch/circuit-open/fuse-melt/all-fail)
- `fetch_reviews_job_test.exs` — 7 tests (single/batch/no-summary-on-failure/validation)
- `fetch_author_rss_job_test.exs` — 15 tests (RSS parse, 24h filter, date parsers)
- `discover_bookstore_events_job_test.exs` — 18 tests (parse/persist/author-match/upsert)
- `source_discovery_job_test.exs` — 8 tests (create/dedup/SearXNG-fallback/both-fail)
- `score_source_job_test.exs` — 9 tests (LLM score/clamp/default-0.5/cancel/error)
- `geographic_discovery_job_test.exs` — 7 tests (5-queries/country-map/location-args)

**Elixir — contexts & handlers**:
- `stacks/enrichment/reviews_test.exs` — 12 (upsert/conflict/validation/stale/validate_summary)
- `stacks/enrichment/prices_test.exs` — 9 (upsert/conflict/validation/stale_isbns/all_stores)
- `stacks/enrichment/authors_test.exs` — 10 (update_sources/without_sources/with_rss)
- `stacks/enrichment/events_test.exs` — 9 (upsert/conflict/upcoming, incl. third-space)
- `stacks/enrichment/price_pipeline_test.exs` — 3 (Broadway handle_message/handle_batch)
- `stacks/enrichment/handlers/book_created_handler_test.exs` — 5 (enqueue TriggerPriceScrape)
- `stacks/enrichment/author_discovery_handler_test.exs` — 4 (no-op design)
- `stacks/discovery_test.exs` — 18 (create/dedup/status/confidence/opt_out/sources_for_location)
- `stacks/discovery/handlers/location_updated_handler_test.exs` — 7 (enqueue GDJ / ignore invalid)
- `stacks/discovery/brave_client_test.exs` + `searxng_client_test.exs` — 9 (mock behaviours)
- `stacks/monitoring/source_health_check_test.exs` — 20 (record_success/failure/compute_status)
- `stacks/circuit_breakers_test.exs` — incl. `:scraper_fuse` + `:together_ai_fuse` blow/recover
- `stacks/workers/dbt_refresh_job_test.exs` — maps `enrichment.prices_scraped` + `source_health.recorded`

**Elixir — controllers** (`apps/core/test/stacks_web/`):
- `controllers/metrics_controller_test.exs` — `GET /api/metrics/source-health` (admin-MFA + 401s)
- `controllers/source_admin_controller_test.exs` — `GET /admin/sources` + approve/reject (13 tests)
- `controllers/opt_out_controller_test.exs` — `POST /api/opt-out` (7 tests, public)
- `user_settings_controller_test.exs` — `PUT /api/settings/location` (3 tests)
- `book_availability_controller_test.exs` — `GET /api/books/:id/availability` (partner stock)

**Elm** (`frontend/tests/`): only `ProtoDecoderTest.elm` touches enrichment
(`enrichment_gaps` decoder for the admin Metrics dashboard). **Zero** tests for
`Components.ReviewSummary`/`PriceInfo`/`AuthorCard` or `Page.Admin.SourceApproval`/
`ScraperConfig`.

**E2E** (`e2e/tests/`): no enrichment-specific spec. `book-detail.spec.ts` has one
shallow touch — "All sections visible when book loads" asserts the "What People
Think" and "Where to Buy" section headers are present.

**dbt** (`dbt/models/`): rich model set — `int_review_sentiment`, `mart_book_reviews`,
`mart_enrichment_gaps`, `int_price_trends`, `mart_book_prices`, `int_event_matches`,
`int_source_health`, `mart_job_stats`, `int_source_approval_rate`, `mart_cost_tracking`
+ staging (`stg_review_snapshots`, `stg_price_snapshots`, `stg_discovered_sources`,
`stg_bookstore_events`, `stg_source_health_checks`, `stg_bookstores`). All staging
tests are proto-generated (`not_null`/`unique` on `id`, `not_null` on timestamps) —
**no** `accepted_values` on any status enum, **no** `relationships`/FK tests, **no**
singular tests for enrichment.

**Rust scraper** (`apps/scraper/src/`): `config.rs` (6), `auth.rs` (7 HMAC),
`robots.rs` (robots.txt), `price.rs` (14 ZAR parsing), `rate_limiter.rs` (4),
`scraper.rs` (fixtures: exclusive_books/takealot/out-of-stock/missing-price +
selector-match-rate + rate-limiter).

---

### Coverage tally

208 cells total (13 layers × 8 US, happy+sad collapsed where a layer is
single-column). Counting happy/sad separately across applicable layers:

| Status | Count |
|--------|-------|
| ✅ STRONG | **63** |
| ⚠️ shallow | **18** |
| ❌ missing | **31** |
| n/a (covered higher up / not applicable / by-design) | **96** |

This is the pre-implementation baseline. Issue #117's DoD requires regenerating
this audit to 0 ❌ / 0 ⚠️ after the punch list lands — **but the three wiring
gaps and the review/price display API (Feature-status #1–#3, #6) are code work
that exceeds a test-only issue and must be spun out as new issues per the
scope-lock rule.**

---
### Framework-layer summary

Cell = worse of (happy, sad). US columns: 2.1.1 reviews · 2.2.1 prices ·
2.2.2 scraper-health · 2.3.1 author · 2.4.1 events · 2.5.1 discovery ·
2.5.2 geo · 2.5.3 opt-out.

| Layer                     | 2.1.1 | 2.2.1 | 2.2.2 | 2.3.1 | 2.4.1 | 2.5.1 | 2.5.2 | 2.5.3 |
|---------------------------|-------|-------|-------|-------|-------|-------|-------|-------|
| L1 API                    | ❌    | ❌    | ✅    | ❌    | n/a   | ✅    | ✅    | ✅    |
| L2 Auth/Guards            | n/a   | n/a   | ⚠️    | n/a   | n/a   | ✅    | ✅    | ⚠️    |
| L3 Database               | ✅    | ✅    | ✅    | ✅    | ✅    | ✅    | ✅    | ✅    |
| L4 Event Flow             | ❌    | ✅    | ✅    | ⚠️    | ❌    | ⚠️    | ⚠️    | n/a   |
| L5 Background Jobs        | ✅    | ✅    | n/a   | ✅    | ✅    | ✅    | ✅    | n/a   |
| L6 External Services      | ✅    | ✅    | n/a   | ✅    | ⚠️    | ✅    | n/a   | n/a   |
| L7 Storage                | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   |
| L8 Cache                  | ❌    | ❌    | n/a   | ❌    | n/a   | n/a   | n/a   | n/a   |
| L9 dbt Models             | ⚠️    | ⚠️    | ⚠️    | ⚠️    | ⚠️    | ⚠️    | n/a   | ⚠️    |
| L10 Elm State Machine     | ❌    | ❌    | ❌    | ❌    | ❌    | ❌    | n/a   | ❌    |
| L11 Operational Metrics   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   |
| L12 Performance/Usability | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   | n/a   |
| L13 Cost Tracking         | ❌    | n/a   | n/a   | n/a   | n/a   | ❌    | n/a   | n/a   |

---

### Full audit tables

#### Layer 1: API Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ❌ No endpoint exposes scraped reviews. `book_controller.ex` `GET /api/books/:id` has zero review references; `Api.elm` has no `getReviews`. Issue §2 "enrichment data embedded" unimplemented. | ❌ | ❌ Same — no endpoint, no sad-path. | ❌ |
| 2.2.1 | ❌ No endpoint exposes scraped `price_snapshots`. `book_controller.ex` has no price refs; `GET /api/books/:id/availability` returns *partner inventory* (`book_availability_controller_test.exs` — "returns availability for a book that has partner stock"), a different feature. | ❌ | ❌ Same. | ❌ |
| 2.2.2 | ✅ metrics_controller_test.exs — "returns 200 with source health for admin JWT" (`GET /api/metrics/source-health`, router.ex:263). | ✅ | ✅ metrics_controller_test.exs — "returns 401 for regular owner JWT (no MFA)", "returns 401 for unauthenticated". | ✅ |
| 2.3.1 | ❌ No endpoint exposes author RSS/events enrichment. `Api.elm` has no author-enrichment fetch; `book_controller.ex` show does not embed it. | ❌ | ❌ Same. | ❌ |
| 2.4.1 | n/a — Issue §2 defines no events endpoint; bookstore events surface only via the (unimplemented) author-card count. No API surface by design. | n/a | n/a | n/a |
| 2.5.1 | ✅ source_admin_controller_test.exs — "returns paginated list of sources for admin JWT", "filters by status", "filters by type" (`GET /api/admin/sources`); "transitions pending_review to approved"/"…to dismissed" (`PUT …/approve`,`…/reject`). | ✅ | ✅ source_admin_controller_test.exs — "returns 422 for already approved source", "returns 404 for nonexistent source" (approve+reject), "returns 401 …(no MFA)", "returns 401 for unauthenticated request". | ✅ |
| 2.5.2 | ✅ user_settings_controller_test.exs — "updates country_code and city" (`PUT /api/settings/location`, router.ex:202). | ✅ | ✅ user_settings_controller_test.exs — "returns 422 for invalid country_code length". | ✅ |
| 2.5.3 | ✅ opt_out_controller_test.exs — "successfully opts out a discovered source" (`POST /api/opt-out`, router.ex:89). | ✅ | ✅ opt_out_controller_test.exs — "returns 404 when URL does not match any source", "returns 422 for invalid email format", "returns 422 when required params are missing", "returns 422 when only url is provided". | ✅ |

#### Layer 2: Auth & Middleware Guards

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | n/a — no reviews endpoint to guard (book show `optional_auth` covered in the upload audit). | n/a | n/a | n/a |
| 2.2.1 | n/a — no scraped-price endpoint to guard. | n/a | n/a | n/a |
| 2.2.2 | ✅ metrics_controller_test.exs — admin-MFA JWT path ("returns 200 … for admin JWT"). | ✅ | ⚠️ 401 is covered for no-MFA + unauthenticated, but Issue §2's "Non-owner: 403" is **not** tested — the route is MFA-gated (returns 401 for a non-MFA owner), so a distinct 403-for-authenticated-non-owner assertion is absent. | ⚠️ |
| 2.3.1 | n/a — no author-enrichment endpoint. | n/a | n/a | n/a |
| 2.4.1 | n/a — no events endpoint. | n/a | n/a | n/a |
| 2.5.1 | ✅ source_admin_controller_test.exs — authenticated admin-MFA path on index/approve/reject. | ✅ | ✅ source_admin_controller_test.exs — "returns 401 …(no MFA)" + "returns 401 for unauthenticated request" on index and approve. (Issue §2's non-owner 403 is again MFA-gated to 401 — same caveat as 2.2.2 but 401 coverage present.) | ✅ |
| 2.5.2 | ✅ user_settings_controller_test.exs — `auth_conn(user)` path on location update. | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated". | ✅ |
| 2.5.3 | ✅ opt_out_controller_test.exs — "does not require authentication" (public endpoint verified). | ✅ | ⚠️ Issue §2 requires `:rate_limit_public` on this route; no test asserts the rate-limit plug fires (no "rate limit"/429 match in opt_out_controller_test.exs). | ⚠️ |

#### Layer 3: Database Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ✅ reviews_test.exs — "inserts a new review snapshot", "upserts on conflict (book_id + source)", "latest_reviews …", "returns book IDs with no review snapshots"/"…with stale reviews (past stale_after)" (`stale_books/1`). | ✅ | ✅ reviews_test.exs — "validates required fields", "validates summary max length". | ✅ |
| 2.2.1 | ✅ prices_test.exs — "inserts a new price snapshot", "updates existing snapshot on conflict (same book_id + store_id)", "latest_prices …", "returns ISBNs for books not scraped recently" (`stale_isbns/1`), "returns all bookstores" (`all_stores/0`). | ✅ | ✅ prices_test.exs — "returns error changeset for missing required fields", "validates price_cents is non-negative". | ✅ |
| 2.2.2 | ✅ monitoring/source_health_check_test.exs — "persists a valid source health check", "creates a new health check on first call" (record_success/failure), "resets consecutive_failures …", "auto-computes status to degraded at 3"/"broken at 7". | ✅ | ✅ monitoring/source_health_check_test.exs — "is invalid without source_name", "is invalid with an unknown source_type"/"…status", "enforces unique constraint on source_name". | ✅ |
| 2.3.1 | ✅ authors_test.exs — "updates website_url"/"rss_feed_url"/"both", "returns authors missing website_url"/"rss_feed_url", "authors_with_rss …"; events_test.exs — "inserts a new bookstore event", "returns future events for a store" (`upcoming_events`). | ✅ | ✅ events_test.exs — "upserts on conflict (store_id, title, event_date)", "returns error for missing required fields". | ✅ |
| 2.4.1 | ✅ events_test.exs — "inserts a new bookstore event", "returns future events for a store"; discover_bookstore_events_job_test.exs — "persisted events can be queried via upcoming_events". | ✅ | ✅ events_test.exs — "returns error for missing required fields"; discover_bookstore_events_job_test.exs — "upsert_event handles changeset errors gracefully". | ✅ |
| 2.5.1 | ✅ discovery_test.exs — "creates a source with pending_review status", "returns the source matching the URL" (`get_source_by_url`), "returns only sources with pending_review status", "updates status to approved", "updates the confidence score". | ✅ | ✅ discovery_test.exs — "returns error on duplicate URL", "validates required fields", "validates type inclusion", "rejects confidence out of range". | ✅ |
| 2.5.2 | ✅ discovery_test.exs — "returns approved sources matching city", "…matching country code" (`sources_for_location/2`). | ✅ | ✅ discovery_test.exs — "excludes non-approved sources". | ✅ |
| 2.5.3 | ✅ discovery_test.exs — "marks source as excluded with email" (`opt_out/2`). | ✅ | ✅ discovery_test.exs — "returns not_found for unknown URL", "returns invalid_email for bad email". | ✅ |

#### Layer 4: Event Flow & Lifecycle

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ❌ **Wiring gap.** `book.created` does **not** enqueue `FetchReviewsJob` — `book_created_handler.ex` only enqueues `TriggerPriceScrapeJob`, and `FetchReviewsJob` is absent from the crontab. The `enrichment.reviews_scraped` emission lives in `fetch_reviews_job.ex` but no test asserts it fires (fetch_reviews_job_test.exs asserts persistence, not emission). | ❌ | ❌ No negative-emission test; the chain isn't wired to test. | ❌ |
| 2.2.1 | ✅ book_created_handler_test.exs — "enqueues TriggerPriceScrapeJob for book.created with ISBN", "handles atom-keyed payload"; `enrichment.prices_scraped` emitted by `price_pipeline.ex` and mapped by dbt_refresh_job_test.exs — "maps enrichment.prices_scraped to correct models". | ✅ | ✅ book_created_handler_test.exs — "skips enqueue when no ISBN in payload", "ignores unrelated events", "catch-all clause handles events without matching structure". | ✅ |
| 2.2.2 | ✅ `source_health.recorded` → dbt_refresh_job_test.exs — "maps source_health.recorded to correct models"; monitoring record_success/failure drives status transitions. | ✅ | ✅ dbt_refresh_job_test.exs — "ignores unmapped events", "ignores events with no event_type match". | ✅ |
| 2.3.1 | ✅ author_discovery_handler_test.exs — "does not enqueue discovery for any book.created event" (tests the documented no-op design); fetch_author_rss_job_test.exs — "parses RSS entries with RFC 2822 dates and emits event". | ✅ | ⚠️ `enrichment.author_updated` → `int_author_activity` mapping exists in `dbt_refresh_handler.ex:13` but is **not** covered by dbt_refresh_job_test.exs (only prices_scraped + source_health.recorded are asserted). | ⚠️ |
| 2.4.1 | ⚠️ discover_bookstore_events_job_test.exs — "persists multiple events and emits enrichment event" asserts emission, **but** `DiscoverBookstoreEventsJob` is orphaned (no cron/handler enqueues it), so the event never fires in production; `enrichment.events_discovered` → `int_event_matches` dbt mapping is untested. | ⚠️ | ❌ No handler/cron triggers `DiscoverBookstoreEventsJob` — the event chain has no producer (feature gap, not just a test gap). | ❌ |
| 2.5.1 | ✅ source_discovery_job_test.exs — "enqueues ScoreSourceJob for each new source" (SDJ→SSJ chain verified). | ✅ | ⚠️ `SourceDiscoveryJob` is only enqueued by `GeographicDiscoveryJob`; Issue §4's "book.created (or periodic) → SourceDiscoveryJob" has no `book.created`/standalone-cron producer. | ⚠️ |
| 2.5.2 | ✅ location_updated_handler_test.exs — "enqueues GeographicDiscoveryJob for atom-keyed payload"/"…string-keyed"; geographic_discovery_job_test.exs — "enqueues SourceDiscoveryJob for each search query". | ✅ | ⚠️ `PUT /api/settings/location` is not tested to **emit** `user.location_updated` — user_settings_controller_test.exs asserts the 200 body only, not the event row; the handler-side sad paths ("ignores … missing city/country_code") are covered. | ⚠️ |
| 2.5.3 | n/a — Issue §4 marks `source.opted_out` as "if instrumented"; `Discovery.opt_out/2` sets `status=excluded` without emitting an event (verified: no emit in the opt_out path). Design choice, no event to test. | n/a | n/a | n/a |

#### Layer 5: Background Jobs (Oban)

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ✅ fetch_reviews_job_test.exs — "fetches and persists review snapshot", "processes stale books" (batch), "strips hallucinated URLs from generated summaries". (Job well tested via direct `perform/1` despite being orphaned — see Feature-status #1.) | ✅ | ✅ fetch_reviews_job_test.exs — "persists snapshot without summary when together client fails", "succeeds when no stale books exist", "returns :ok for unrecognized args". | ✅ |
| 2.2.1 | ✅ trigger_price_scrape_job_test.exs — "scrapes a single ISBN across all stores", "returns ok when nothing to scrape" (batch). | ✅ | ✅ trigger_price_scrape_job_test.exs — "returns error when ScraperClient reports circuit open", "melts fuse on scraper error and returns ok when not all fail", "returns error when all scrape requests fail", "returns ok when no stores configured". | ✅ |
| 2.2.2 | n/a — scraper-config health is a read model; per-job health recording is covered at L3 (monitoring) + the jobs' own failure paths (L5 rows above/below). | n/a | n/a | n/a |
| 2.3.1 | ✅ fetch_author_rss_job_test.exs — "parses RSS entries with RFC 2822 dates and emits event", "filters out entries older than 24 hours", "keeps entries from within the last 24 hours". | ✅ | ✅ fetch_author_rss_job_test.exs — "returns ok when no authors have rss feeds", "handles fetch errors gracefully", "returns nil for unparseable string". | ✅ |
| 2.4.1 | ✅ discover_bookstore_events_job_test.exs — "processes stores with website_url set" (batch), "extracts events from HTML with h2 tags and dates", "links author when name matches a known author", "persists multiple events and emits enrichment event". | ✅ | ✅ discover_bookstore_events_job_test.exs — "returns cancel when store not found", "handles HTML with no matching patterns", "upsert_event handles changeset errors gracefully". | ✅ |
| 2.5.1 | ✅ source_discovery_job_test.exs — "creates new sources from search results", "enqueues ScoreSourceJob for each new source", "infers type from search result content"; score_source_job_test.exs — "scores a source via LLM and updates confidence", "handles high confidence score (> 0.8)"/"low", "clamps confidence to 1.0"/"0.0". | ✅ | ✅ source_discovery_job_test.exs — "deduplicates against existing sources", "returns error when both search clients fail"; score_source_job_test.exs — "defaults to 0.5 when LLM response is not a number", "returns cancel when source not found", "returns error when LLM fails". | ✅ |
| 2.5.2 | ✅ geographic_discovery_job_test.exs — "enqueues SourceDiscoveryJob for each search query", "enqueues exactly 5 queries per city", "maps country code to name in book clubs query", "location is included in all enqueued jobs". | ✅ | ✅ geographic_discovery_job_test.exs — "uses raw country code when no name mapping exists"; location_updated_handler_test.exs — "ignores location_updated event with missing city"/"…country_code"/"…empty payload" (the "no location ⇒ no job" sad path). | ✅ |
| 2.5.3 | n/a — opt-out is synchronous HTTP (`OptOutController`), no Oban job. | n/a | n/a | n/a |

#### Layer 6: External Service Calls

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ✅ fetch_reviews_job_test.exs drives the Together-AI mock (`summarize_reviews/2`) + review-fetcher mock through the pipeline; circuit_breakers_test.exs — ":together_ai_fuse … fuse is installed and starts :ok". | ✅ | ✅ fetch_reviews_job_test.exs — "persists snapshot without summary when together client fails"; circuit_breakers_test.exs — ":together_ai_fuse … circuit blows after repeated connection failures and returns {:error, :circuit_open}". | ✅ |
| 2.2.1 | ✅ trigger_price_scrape_job_test.exs drives `MockScraperClient`; Rust side: scraper.rs — "test_scrape_exclusive_books_fixture"/"test_scrape_takealot_fixture"; auth.rs — "test_valid_token_accepted" (HMAC round-trip). | ✅ | ✅ trigger_price_scrape_job_test.exs — "returns error when ScraperClient reports circuit open"; circuit_breakers_test.exs — ":scraper_fuse … circuit blows … returns {:error, :circuit_open}"; scraper.rs — "test_scrape_out_of_stock", "test_scrape_missing_price_returns_none"; auth.rs — "test_wrong_secret_rejected". | ✅ |
| 2.2.2 | n/a — health dashboard reads `op.source_health_checks` from the DB; no external call in the read path. | n/a | n/a | n/a |
| 2.3.1 | ✅ fetch_author_rss_job_test.exs drives `MockRssFetcher` (RSS XML → parsed entries). | ✅ | ✅ fetch_author_rss_job_test.exs — "handles fetch errors gracefully". (No dedicated RSS circuit-breaker fuse — RSS liveness is handled by `RSSLivenessJob`; acceptable, low-criticality path.) | ⚠️ |
| 2.4.1 | ⚠️ discover_bookstore_events_job_test.exs covers HTML **parsing** thoroughly (`parse_events/2`) but the external **fetch** (the Req/HTTP GET to the store's `/events` page) is not exercised against a mock — no fetch-success or fetch-failure HTTP test. | ⚠️ | ⚠️ Same — no external fetch-failure test (e.g. store returns 500/timeout); only changeset/parse edge cases are covered. | ⚠️ |
| 2.5.1 | ✅ brave_client_test.exs — "returns registered response"; searxng_client_test.exs — "returns configured response"; source_discovery_job_test.exs — "falls back to SearXNG when Brave budget exhausted". | ✅ | ✅ brave_client_test.exs — "returns error when error response is registered"; searxng_client_test.exs — "returns error response when configured"; source_discovery_job_test.exs — "returns error when both search clients fail". | ✅ |
| 2.5.2 | n/a — geographic sweep issues no external calls itself; it fans out to `SourceDiscoveryJob`, whose Brave/SearXNG calls are covered at 2.5.1. | n/a | n/a | n/a |
| 2.5.3 | n/a — opt-out makes no external call (local DB update only). | n/a | n/a | n/a |

#### Layer 7: Storage (R2 / Local)

| US  | Happy Path | Sad Path |
|-----|-----------|----------|
| all | n/a — Issue §7: enrichment data is stored in Postgres, not object storage. No R2 operations in any enrichment path. | n/a |

#### Layer 8: Cache Interactions

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ❌ Issue §8 requires `BookDetailCache` invalidation when review data arrives so the next `GET /api/books/:id` serves fresh enrichment. No such test exists — and because reviews are not embedded in the book payload (Feature-status #3), the invalidation is neither wired nor testable yet. | ❌ | ❌ Same. | ❌ |
| 2.2.1 | ❌ Same — no cache-invalidation test on `enrichment.prices_scraped`; prices aren't served through the cached book endpoint. | ❌ | ❌ Same. | ❌ |
| 2.3.1 | ❌ Same — author-enrichment cache invalidation untested/unwired. | ❌ | ❌ Same. | ❌ |
| 2.4.1 | n/a — events surface (would surface) via the author card; folded into 2.3.1. | n/a | n/a | n/a |
| 2.5.1–2.5.3 | n/a — admin/discovery/opt-out reads are not served through `BookDetailCache`. | n/a | n/a | n/a |

#### Layer 9: dbt Model Dependencies

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ✅ `int_review_sentiment.sql`, `mart_book_reviews.sql`, `mart_enrichment_gaps.sql` exist; `stg_review_snapshots` present with proto-generated `not_null`/`unique` on `id`; `dbt_refresh_handler.ex:12` maps `enrichment.reviews_scraped` → both models. | ✅ | ❌ No `relationships` test `stg_review_snapshots.book_id → stg_books.id`; no singular test; the `reviews_scraped → [int_review_sentiment, mart_book_reviews]` mapping is not asserted in dbt_refresh_job_test.exs (only `prices_scraped` is). | ❌ |
| 2.2.1 | ✅ `int_price_trends.sql`, `mart_book_prices.sql`, `stg_price_snapshots`; dbt_refresh_job_test.exs — "maps enrichment.prices_scraped to correct models". | ✅ | ❌ No `relationships` `stg_price_snapshots.book_id → stg_books.id`/`store_id → stg_bookstores.id`; no `accepted_values` on `currency`. | ❌ |
| 2.2.2 | ✅ `int_source_health.sql`, `mart_job_stats.sql`, `stg_source_health_checks` (proto tests on id/counters/timestamps). | ✅ | ❌ No `accepted_values` on `stg_source_health_checks.status` (healthy/degraded/broken), no `accepted_values` on `source_type`. | ❌ |
| 2.3.1 | ✅ `int_author_activity` (via `enrichment.author_updated` mapping), `int_event_matches.sql`, `stg_bookstore_events`. | ✅ | ❌ No `relationships` `stg_bookstore_events.store_id → stg_bookstores.id`/`author_id → stg_authors.id`. | ❌ |
| 2.4.1 | ✅ `int_event_matches.sql` + `stg_bookstore_events` present. | ✅ | ❌ Same FK gap as 2.3.1; no singular test that matched events reference a real author/store. | ❌ |
| 2.5.1 | ✅ `int_source_approval_rate.sql` + `stg_discovered_sources` (proto tests on id/timestamps). | ✅ | ❌ No `accepted_values` on `stg_discovered_sources.status` (pending_review/approved/rejected/excluded), no `relationships`. | ❌ |
| 2.5.2 | n/a — geographic sweep has no dedicated dbt model; it reuses `stg_discovered_sources` (covered at 2.5.1). | n/a | n/a | n/a |
| 2.5.3 | ✅ opt-out is reflected as `status='excluded'` in `stg_discovered_sources` + `excluded_at` column. | ✅ | ❌ Same `accepted_values` gap on `status` (excluded value untested). | ❌ |

**Caveat for all L9 fixes:** `stg_*` schema.yml entries are proto-generated by
`mix proto.sync` — new `accepted_values`/`relationships` tests must go through the
proto manifest/generator or live as singular tests under `dbt/tests/singular/`,
not hand-edits (they'd be overwritten). See MEMORY "dbt Staging Models".

#### Layer 10: Elm Frontend State Machine

Zero enrichment component/page tests exist in `frontend/tests/`. `ProtoDecoderTest.elm`
touches only the `enrichment_gaps` decoder (admin Metrics dashboard). The Playwright
touch in `book-detail.spec.ts` ("All sections visible when book loads") verifies the
"What People Think"/"Where to Buy" **section headers** are present but nothing about
card content, state transitions, or the RemoteData variants.

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ❌ `Components.ReviewSummary` exists as a pure view but has no test. Issue §10's `view NotAsked`/`Loading`/`Success []`/`Success data` cases are all unverified. (`book-detail.spec.ts` header-visibility touch is a shallow E2E proxy, not a state-machine test.) | ❌ | ❌ `view (Failure _)` → "Could not load reviews." untested. | ❌ |
| 2.2.1 | ❌ `Components.PriceInfo` — no test for `NotAsked`/empty/`Loading`/`Success` (sorted, "Buy" links). | ❌ | ❌ `view (Failure _)` → "Could not load prices." untested. | ❌ |
| 2.2.2 | ❌ `Page.Admin.ScraperConfig` is wired to `Api.getSourceHealth` but has no test: init `sourceHealth = Loading`, `SourceHealthReceived (Ok data)`. | ❌ | ❌ `SourceHealthReceived (Err err)` → `Failure` untested. | ❌ |
| 2.3.1 | ❌ `Components.AuthorCard` — no test for `view Nothing`/`view (Just author) Nothing`/`…(Just enrichment)` with posts/events. | ❌ | ❌ "Author information unavailable." / "No recent posts." branches untested. | ❌ |
| 2.4.1 | ❌ Upcoming-events count rendered by `AuthorCard` — untested (folded into 2.3.1). | ❌ | ❌ Same. | ❌ |
| 2.5.1 | ❌ `Page.Admin.SourceApproval` is wired to `Api.getAdminSources`/`approveSource` but has no test: init `Loading`, `SourcesLoaded`, `SetStatusFilter`, `PageChanged`, `ApproveClicked`/`ApproveCompleted`, reject. | ❌ | ❌ `ApproveCompleted (Err _)` → `actionError` untested. | ❌ |
| 2.5.2 | n/a — no dedicated enrichment UI; the location update is a field on the Settings page (generic Settings coverage exists in `SettingsTest.elm`), not an enrichment-specific state machine. | n/a | n/a | n/a |
| 2.5.3 | ❌ **No opt-out form exists in `frontend/src`** (`grep -ri opt.?out frontend/src` → nothing). Issue §1's "Is this your business?" form is unimplemented (feature gap, not just a test gap). | ❌ | ❌ Same — invalid-email/missing-field error display has no UI to test. | ❌ |

#### Layer 11: Operational Metrics

All cells `n/a — covered by SLO gate + automatic Oban/Phoenix telemetry`.
`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy and asserts on
`oban_failure_rate_scraper`, `oban_failure_rate_vision`, and `scraper_fuse_open`
(per project convention). Per-job enqueued/completed/failed counters (Issue §11)
fire automatically via Oban telemetry; per-US repetition adds no guarantee.

The external-service metric firing IS partially tested where it matters most —
circuit_breakers_test.exs asserts `[:stacks, :fuse, :blown]` telemetry for
`:scraper_fuse` and `:together_ai_fuse`, plus `[:stacks, :fuse, :melt]`/`:recovered`/
`:probe_failed`. Per-source (GoodReads/Reddit/Storygraph) success/failure rates are
persisted in `op.source_health_checks` (covered at L3). Brave budget-usage
instrumentation exists in `brave_client.ex` but has no dedicated firing test —
folded into the L13 cost-tracking punch item.

#### Layer 12: Performance & Usability Metrics

All cells `n/a — covered by SLO gate, not unit tests`. In-test SLA bounds are an
anti-pattern under variable CI timing. Enrichment freshness (30-day stale threshold,
review coverage %) is a dashboard concern derived from `mart_enrichment_gaps` +
`review_snapshots.scraped_at`; the query logic is covered at L3 (`stale_books/1`,
`stale_isbns/1`) and L9 (mart models).

#### Layer 13: Cost Tracking

| US    | Happy Path | Verdict | Sad Path | Verdict |
|-------|-----------|---------|----------|---------|
| 2.1.1 | ❌ Issue §11 tracks Together-AI review-summary spend (~$0.0002–$0.001/book) in `mart_cost_tracking`, but neither `fetch_reviews_job.ex` nor `ai/together_client.ex` calls `BudgetTracker.record_cost` — the LLM summary spend is silently $0 (mirrors the upload audit's Fix #12 for vision). | ❌ | ❌ No cost-recorded-even-on-error test (there is no cost recording at all). | ❌ |
| 2.2.1 | n/a — scraper compute is Fly.io machine time (no per-call external API spend); covered by the cost dashboard at deploy time. | n/a | n/a | n/a |
| 2.2.2 | n/a — no external spend. | n/a | n/a | n/a |
| 2.3.1 | n/a — RSS fetch has no per-call API cost. | n/a | n/a | n/a |
| 2.4.1 | n/a — bookstore HTML fetch has no per-call API cost. | n/a | n/a | n/a |
| 2.5.1 | ❌ Brave Search per-query cost (Issue §11) and the `ScoreSourceJob` LLM confidence-scoring spend are not recorded via `BudgetTracker` (`score_source_job.ex`/`source_discovery_job.ex` have no `record_cost`); `brave_client.ex` tracks a daily budget but does not feed `mart_cost_tracking`. | ❌ | ❌ No cost-on-error test. | ❌ |
| 2.5.2 | n/a — geographic sweep's costs are the fanned-out `SourceDiscoveryJob` Brave calls (covered/punch-listed at 2.5.1). | n/a | n/a | n/a |
| 2.5.3 | n/a — opt-out has no external spend. | n/a | n/a | n/a |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or modified
during this audit (pre-implementation baseline). Items tagged **[BLOCKED-FEATURE]**
require production code that exceeds this test-only issue and must be spun out as
new issues per the scope-lock rule.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1/L4/L8 2.1.1 | **[BLOCKED-FEATURE]** No API exposes scraped reviews and `book.created` doesn't enqueue `FetchReviewsJob`. Wire `BookCreatedHandler` (or a cron) to enqueue `FetchReviewsJob`, embed review snapshots in `GET /api/books/:id` (or add `GET /api/books/:id/reviews`), then add controller + cache-invalidation tests. | new issue (enrichment display wiring) → then `book_controller_test.exs` |
| 2 | L1/L8 2.2.1 | **[BLOCKED-FEATURE]** No API exposes scraped `price_snapshots` (availability endpoint is partner stock). Embed prices in the book payload / add a prices endpoint, then add controller + cache-invalidation tests. | new issue → then `book_controller_test.exs` |
| 3 | L1/L8 2.3.1 | **[BLOCKED-FEATURE]** No API exposes author RSS/event enrichment. Embed author enrichment in the book payload, then add controller tests. | new issue → then `book_controller_test.exs` |
| 4 | L2 2.2.2 sad | Decide + test the "non-owner 403" contract for `GET /api/metrics/source-health` (currently MFA-gated to 401); either add a 403-for-authenticated-non-owner test or reconcile Issue §2 with the MFA design. | `apps/core/test/stacks_web/controllers/metrics_controller_test.exs` |
| 5 | L2 2.5.3 sad | Assert `:rate_limit_public` fires on `POST /api/opt-out` (repeated requests → 429). | `apps/core/test/stacks_web/controllers/opt_out_controller_test.exs` |
| 6 | L4 2.1.1 | **[BLOCKED-FEATURE]** After #1 wires the trigger, add: `book.created` (or cron) enqueues `FetchReviewsJob`; `FetchReviewsJob` emits `enrichment.reviews_scraped` with `%{book_count: N}`. | `book_created_handler_test.exs` + `fetch_reviews_job_test.exs` |
| 7 | L4 2.3.1 sad | Assert `enrichment.author_updated` → `[int_author_activity]` mapping in `DbtRefreshHandler`. | `apps/core/test/stacks/workers/dbt_refresh_job_test.exs` |
| 8 | L4/L6 2.4.1 | **[BLOCKED-FEATURE]** `DiscoverBookstoreEventsJob` is orphaned — add a cron entry or handler that enqueues it, then assert the trigger + `enrichment.events_discovered` emission + external fetch (mock store `/events` HTTP GET, success and failure). | `config/config.exs` (cron) + new handler + `discover_bookstore_events_job_test.exs` |
| 9 | L4 2.5.1 sad | Decide + implement a `book.created` or standalone periodic trigger for `SourceDiscoveryJob` (Issue §4), or descope to geographic-only and reclassify n/a. | new issue or descope note + `source_discovery_job_test.exs` |
| 10 | L4 2.5.2 sad | Assert `PUT /api/settings/location` **emits** `user.location_updated` (event row in `event_log`), not just the 200 body. | `apps/core/test/stacks_web/user_settings_controller_test.exs` |
| 11 | L6 2.3.1 sad | Either add a circuit breaker/fuse around the RSS fetcher and a fuse-blown test, or formally accept RSS as a low-criticality no-fuse path and reclassify n/a. | `circuit_breakers_test.exs` or audit reclassification |
| 12 | L6 2.4.1 | Add external-fetch tests for `DiscoverBookstoreEventsJob`: mock store HTML fetch success, empty response (no events), and fetch failure (500/timeout → monitoring recorded). | `discover_bookstore_events_job_test.exs` |
| 13 | L9 2.1.1 sad | `relationships` test `stg_review_snapshots.book_id → stg_books.id` + assert `reviews_scraped → [int_review_sentiment, mart_book_reviews]` mapping. (proto-sync caveat.) | `dbt/tests/singular/` or proto generator + `dbt_refresh_job_test.exs` |
| 14 | L9 2.2.1 sad | `relationships` `stg_price_snapshots.book_id → stg_books.id`, `store_id → stg_bookstores.id`; `accepted_values` on `currency`. (proto-sync caveat.) | `dbt/tests/singular/` or proto generator |
| 15 | L9 2.2.2 sad | `accepted_values` on `stg_source_health_checks.status` (healthy/degraded/broken) + `source_type`. (proto-sync caveat.) | `dbt/tests/singular/` or proto generator |
| 16 | L9 2.3.1 / 2.4.1 sad | `relationships` `stg_bookstore_events.store_id → stg_bookstores.id`, `author_id → stg_authors.id`; singular test that matched events reference a real store/author. (proto-sync caveat.) | `dbt/tests/singular/` or proto generator |
| 17 | L9 2.5.1 / 2.5.3 sad | `accepted_values` on `stg_discovered_sources.status` (pending_review/approved/rejected/excluded) + `relationships` on `id`/FK. (proto-sync caveat.) | `dbt/tests/singular/` or proto generator |
| 18 | L10 2.1.1 | Elm tests for `Components.ReviewSummary`: `view NotAsked` (3 placeholder cards), `Loading`, `Success {sources=[]}` ("No reviews yet."), `Success data` (per-source cards/sentiment bar/timestamp), `Failure`. | new `frontend/tests/Components/ReviewSummaryTest.elm` |
| 19 | L10 2.2.1 | Elm tests for `Components.PriceInfo`: `NotAsked`/empty, `Loading`, `Success` (lowest-first, "Buy" links), `Failure`. | new `frontend/tests/Components/PriceInfoTest.elm` |
| 20 | L10 2.2.2 | Elm state-machine tests for `Page.Admin.ScraperConfig`: init `Loading` + `Api.getSourceHealth`, `SourceHealthReceived (Ok/Err)`. | new `frontend/tests/Page/Admin/ScraperConfigTest.elm` |
| 21 | L10 2.3.1 / 2.4.1 | Elm tests for `Components.AuthorCard`: `view Nothing`, `Just author Nothing` ("RSS/Events coming soon"), with-posts, with-events count. | new `frontend/tests/Components/AuthorCardTest.elm` |
| 22 | L10 2.5.1 | Elm state-machine tests for `Page.Admin.SourceApproval`: init, `SourcesLoaded`, `SetStatusFilter`, `PageChanged`, `ApproveClicked`/`ApproveCompleted (Ok/Err)`, reject analogues. | new `frontend/tests/Page/Admin/SourceApprovalTest.elm` |
| 23 | L10 2.5.3 | **[BLOCKED-FEATURE]** Build the business opt-out form (Issue §1 — URL/email/reason fields, success + invalid-email + missing-field + unknown-URL errors) in `frontend/src`, then add Elm + Playwright tests. | new issue (opt-out UI) → then Elm test + `e2e/tests/` |
| 24 | L13 2.1.1 | **[BLOCKED-FEATURE]** Instrument `FetchReviewsJob`/`together_client` to call `BudgetTracker.record_cost(:together_ai, …)` on every summary (success + error), then add a firing test (pattern: upload audit Fix #12). | `fetch_reviews_job.ex`/`together_client.ex` + `fetch_reviews_job_test.exs` |
| 25 | L13 2.5.1 | **[BLOCKED-FEATURE]** Instrument Brave-query and `ScoreSourceJob` LLM spend via `BudgetTracker.record_cost`, feeding `mart_cost_tracking`; add firing tests. | `brave_client.ex`/`score_source_job.ex` + tests |
| 26 | E2E (all display US) | Playwright specs for the enrichment UI once #1–#3/#23 land: review cards/sentiment colours/ARIA (§1 US-2.1.1), price cards/ZAR/trend (§1 US-2.2.1), author card (§1 US-2.3.1), `/admin/scrapers` health table (§1 US-2.2.2), `/admin/sources` approve/reject (§1 US-2.5.1), opt-out form (§1 US-2.5.3). Currently only a shallow section-header check exists in `book-detail.spec.ts`. | new `e2e/tests/enrichment.spec.ts` + `e2e/tests/admin.spec.ts` |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the 13-layer × 8-US
matrix:

- **63 ✅ STRONG** — the context/worker/scraper layer is genuinely well tested:
  every enrichment context (Reviews, Prices, Authors, Events, Discovery,
  Monitoring), every named worker's `perform/1`, the Brave/SearXNG/scraper mocks,
  the circuit-breaker fabric, and the Rust scraper all have real, cited coverage.
- **18 ⚠️ shallow** — partial wiring (SourceDiscovery trigger, location-updated
  emission, author_updated dbt mapping), missing external-fetch tests for the
  events job, MFA-vs-403 auth ambiguity, opt-out rate-limit, RSS no-fuse.
- **31 ❌ missing** — concentrated in Elm (no enrichment component/page tests at
  all), dbt sad-paths (no `accepted_values`/`relationships` on any enrichment
  model), the review/price/author **display API** (unbuilt), cache invalidation
  (unwired), the `FetchReviewsJob`/`DiscoverBookstoreEventsJob` **triggers**
  (orphaned), the opt-out **form** (unbuilt), and cost instrumentation (absent).
- **96 n/a** — storage (Postgres, no R2), performance/operational metrics (SLO
  gate + Oban/fuse telemetry), and layer/US combinations that genuinely don't
  apply, each with an inline rationale.

**Headline findings (the audit's core value):**
1. **The enrichment pipeline is well-built but not end-to-end wired.** Three
   producers are dangling: `FetchReviewsJob` and `DiscoverBookstoreEventsJob` are
   **orphaned** (referenced only in their own files — no cron, no handler), and
   `SourceDiscoveryJob` only fires via the geographic sweep. Reviews and bookstore
   events therefore never populate in production despite passing unit tests.
2. **There is no read path for scraped reviews/prices/author enrichment.**
   `GET /api/books/:id` embeds none of it and `Api.elm` has no fetchers, so the
   `ReviewSummary`/`PriceInfo`/`AuthorCard` view components are dead code with no
   data feed — and the Elm layer has **zero** enrichment tests (only the admin
   `enrichment_gaps` decoder). The US-2.5.3 opt-out **form** doesn't exist in
   `frontend/src` at all.
3. **dbt models are comprehensive but their sad-paths are untested** — not one
   enrichment staging model carries an `accepted_values` (status enums) or
   `relationships` (FK) test; all coverage is proto-generated `not_null`/`unique`.
   And enrichment LLM/Brave **cost is silently $0** (no `BudgetTracker.record_cost`
   anywhere in the enrichment jobs — the same class of bug the upload audit's
   Fix #12 caught for vision).

**Test-runner totals at baseline (enrichment-scoped):** Elixir ~140 tests across
7 worker + 6 context/handler + 4 controller + monitoring/discovery/circuit-breaker
files; Elm **0** enrichment component/page tests; Playwright **1** shallow
section-header touch; dbt ~10 enrichment models with proto-generated column tests
only; Rust **35+** cargo tests. Punch list: **26 items**, of which **8 are
[BLOCKED-FEATURE]** (#1, #2, #3, #6, #8, #23, #24, #25) and require new issues for
production wiring before their tests can be written.
## Definition of Done
- [ ] All mock-based test categories pass with `TEST_TARGET=local` (excludes `@tag :deployed_only`)
- [ ] `@tag :deployed_only` scraper tests pass with `TEST_TARGET=deployed` against a preview stack that has the scraper deployed
- [ ] Scraper deployment prerequisites documented above are met before attempting deployed tests
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Agent Assignment
Orchestrator-coordinated: `playwright-agent` for UI tests, `elixir-agent` for API/DB/event/job/external service tests, `elm-agent` for state machine tests, `dbt-agent` for model tests.

## Progress Notes
[Updated by agents during execution.]
