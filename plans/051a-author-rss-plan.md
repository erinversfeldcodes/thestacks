# Plan: Issue #051a — Author Intelligence + RSS Polling

## Context

Authors are auto-created when books are added via ISBN resolver. The `op.authors` table has `website_url`, `rss_feed_url`, and `open_library_id` columns, but the Ecto schema only maps `name`, `bio`, and `website_url`. No enrichment infrastructure exists. The Events Registry is empty — this will register the first event handler.

## Key Decisions

1. **Fix Author schema first** — add missing `rss_feed_url` and `open_library_id` fields before building enrichment.
2. **BraveClient as a behaviour** — swappable for tests. Rate-limit tracking via a simple daily counter in ETS or application env.
3. **RSS parser: `ElixirFeedParser`** — pure Elixir, no NIFs, handles RSS 2.0 + Atom. Alternative: `feeder_ex` but less maintained.
4. **Enrichment.Authors is a new context** — separate from `Stacks.Books` which owns the Author schema. The enrichment context queries authors but doesn't own the schema.
5. **Daily cron for RSS polling** — `FetchAuthorRSSJob` runs once per day, processes all authors with `rss_feed_url` set.

## Implementation Steps

### Step 1: Fix Author schema
- Add `field :rss_feed_url, :string` and `field :open_library_id, :string` to `apps/core/lib/stacks/books/author.ex`
- Add both to the changeset cast list
- Update factory to include these fields

### Step 2: Add RSS parser dependency
- Add `{:elixir_feed_parser, "~> 2.1"}` to `apps/core/mix.exs` (or `{:feeder_ex, "~> 1.1"}` — evaluate which is better maintained)
- Run `mix deps.get`

### Step 3: Create `Stacks.Discovery.BraveClient`
- Behaviour: `Stacks.Discovery.BraveClientBehaviour`
- `search/2` — accepts query string + opts (limit, offset), returns `{:ok, [result]}` or `{:error, reason}`
- Uses `Finch` with `Stacks.Finch` pool
- API key via `Application.get_env(:core, :brave_search_api_key)`
- Rate tracking: simple counter in process state or ETS, reject if > 67/day (2000/month ÷ 30)
- Mock: `Stacks.Discovery.MockBraveClient`

### Step 4: Create `Stacks.Enrichment.Authors` context
- `update_author_sources/2` — updates `website_url`, `rss_feed_url` on author record via `Books.Author` changeset
- `authors_without_sources/0` — `from(a in Author, where: is_nil(a.website_url) or is_nil(a.rss_feed_url))`
- `authors_with_rss/0` — `from(a in Author, where: not is_nil(a.rss_feed_url))`
- Note: this context queries `Books.Author` but does NOT own the schema — `Books` owns it.

### Step 5: Create `DiscoverAuthorSourcesJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{author_id: id}` or `%{batch: true}`
- Batch mode: queries `Authors.authors_without_sources/0`
- For each author: search Brave for `"{name}" official website OR blog`
- Parse results: extract first URL that looks like a personal site (not social media)
- Look for RSS feed: check `<link rel="alternate" type="application/rss+xml">` in HTML, or try `/feed`, `/rss`, `/feed.xml`
- Update author via `Authors.update_author_sources/2`
- On failure: log, return `{:error, reason}` for retry

### Step 6: Create `FetchAuthorRSSJob` (Oban worker, cron: daily)
- Queue: `:default`, max_attempts: 3
- No args (batch-only, processes all authors with RSS)
- Queries `Authors.authors_with_rss/0`
- For each author: fetch RSS feed URL, parse with RSS parser
- Extract entries from last 24 hours (since last poll)
- Emit `enrichment.author_updated` event with entries in payload
- On feed parse failure: log warning, skip author, continue

### Step 7: Event handler for `book.created`
- Create `Stacks.Enrichment.Handlers.AuthorDiscoveryHandler`
- On `book.created`: extract author info from event, check if author has sources
- If not: enqueue `DiscoverAuthorSourcesJob` for that author
- Register in `Stacks.Events.Registry`

### Step 8: Configuration
- Add to `config.exs`: `config :core, :brave_client, Stacks.Discovery.BraveClient`
- Add to `runtime.exs`: optional `BRAVE_SEARCH_API_KEY` env var
- Add to `test.exs`: `config :core, :brave_client, Stacks.Discovery.MockBraveClient`
- Add cron: `{"0 7 * * *", Stacks.Workers.FetchAuthorRSSJob}` (7 AM UTC, after price scrape)

### Step 9: Event emission
- `FetchAuthorRSSJob` emits `enrichment.author_updated` with payload `%{author_id, new_entries: [...]}`
- Uses `Events.emit_safe/1`

## File Inventory

### New files
- `apps/core/lib/stacks/discovery/brave_client.ex`
- `apps/core/lib/stacks/discovery/brave_client_behaviour.ex`
- `apps/core/lib/stacks/discovery/mock_brave_client.ex`
- `apps/core/lib/stacks/enrichment/authors.ex`
- `apps/core/lib/stacks/enrichment/handlers/author_discovery_handler.ex`
- `apps/core/lib/stacks/workers/discover_author_sources_job.ex`
- `apps/core/lib/stacks/workers/fetch_author_rss_job.ex`
- `apps/core/test/stacks/enrichment/authors_test.exs`
- `apps/core/test/stacks/workers/discover_author_sources_job_test.exs`
- `apps/core/test/stacks/workers/fetch_author_rss_job_test.exs`
- `apps/core/test/stacks/discovery/brave_client_test.exs`

### Modified files
- `apps/core/mix.exs` — add RSS parser dep
- `apps/core/lib/stacks/books/author.ex` — add rss_feed_url, open_library_id fields
- `apps/core/lib/stacks/events/registry.ex` — register book.created handler
- `apps/core/config/config.exs` — brave_client config, cron entry
- `apps/core/config/test.exs` — mock brave client
- `apps/core/config/runtime.exs` — BRAVE_SEARCH_API_KEY
- `apps/core/test/support/factory.ex` — update author factory

## Shared Dependencies with #050a

Both issues modify `Stacks.Events.Registry` to register `book.created` handlers. If implemented in parallel:
- Each adds its handler module to the registry's `"book.created"` list
- The registry supports multiple handlers per event type — no conflict
- Merge will combine both handler lists

## Verification
1. Author schema has `rss_feed_url` and `open_library_id` fields
2. `mix test` passes — all new tests + existing author tests
3. BraveClient mocked in tests — no real API calls
4. RSS parsing tested with fixture feed data
5. Event handler triggers discovery on `book.created`
6. `just verify` passes
