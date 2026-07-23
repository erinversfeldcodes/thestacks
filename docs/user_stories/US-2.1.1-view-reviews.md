# US-2.1.1 — View Aggregated Review Sentiments

## 1. User Story

> **As a** user, **I want to** see a summary of what people think about a book across multiple platforms **so that** I can get a balanced sense of reception without reading hundreds of reviews.

The user opens a book detail overlay. The "What People Think" section is already populated with sentiment data. Each source (GoodReads, Reddit, Storygraph) has its own card showing: source icon, a one-sentence LLM-generated sentiment summary with citations, a colour-coded sentiment bar (deep red for critical, warm amber for mixed, deep green for glowing), and clickable links to the original review pages/threads. A small "Last refreshed: 3 days ago" timestamp at the bottom of the section. Books in the Reading Pile refresh more frequently; books in the Library refresh less often.

**Acceptance criteria:**
- Per-source cards with sentiment summary, score, and links
- Colour-coded sentiment bar per source
- "Last refreshed" timestamp
- Data populated without user intervention (background scraping)

---

## 2. UI Interaction Flow

### Happy Path
1. User opens a book detail overlay (clicks a book spine on any bookshelf).
2. The "What People Think" section renders within the overlay.
3. If review data exists (`Success` state), per-source cards display with sentiment summaries.
4. Each card shows: source name, AI-generated summary, sentiment bar, optional rating, and "Last refreshed" timestamp.
5. User reads summaries and clicks through to original review pages in new tabs.

### Sad Paths
- **No reviews yet**: When `Success` data has an empty `sources` list, the component shows "No reviews yet."
- **Fetch failure**: When `Failure`, displays "Could not load reviews."
- **Not yet loaded**: When `NotAsked`, placeholder cards render for GoodReads, Storygraph, and Reddit with "Sentiment data coming soon" stubs.

### Elm State Machine
- **Component module**: `Components.ReviewSummary`
- **Model fields involved**: `RemoteData e ReviewData` (passed as a prop, not owned by the component)
- **Msg flow**: No messages — this is a pure view component (`view : RemoteData e ReviewData -> Html msg`)
- **RemoteData states**: NotAsked (placeholder stubs) / Loading (spinner) / Success (source cards) / Failure (error message)
- **OutMsg pattern**: N/A — stateless component

---

## 3. API Calls

Review data is fetched as part of the book detail endpoint (not a separate call in the current implementation). The review snapshots are populated by background workers and read from the database.

### `GET /api/books/:id`
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Request body**: N/A (GET)
- **Response (success)**: Book detail JSON including review snapshot data — HTTP 200
- **Response (error)**: `{ error: "Not found" }` — HTTP 404

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Visibility checks**: Book detail may apply visibility checks based on book's `visibility_tier`
- **Age gate**: `AgeGate.enforce/2` — if book is `age_gated`, requires `age_verified: true` on the user
- **Ownership checks**: N/A — review data is read-only

---

## 5. Database Interactions

### Read: Latest review snapshots for a book
- **Table(s)**: `op.review_snapshots`
- **Query**: `Reviews.latest_reviews(book_id)` — `WHERE book_id = ? ORDER BY scraped_at DESC`
- **Indexes used**: Composite unique index on `(book_id, source)` serves the conflict target; query benefits from index on `book_id`
- **Schema module**: `Stacks.Enrichment.ReviewSnapshot`

### Read: Stale books needing review refresh
- **Table(s)**: `op.books` LEFT JOIN `op.review_snapshots`
- **Query**: `Reviews.stale_books(30)` — finds books with no snapshot, or with `stale_after < cutoff`, or where `scraped_at < cutoff` and `stale_after` is nil
- **Indexes used**: Left join on `rs.book_id = b.id`
- **Schema module**: `Stacks.Enrichment.ReviewSnapshot`

### Write: Upsert review snapshot
- **Table(s)**: `op.review_snapshots`
- **Operation**: INSERT ON CONFLICT UPDATE
- **Changeset validations**: Required: `book_id`, `source`, `source_url`, `scraped_at`. Optional: `sentiment_score`, `summary` (max 500 chars), `rating`, `rating_count`, `stale_after`
- **Transaction**: No explicit Multi — single upsert
- **Denormalization**: None

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `enrichment.reviews_scraped`
- **Aggregate**: `enrichment` + generated UUID
- **Payload**: `{ book_count: N }`
- **Emitted by**: `Stacks.Workers.FetchReviewsJob`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: On `enrichment.reviews_scraped`, enqueues `DbtRefreshJob` for models `["int_review_sentiment", "mart_book_reviews"]`
- **Downstream effects**: dbt models refreshed for review analytics

---

## 7. Background Jobs (Oban)

### FetchReviewsJob
- **Worker**: `Stacks.Workers.FetchReviewsJob`
- **Queue**: `:default`
- **Args**: `%{"book_id" => uuid}` (single) or `%{"batch" => true}` (batch)
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. In batch mode: calls `Reviews.stale_books(30)` to find books needing refresh
  2. For each book: calls `review_fetcher().fetch_reviews(book_id)` to get raw review data from external sources
  3. For each source: calls `together_client.summarize_reviews/2` to generate an LLM summary
  4. Validates summary with `Reviews.validate_summary/2` — strips hallucinated URLs, truncates to 500 chars
  5. Upserts via `Reviews.upsert_snapshot/1`
  6. Records source health via `Monitoring.record_success/2` or `Monitoring.record_failure/3`
- **On success**: Snapshot persisted, `enrichment.reviews_scraped` event emitted, source health marked healthy
- **On failure**: Individual source failures logged and recorded in monitoring; job retries up to 3 times

---

## 8. External Service Calls

### Together AI (LLM summary generation)
- **Service**: Together AI
- **Endpoint**: Configured via `together_client.summarize_reviews/2`
- **Client module**: `Stacks.AI.TogetherClient` (real) / configurable via `Application.get_env(:core, :together_client)`
- **Auth**: API key
- **Circuit breaker**: Returns `{:error, :circuit_open}` when fuse is blown — summary is skipped (set to nil), snapshot still persisted
- **Fallback**: Summary field set to nil; snapshot saved without summary
- **Mock in test**: `Stacks.Enrichment.MockReviewFetcher` for the review data fetcher

### Review data fetcher
- **Service**: External review platforms (GoodReads, Reddit, Storygraph)
- **Client module**: `Stacks.Enrichment.MockReviewFetcher` (default in dev/test), real implementation fetches from external sources
- **Mock in test**: Configurable via `Application.get_env(:core, :review_fetcher)`

---

## 9. Storage (R2 / Local)

N/A — review snapshots are stored in the database, not in object storage.

---

## 10. Cache Interactions

N/A — review data is currently served directly from the database. No explicit caching layer for review snapshots.

---

## 11. dbt Model Dependencies

### `int_review_sentiment`
- **Model**: `int_review_sentiment`
- **Trigger**: `enrichment.reviews_scraped` event via `DbtRefreshHandler`
- **Materialisation**: Intermediate model (feeds into mart)
- **Consumer**: `mart_book_reviews`, `mart_enrichment_gaps`

### `mart_book_reviews`
- **Model**: `mart_book_reviews` (view)
- **Trigger**: `enrichment.reviews_scraped` event via `DbtRefreshHandler`
- **Materialisation**: View — `SELECT book_id, avg_rating, avg_sentiment_score, review_count FROM int_review_sentiment`
- **Consumer**: Metrics dashboard review coverage data

### `mart_enrichment_gaps`
- **Model**: `mart_enrichment_gaps` (view)
- **Trigger**: Indirectly refreshed when review data changes
- **Materialisation**: View — joins `int_book_detail_view` with `int_review_sentiment` to identify books with `missing_reviews`
- **Consumer**: the `/api/metrics/enrichment-gaps` endpoint was removed in #267 (in-app metrics dashboard superseded by Grafana); the `mart_enrichment_gaps` mart is retained for the Grafana observability surface

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: N/A — this is a component within the book detail overlay, not a standalone route
- **URL**: N/A
- **Public or authenticated**: Inherits from book detail overlay context

### Init
- **`initPage` branch**: N/A — component receives data as a prop
- **API calls on init**: None — data comes from the parent book detail fetch
- **Initial model state**: Typically `NotAsked` until the parent provides data

### Update cycle
N/A — `Components.ReviewSummary` is a pure view function with no messages or state.

### View
- **Key elements**:
  - `NotAsked`: Three placeholder cards (GoodReads, Storygraph, Reddit) with "Sentiment data coming soon"
  - `Loading`: Spinner with "Loading reviews..."
  - `Success` (empty): "No reviews yet"
  - `Success` (data): Per-source cards with header (icon + source name), summary text, sentiment bar, optional rating ("X / 5"), and "Last refreshed" timestamp
  - `Failure`: "Could not load reviews."
- **ARIA attributes**: `role="region"`, `aria-labelledby="section-reviews"` on the section
- **CSS classes**: `book-detail__section`, `book-detail__reviews`, `book-detail__reviews-grid`, `book-detail__review-card`, `book-detail__review-sentiment`, `book-detail__review-sentiment-fill`

---

## 13. Operational Metrics

- **Oban job counts for `FetchReviewsJob`**: enqueued, completed, failed, retried — tracked via `mart_job_stats` dbt model and Oban telemetry (`[:oban, :job, :start | :stop | :exception]`)
- **Together AI call counts and latencies**: per-call duration for `summarize_reviews/2`, tracked via `Monitoring.record_success/2` and `Monitoring.record_failure/3`
- **Circuit breaker state**: Together AI fuse events — open/closed transitions visible in `op.source_health_checks` (source_type: `"together_ai"`)
- **Review fetcher call counts**: per-source (GoodReads, Reddit, Storygraph) success/failure rates recorded in `op.source_health_checks`
- **Event handler execution times**: `DbtRefreshHandler` processing time for `enrichment.reviews_scraped` events
- **dbt refresh job duration**: time to rebuild `int_review_sentiment` and `mart_book_reviews` models, tracked in `mart_job_stats`

---

## 14. Performance & Usability Metrics

- **Enrichment data freshness**: time since last review scrape per book — derived from `review_snapshots.scraped_at` vs `NOW()`. Stale threshold: 30 days (configurable via `Reviews.stale_books/1`)
- **Review summary quality**: LLM response parse success rate — percentage of `summarize_reviews/2` calls that produce a valid summary vs those stripped by `Reviews.validate_summary/2` (hallucinated URLs, truncation)
- **Review coverage**: percentage of books with at least one review snapshot — reported via `mart_enrichment_gaps.missing_reviews`
- **Per-source yield**: number of reviews successfully fetched per source (GoodReads, Reddit, Storygraph) — derivable from `op.review_snapshots` grouped by `source`
- **Batch processing throughput**: books processed per `FetchReviewsJob` batch run

---

## 15. Cost Tracking

- **Together AI** (review summary generation): ~$0.20 per 1M input tokens, ~$0.60 per 1M output tokens (Meta Llama 3.1 8B Instruct pricing). Each review summary consumes ~500-2000 input tokens (raw reviews) and ~100-200 output tokens (summary). Estimated cost per book: $0.0002-$0.001. Tracked via `mart_cost_tracking` dbt model.
- **Review data fetcher**: no direct API cost (scraping external review pages). Compute cost is Fly.io machine time during `FetchReviewsJob` execution.
- **Fly.io compute**: core app machine runs the Oban worker. Cost depends on machine size and duration of batch runs. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: database queries for `Reviews.stale_books/1`, snapshot upserts, and dbt model rebuilds consume Neon compute units. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
