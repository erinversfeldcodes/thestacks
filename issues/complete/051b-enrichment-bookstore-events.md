# Issue #051b: Bookstore Events + Third Space Discovery

## Summary
Build event discovery for bookstores and third spaces: scrape event listings, discover new community spaces, and persist to `op.bookstore_events` and `op.third_space_events`.

## User Stories
US-6.2 — "As a user, I want to discover book events near me (readings, signings, book clubs)."

## Goal
Background workers discover events at known bookstores and third spaces. Events are scraped, parsed, and persisted. New third spaces can be discovered via search.

## Scope Check
- 1 context (`Stacks.Enrichment.Events`)
- 1 Oban worker (`DiscoverBookstoreEventsJob`)
- 0 new endpoints
- ~300 LOC

## Wiring
- [x] This issue is implementation only. Events surface via a future discovery/events endpoint.

## Technical Requirements

1. **`Stacks.Enrichment.Events` context**:
   - `upsert_event/1` — insert or update bookstore event (keyed on `store_id + title + event_date`)
   - `upcoming_events/1` — returns events in the future for a given store/space
   - `upsert_third_space_event/1` — insert or update third space event
2. **`DiscoverBookstoreEventsJob`** (Oban worker, queue: `:default`):
   - Accepts `%{store_id: id}` or `%{batch: true}`
   - Fetches event listings from bookstore websites (via Req, HTML parsing)
   - Parses event data: title, description, event_date, location, URL
   - Links to author if author name matches known authors
   - Persists via `Events.upsert_event/1`
3. **SearXNG fallback client** (`Stacks.Discovery.SearxngClient`):
   - `search/2` — accepts query + opts, returns results
   - Used as fallback when Brave Search quota is exhausted
   - Configurable instance URL via `SEARXNG_URL` env var
4. **Event emission**: `enrichment.events_discovered` via `Events.emit_safe/1`

## Reviewer Context
- `op.bookstore_events` and `op.third_space_events` tables already exist (migrations 20260305000015, 20260305000017)
- `op.bookstore_events` has FK to `op.bookstores` and optional FK to `op.authors`
- SearXNG is self-hosted — the URL must be configurable, not hardcoded

## Definition of Done
- [ ] `Stacks.Enrichment.Events` context with upsert_event, upcoming_events, upsert_third_space_event
- [ ] `DiscoverBookstoreEventsJob` scrapes and persists bookstore events
- [ ] `Stacks.Discovery.SearxngClient` with search/2
- [ ] `enrichment.events_discovered` event emitted on success
- [ ] Tests cover: context CRUD, worker success/failure, SearXNG client (mocked)
- [ ] `just verify` passes

## Dependencies
- Issue #043 (bookstore/third_space tables — complete)

## Agent Assignment
elixir-agent

## Progress Notes
