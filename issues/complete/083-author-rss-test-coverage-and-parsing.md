# Issue #083: Author RSS — Test Coverage + RFC 2822 Parsing Fix

## Summary
Fix three gaps in the author RSS enrichment infrastructure identified during PE review of #051a: RFC 2822 date parsing is a no-op, RSS fetch has no mock/behaviour for testing, and RSS URL discovery makes bare HTTP calls without error logging.

## User Stories
N/A — test coverage and correctness fix.

## Goal
The FetchAuthorRSSJob correctly parses real RSS feeds (which use RFC 2822 dates) and the happy path is tested without network calls.

## Scope Check
- 1 module modified (FetchAuthorRSSJob)
- 1 behaviour extracted (RSS fetch)
- 0 new endpoints
- ~150 LOC

## Wiring
- [x] This issue is implementation only. No router wiring needed.

## Technical Requirements

1. **Fix RFC 2822 date parsing** — `try_rfc2822/1` in `FetchAuthorRSSJob` currently always returns `nil`. Add a working parser (Timex dep, or regex-based for the common `Thu, 20 Mar 2026 10:00:00 +0000` format). Without this, `filter_recent_entries/1` discards all real RSS entries.

2. **Extract RSS fetch behaviour** — Create `Stacks.Enrichment.RssFetcherBehaviour` with `fetch_and_parse/1` callback. Real implementation uses Finch + ElixirFeedParser. Mock implementation for tests. Wire via application env like BraveClient/ScraperClient.

3. **Test happy path** — FetchAuthorRSSJob test should verify: successful XML parsing, date filtering, event emission with correct payload. Use mock RSS fetcher, not real HTTP calls.

4. **Fix `discover_rss_feed/1` error handling** — The `rescue _` in `DiscoverAuthorSourcesJob.try_fetch_feed/1` should at minimum log the exception rather than swallowing silently.

5. **Add catch-all `handle_event/1`** to `AuthorDiscoveryHandler` (defensive, matches BookCreatedHandler pattern).

## Reviewer Context
- This issue addresses PE review findings P2-1, P2-2, P2-3, P3-4 from the #051a review.

## Definition of Done
- [ ] RFC 2822 dates parse correctly (test with common RSS date format)
- [ ] RSS fetch is behind a behaviour, mocked in tests
- [ ] FetchAuthorRSSJob happy path tested (parse + filter + emit)
- [ ] `rescue _` logs the exception in discover_rss_feed
- [ ] AuthorDiscoveryHandler has catch-all clause
- [ ] `just verify` passes

## Dependencies
Issue #051a (author RSS — complete).

## Agent Assignment
elixir-agent

## Progress Notes
