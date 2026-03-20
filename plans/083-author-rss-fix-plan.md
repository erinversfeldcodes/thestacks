# Plan: Issue #083 — Author RSS Test Coverage + RFC 2822 Parsing Fix

## Context

`FetchAuthorRSSJob.try_rfc2822/1` always returns `nil`, making RSS polling effectively inert. Timex is already available as a transitive dep from ElixirFeedParser. The catch-all on AuthorDiscoveryHandler and the bare rescue in discover_rss_feed were already fixed in Phase 2 review fixes.

## Remaining Items

1. **Fix RFC 2822 parsing** — use `Timex.parse/2` with `"{RFC822}"` format
2. **Extract RSS fetch behind behaviour** — `RssFetcherBehaviour` with `fetch_and_parse/1`
3. **Test happy path** — mock RSS fetcher returns parsed entries, verify filtering + event emission

## Implementation Steps

### Step 1: Fix `try_rfc2822/1`
- Replace the no-op with: `Timex.parse(date_string, "{RFC822}")` → `{:ok, datetime}` → convert to UTC DateTime
- Fallback: try `"{RFC822z}"` format variant
- On parse failure: return nil (existing behaviour, logged)

### Step 2: Extract RSS fetch behaviour
- `Stacks.Enrichment.RssFetcherBehaviour` with `@callback fetch_and_parse(url :: String.t()) :: {:ok, map()} | {:error, term()}`
- `Stacks.Enrichment.RssFetcher` — real implementation (current `fetch_and_parse/1` logic from FetchAuthorRSSJob)
- `Stacks.Enrichment.MockRssFetcher` — process dictionary mock
- Wire via `config :core, :rss_fetcher, Stacks.Enrichment.RssFetcher`

### Step 3: Update FetchAuthorRSSJob
- Replace inline `fetch_and_parse/1` with call to configured `rss_fetcher()`
- Keep `parse_feed`, `filter_recent_entries`, `parse_date` logic in the job (parsing is job responsibility)

### Step 4: Write happy path tests
- Mock RSS fetcher returns `{:ok, %{entries: [%{title, url, published, summary}]}}`
- Test: entries with RFC 2822 dates are correctly parsed and filtered
- Test: event `enrichment.author_updated` is emitted with correct payload
- Test: entries older than 24 hours are filtered out

## File Inventory

### New files
- `apps/core/lib/stacks/enrichment/rss_fetcher_behaviour.ex`
- `apps/core/lib/stacks/enrichment/rss_fetcher.ex`
- `apps/core/lib/stacks/enrichment/mock_rss_fetcher.ex`

### Modified files
- `apps/core/lib/stacks/workers/fetch_author_rss_job.ex` — fix try_rfc2822, use rss_fetcher behaviour
- `apps/core/test/stacks/workers/fetch_author_rss_job_test.exs` — add happy path tests
- `apps/core/config/config.exs` — rss_fetcher config
- `apps/core/config/test.exs` — mock rss_fetcher
