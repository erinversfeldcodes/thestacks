# Issue #051c: Source Discovery + Geographic Sweep + Opt-Out

## Summary
Build the automated source discovery system: find new bookstores and third spaces via search APIs, score them with LLM confidence, run geographic sweeps for user locations, and provide an opt-out endpoint for businesses.

## User Stories
US-6.3 — "As a bookshop owner, I want to opt out of being listed if I choose."
US-7.1 — "As a user, I want to discover bookshops near me automatically."

## Goal
The platform automatically discovers bookstores and community spaces relevant to users' locations. Discovered sources are scored for confidence, queued for platform owner approval, and can be opted out by the business via a public endpoint.

## Scope Check
- 1 context (`Stacks.Discovery`)
- 3 Oban workers (`SourceDiscoveryJob`, `ScoreSourceJob`, `GeographicDiscoveryJob`)
- 1 new endpoint (`POST /api/opt-out`)
- ~400 LOC

## Wiring
- [x] This issue includes router wiring for the opt-out endpoint.

## Technical Requirements

1. **`Stacks.Discovery` context**:
   - `create_source/1` — insert into `op.discovered_sources` with status `:pending`
   - `get_source_by_url/1` — dedup check before inserting
   - `update_source_status/2` — approve, reject, or exclude
   - `opt_out/2` — sets `status: :excluded`, `excluded_at`, `exclusion_email`
   - `pending_sources/0` — returns sources awaiting approval
   - `sources_for_location/2` — returns approved sources near a city/country
2. **`SourceDiscoveryJob`** (Oban worker, queue: `:default`):
   - Accepts `%{query: query, location: location}` or `%{batch: true}`
   - Uses `BraveClient.search/2` (primary) with `SearxngClient.search/2` (fallback)
   - Deduplicates against existing sources by URL
   - Creates new sources with `status: :pending`
   - Enqueues `ScoreSourceJob` for each new source
3. **`ScoreSourceJob`** (Oban worker, queue: `:default`):
   - Accepts `%{source_id: id}`
   - Calls Together AI to score confidence (0.0-1.0) based on source metadata
   - Updates `discovered_sources.confidence` field
   - Sources with confidence > 0.8 are auto-flagged for review
4. **`GeographicDiscoveryJob`** (Oban worker, queue: `:default`):
   - Triggered by `user.location_updated` event
   - Searches for bookstores/third spaces near the user's city + country
   - Enqueues `SourceDiscoveryJob` for each search query
5. **`StacksWeb.OptOutController`**:
   - `POST /api/opt-out` — unauthenticated endpoint
   - Accepts `%{url: url, email: email, reason: reason}`
   - Validates email format, URL must match an existing discovered source
   - Sets source status to `:excluded` with exclusion metadata
   - Returns 200 on success, 404 if URL not found, 422 on validation error
6. **Event emission**: `enrichment.sources_discovered` via `Events.emit_safe/1`

## Reviewer Context
- `op.discovered_sources` table already exists with `status` ENUM and `excluded_at` / `exclusion_email` columns (migration 20260305000011)
- The opt-out endpoint is unauthenticated by design — businesses should not need a platform account to opt out
- Brave Search has a 2000 queries/month free tier — `BraveClient` (from #051a) handles rate limiting
- `user.location_updated` event is already emitted by `Accounts.update_location/2` (from #048)

## Definition of Done
- [ ] `Stacks.Discovery` context with create_source, get_source_by_url, opt_out, pending_sources, sources_for_location
- [ ] `SourceDiscoveryJob` discovers sources via Brave/SearXNG and deduplicates
- [ ] `ScoreSourceJob` scores source confidence via Together AI
- [ ] `GeographicDiscoveryJob` triggers discovery for user locations
- [ ] `POST /api/opt-out` endpoint works for unauthenticated business opt-out
- [ ] `enrichment.sources_discovered` event emitted on success
- [ ] Tests cover: context CRUD, all 3 workers, opt-out controller (success + error paths)
- [ ] `just verify` passes

## Dependencies
- Issue #051a (Brave client — shared dependency)
- Issue #043 (discovered_sources table — complete)

## Agent Assignment
elixir-agent

## Progress Notes
