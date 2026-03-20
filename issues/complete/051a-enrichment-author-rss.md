# Issue #051a: Author Intelligence + RSS Polling

## Summary
Build author enrichment: discover author websites and RSS feeds via Brave Search, poll RSS feeds for new content, and update author records.

## User Stories
US-6.1 — "As a user, I want to see author news and updates so I stay connected to writers I follow."

## Goal
When an author is added to the system, a background job searches for their website and RSS feed. Discovered feeds are polled periodically. New content triggers events that downstream consumers (notifications, blog associations) can act on.

## Scope Check
- 1 context (`Stacks.Enrichment.Authors`)
- 2 Oban workers (`DiscoverAuthorSourcesJob`, `FetchAuthorRSSJob`)
- 0 new endpoints
- ~400 LOC

## Wiring
- [x] This issue is implementation only. Author updates surface via notifications in a future issue.

## Technical Requirements

1. **Add RSS parser dependency** — `feeder_ex` or similar to `apps/core/mix.exs`
2. **Brave Search API client** (`Stacks.Discovery.BraveClient`):
   - `search/2` — accepts query string + opts, returns list of result maps
   - Rate limited: free tier is 2000 queries/month (~67/day)
   - Uses `Req` HTTP client with API key header
   - Respects `TEST_TARGET` env var
3. **`Stacks.Enrichment.Authors` context**:
   - `update_author_sources/2` — sets `website_url`, `rss_feed_url` on author record
   - `authors_without_sources/0` — returns authors missing website_url or rss_feed_url
   - `authors_with_rss/0` — returns authors with rss_feed_url set
4. **`DiscoverAuthorSourcesJob`** (Oban worker, queue: `:default`):
   - Accepts `%{author_id: id}` or `%{batch: true}`
   - Searches Brave for `"{author_name}" official website OR blog`
   - Extracts website URL and RSS feed URL from results
   - Updates author record via `Authors.update_author_sources/2`
   - Triggered by `book.created` event (new author discovered)
5. **`FetchAuthorRSSJob`** (Oban worker, queue: `:default`, cron: daily):
   - Fetches RSS feed for each author with `rss_feed_url` set
   - Parses feed entries via RSS parser
   - Emits `enrichment.author_updated` event with new entries in payload
   - On feed parse failure: log warning, do not crash
6. **Event emission**: `enrichment.author_updated` via `Events.emit_safe/1`

## Reviewer Context
- `op.authors` already has `website_url` and `rss_feed_url` columns (created in migration 20260305000004)
- Brave Search API key should be configured via `BRAVE_SEARCH_API_KEY` env var
- Rate limit: 2000 queries/month on free tier — implement daily budget tracking

## Definition of Done
- [ ] RSS parser dependency added and compiles
- [ ] `Stacks.Discovery.BraveClient` with search/2
- [ ] `Stacks.Enrichment.Authors` context with update_author_sources, authors_without_sources, authors_with_rss
- [ ] `DiscoverAuthorSourcesJob` discovers author websites via Brave Search
- [ ] `FetchAuthorRSSJob` polls RSS feeds and emits events
- [ ] Tests cover: Brave client (mocked), author context CRUD, both workers
- [ ] `just verify` passes

## Dependencies
- Issue #046 (works/editions — complete)
- Issue #043 (author schema — complete)

## Agent Assignment
elixir-agent

## Progress Notes
