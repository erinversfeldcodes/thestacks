# Plan: Issue #051c — Source Discovery + Geographic Sweep + Opt-Out

## Context

The `op.discovered_sources` table exists with `source_status` enum (`pending_review, approved, dismissed, excluded`) and `source_type` enum (`bookshop, review_site, community, event_source`). The `user.location_updated` event is already emitted by `Accounts.update_location/2` with payload `{country_code, city}`. BraveClient and SearxngClient (from #051a and #051b) are available.

## Key Decisions

1. **Status enum alignment** — the DB uses `pending_review`, not `pending`. All code must use `"pending_review"`.
2. **TogetherClient shared with #050b** — reuse the same LLM client for confidence scoring.
3. **Geographic discovery triggered by event** — register handler for `user.location_updated` in Events.Registry.
4. **Opt-out is unauthenticated** — businesses don't need a platform account. Validates email format and URL match.
5. **Deduplication by URL** — `get_source_by_url/1` before creating.

## Implementation Steps

### Step 1: Create `Stacks.Enrichment.DiscoveredSource` schema
- Maps `op.discovered_sources`
- Fields: id, name, type, url, confidence, discovered_via, discovered_at, status, approved_at, config_generated, excluded_at, exclusion_email, timestamps
- Changeset validates: required `[:name, :type, :url, :discovered_at, :status]`

### Step 2: Create `Stacks.Discovery` context
- `create_source/1` — insert with `status: "pending_review"` + `discovered_at: now`
- `get_source_by_url/1` — dedup check before inserting
- `update_source_status/2` — set status (approve, reject, exclude)
- `opt_out/2` — accepts `%{url, email}`, sets `status: "excluded"`, `excluded_at`, `exclusion_email`
- `pending_sources/0` — returns sources with `status: "pending_review"`
- `sources_for_location/2` — returns approved sources matching city/country

### Step 3: Create `SourceDiscoveryJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{query: query, location: %{city, country_code}}` or `%{batch: true}`
- Uses BraveClient (primary) with SearxngClient (fallback on budget exhaustion)
- Deduplicates against existing sources by URL
- Creates new sources with `status: "pending_review"`
- Enqueues `ScoreSourceJob` for each new source
- Emits `enrichment.sources_discovered` event

### Step 4: Create `ScoreSourceJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{source_id: id}`
- Calls TogetherClient to score confidence (0.0-1.0) based on source name, URL, type
- Updates `discovered_sources.confidence` field
- Sources with confidence > 0.8 logged for platform owner review

### Step 5: Create `GeographicDiscoveryJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{city: city, country_code: country_code}`
- Builds search queries: `"bookshops in {city}"`, `"reading groups {city}"`, `"book clubs {city} {country}"`
- Enqueues `SourceDiscoveryJob` for each query

### Step 6: Create event handler for `user.location_updated`
- `Stacks.Discovery.Handlers.LocationUpdatedHandler`
- On `user.location_updated`: extract city + country_code from payload, enqueue `GeographicDiscoveryJob`
- Register in Events.Registry

### Step 7: Create `StacksWeb.OptOutController`
- `POST /api/opt-out` — unauthenticated
- Accepts: `%{url: url, email: email, reason: reason}`
- Validates: email format, URL must match existing discovered source
- Calls `Discovery.opt_out/2`
- Returns: 200 on success, 404 if URL not found, 422 on validation error
- Add route in router under unauthenticated `:api` scope

### Step 8: Configuration
- Register `LocationUpdatedHandler` in Events.Registry for `"user.location_updated"`

## File Inventory

### New files
- `apps/core/lib/stacks/enrichment/discovered_source.ex`
- `apps/core/lib/stacks/discovery.ex`
- `apps/core/lib/stacks/discovery/handlers/location_updated_handler.ex`
- `apps/core/lib/stacks/workers/source_discovery_job.ex`
- `apps/core/lib/stacks/workers/score_source_job.ex`
- `apps/core/lib/stacks/workers/geographic_discovery_job.ex`
- `apps/core/lib/stacks_web/controllers/opt_out_controller.ex`
- `apps/core/test/stacks/discovery_test.exs`
- `apps/core/test/stacks/workers/source_discovery_job_test.exs`
- `apps/core/test/stacks/workers/score_source_job_test.exs`
- `apps/core/test/stacks/workers/geographic_discovery_job_test.exs`
- `apps/core/test/stacks_web/controllers/opt_out_controller_test.exs`
- `apps/core/test/stacks/discovery/handlers/location_updated_handler_test.exs`

### Modified files
- `apps/core/lib/stacks/events/registry.ex` — add `"user.location_updated"` handler
- `apps/core/lib/core_web/router.ex` — add `POST /api/opt-out` route
- `apps/core/test/support/factory.ex` — discovered_source factory
