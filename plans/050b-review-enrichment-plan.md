# Plan: Issue #050b — Review Enrichment + LLM Summaries

## Context

The `op.review_snapshots` table exists with a `review_source` enum (`goodreads`, `reddit`, `storygraph`, `other`). No Ecto schema, context, or worker exists yet. Together AI is used for LLM summaries — the API key is `VISION_TOGETHER_API_KEY`. No Broadway needed — direct upserts are simpler for the expected volume.

## Key Decisions

1. **No Broadway** — reviews are fetched per-book, not in high-volume batches. Direct `upsert_snapshot/1` calls.
2. **TogetherClient as a behaviour** — swappable for tests. Uses Finch + JSON, not HMAC (Together AI uses API key auth).
3. **Fuse on Together AI** — 3 failures in 2min blows circuit. When blown, persist snapshot without summary.
4. **Unique index migration** — `(book_id, source)` needed for upsert conflict target.

## Implementation Steps

### Step 1: Add unique index migration
- New migration: `add_review_snapshots_unique_index.exs`
- `create unique_index(:review_snapshots, [:book_id, :source], prefix: "op")`

### Step 2: Create `Stacks.Enrichment.ReviewSnapshot` schema
- Maps `op.review_snapshots` table
- Fields: id, book_id, source, source_url, sentiment_score, summary, rating, rating_count, scraped_at, stale_after
- `belongs_to :book, Stacks.Books.Book`
- Changeset validates: required `[:book_id, :source, :source_url, :scraped_at]`, summary max 500 chars

### Step 3: Create `Stacks.Enrichment.Reviews` context
- `upsert_snapshot/1` — `on_conflict: {:replace, [:summary, :rating, :rating_count, :sentiment_score, :scraped_at, :stale_after, :source_url]}`, conflict target `[:book_id, :source]`
- `latest_reviews/1` — latest review per source for a book_id
- `stale_books/1` — book_ids with no review or past stale_after

### Step 4: Create `Stacks.AI.TogetherClient`
- Behaviour: `Stacks.AI.TogetherClientBehaviour`
- `summarize_reviews/2` — accepts review text + book context, returns `{:ok, summary}` or `{:error, reason}`
- Uses Finch, JSON body, `Authorization: Bearer <api_key>` header
- API key via `Application.get_env(:core, :vision_together_api_key)`
- Mock: `Stacks.AI.MockTogetherClient`

### Step 5: Add Fuse circuit breaker
- Name: `:together_ai_fuse`
- Check before each LLM call; on failure: `:fuse.melt`
- When blown: skip summary generation, persist snapshot without summary field

### Step 6: URL hallucination validation
- `validate_summary/2` — accepts summary string + source review data
- Extracts URLs from summary via regex
- Each URL must appear in the source data; strip any that don't
- Truncate to 500 chars

### Step 7: Create `FetchReviewsJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{book_id: id}` or `%{batch: true}`
- Batch: queries `Reviews.stale_books(30)`
- For each book: fetch review data (mocked in dev/test), call TogetherClient for summary, validate, upsert
- Compute `stale_after` (30 days from scraped_at)
- Emit `enrichment.reviews_scraped` event

### Step 8: Configuration
- Add to `config.exs`: `config :core, :together_client, Stacks.AI.TogetherClient`
- Add to `runtime.exs`: require `VISION_TOGETHER_API_KEY` in prod
- Add to `test.exs`: `config :core, :together_client, Stacks.AI.MockTogetherClient`

## File Inventory

### New files
- `apps/core/priv/repo/migrations/TIMESTAMP_add_review_snapshots_unique_index.exs`
- `apps/core/lib/stacks/enrichment/review_snapshot.ex`
- `apps/core/lib/stacks/enrichment/reviews.ex`
- `apps/core/lib/stacks/ai/together_client_behaviour.ex`
- `apps/core/lib/stacks/ai/together_client.ex`
- `apps/core/lib/stacks/ai/mock_together_client.ex`
- `apps/core/lib/stacks/workers/fetch_reviews_job.ex`
- `apps/core/test/stacks/enrichment/reviews_test.exs`
- `apps/core/test/stacks/workers/fetch_reviews_job_test.exs`

### Modified files
- `apps/core/config/config.exs` — together_client config
- `apps/core/config/test.exs` — mock together client
- `apps/core/config/runtime.exs` — VISION_TOGETHER_API_KEY required in prod
- `apps/core/test/support/factory.ex` — review_snapshot factory
