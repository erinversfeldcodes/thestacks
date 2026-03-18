# Issue #051: Author Intelligence, Events, Source Discovery + Geographic Sweep

## Summary
Build the remaining enrichment contexts: author intelligence (RSS, website, events), bookstore event discovery, source discovery agent (book-triggered + geographic sweep), and business opt-out flow.

## User Stories
US-2.3.1 (author intelligence), US-2.4.1 (bookstore events), US-2.5.1 (source discovery), US-2.5.2 (geographic sweep), US-2.5.3 (business opt-out)

## Goal
Author data is auto-discovered when books are added. Bookstore events are discovered and matched to the user's collection. The source discovery agent expands the enrichment network via Brave Search + SearXNG. Geographic sweeps find local spaces when a user sets their location. Businesses can opt out of being listed.

## Technical Requirements

**`Stacks.Enrichment.Authors` context:**
- `get_author_intel/1` — returns author website, RSS feed, latest posts, upcoming events
- `DiscoverAuthorSourcesJob` (Oban, weekly) — Brave Search for author website + RSS
- `FetchAuthorRSSJob` (Oban, hourly) — poll known RSS feeds, store latest posts
- RSS parsing via `feeder_ex` or similar
- Update `authors` table with `website_url`, `rss_feed_url` on discovery

**`Stacks.Enrichment.Events` context:**
- `get_matched_events/1` — join events with user's book/author graph
- `DiscoverBookstoreEventsJob` (Oban, daily) — search for events at bookstores
- Store in `bookstore_events` — FK to `bookstores` and optionally `authors`

**`Stacks.Discovery` context:**
- `SourceDiscoveryJob` (Oban, daily) — book-triggered discovery via Brave Search + SearXNG
- `ScoreSourceJob` (Oban, on-demand) — LLM confidence scoring per discovered URL
- `GeographicDiscoveryJob` (Oban, event-driven + quarterly cron) — location-based sweep: `"bookshop {city}"`, `"reading group {city}"`, etc. Triggered by `user.location_updated` event.
- `approve_source/1`, `reject_source/1` — human approval flow
- Exclusion list check: skip URLs where `discovered_sources.status = 'excluded'`

**Business opt-out (`StacksWeb.OptOutController`):**
- `POST /api/opt-out` — unauthenticated endpoint. Rate limit: 5/min.
- Accepts: business name, contact email, choice (remove / become partner)
- For removal: set `discovered_sources.status = 'excluded'` and/or `third_spaces.opted_out = true`
- For partnership: route to partner onboarding (Phase 2)
- `OptOutConfirmationJob` — sends confirmation email to business

**Search infrastructure:**
- Brave Search API client with rate limiting (2000 queries/month free tier)
- SearXNG fallback (self-hosted — deployment in Issue #063)
- Auto-fallback when approaching Brave free tier limit

## Definition of Done
- [ ] Author discovery finds website + RSS for a known author (mocked Brave Search)
- [ ] RSS feed polling stores latest posts
- [ ] Bookstore events discovered and matched to user's books
- [ ] Source discovery scores URLs with LLM confidence (mocked LLM)
- [ ] Geographic sweep finds local spaces for a configured city
- [ ] Business opt-out: `POST /api/opt-out` sets exclusion, sends confirmation
- [ ] Exclusion list prevents re-discovery of opted-out URLs
- [ ] Human approval flow: discover → score → approve/reject
- [ ] Circuit breakers on Brave Search and SearXNG calls
- [ ] `mix test` passes with mocked external services

## Dependencies
Issue #046 (books/authors must exist), Issue #043 (discovered_sources columns)

## Agent Assignment
elixir-agent (Opus — external API integration, LLM guardrails)

## Progress Notes
