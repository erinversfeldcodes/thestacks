# Issue #050b: Review Enrichment + LLM Summaries

## Summary
Build the review enrichment pipeline: fetch external review data, generate LLM summaries via Together AI, and persist to `op.review_snapshots`.

## User Stories
US-5.2 — "As a user, I want to see review summaries from external sources so I can decide if a book is worth reading."

## Goal
An Oban worker periodically fetches review data for books in the catalogue, generates concise LLM summaries, validates them for hallucinations, and persists snapshots. The Together AI client is circuit-breaker-protected.

## Scope Check
- 1 context (`Stacks.Enrichment.Reviews`)
- 1 Oban worker (`FetchReviewsJob`)
- 0 new endpoints
- ~400 LOC

## Wiring
- [x] This issue is implementation only. Review data surfaces via book detail endpoint in a future issue.

## Technical Requirements

1. **`Stacks.Enrichment.Reviews` context**:
   - `upsert_snapshot/1` — insert or update `op.review_snapshots` (keyed on `book_id + source`)
   - `latest_reviews/1` — returns latest review per source for a given book_id
   - `stale_books/1` — returns book_ids with no review or stale review (past `stale_after`)
2. **`FetchReviewsJob`** (Oban worker, queue: `:default`):
   - Accepts `%{book_id: id}` or `%{batch: true}` for bulk
   - Fetches review metadata from configured sources (mocked in dev/test)
   - Calls Together AI to generate summary (max 500 chars)
   - Validates summary: no URL hallucination (URLs in summary must exist in source data)
   - Computes `stale_after` (source-dependent, default 30 days)
   - Persists via `Reviews.upsert_snapshot/1`
3. **Together AI client module** (`Stacks.AI.TogetherClient`):
   - `summarize_reviews/2` — accepts review text + book context, returns summary string
   - Uses `Req` HTTP client with JSON body
   - Respects `TEST_TARGET` env var (mock in test, real in deployed)
4. **Fuse circuit breaker** for Together AI:
   - Name: `:together_ai_fuse`
   - Strategy: `{:standard, 3, 120_000}` (3 failures in 2min → blow)
   - When blown: skip summary generation, persist snapshot without summary
5. **Validation**:
   - Summary length: max 500 characters, truncate if exceeded
   - URL hallucination check: any URL in the summary must appear in the source review data
   - Sentiment score: pass-through from source (not LLM-generated)
6. **Event emission**: `enrichment.reviews_scraped` via `Events.emit_safe/1` after successful batch

## Reviewer Context
- `op.review_snapshots` table already exists with source ENUM (created in migration 20260305000012)
- The `source` column uses a Postgres ENUM `op.review_source`
- Together AI API key is configured via `VISION_TOGETHER_API_KEY` env var (same key used by vision sidecar)
- See `Stacks.AI.Client` for the existing HTTP + HMAC pattern

## Definition of Done
- [ ] `Stacks.Enrichment.Reviews` context with upsert_snapshot, latest_reviews, stale_books
- [ ] `FetchReviewsJob` fetches, summarizes, validates, and persists review snapshots
- [ ] `Stacks.AI.TogetherClient` with summarize_reviews/2
- [ ] Fuse circuit breaker protects Together AI calls
- [ ] URL hallucination validation on generated summaries
- [ ] `enrichment.reviews_scraped` event emitted on success
- [ ] Tests cover: context CRUD, worker success/failure, fuse blown path, hallucination detection
- [ ] `just verify` passes

## Dependencies
- Issue #046 (works/editions — complete)

## Agent Assignment
elixir-agent

## Progress Notes
