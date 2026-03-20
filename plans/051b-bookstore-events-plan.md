# Plan: Issue #051b — Bookstore Events + Third Space Discovery

## Context

The `op.bookstore_events`, `op.third_spaces`, and `op.third_space_events` tables all exist. `space_type` enum: `reading_group, cafe, bookshop, festival, market`. The Bookstore Ecto schema exists at `Stacks.Enrichment.Bookstore`. No event or third space schemas exist yet. SearXNG URL is already configured in `runtime.exs` for prod.

## Key Decisions

1. **SearxngClient follows BraveClient pattern** — behaviour + mock, but no daily budget (self-hosted, unlimited).
2. **Event upsert keyed on `(store_id, title, event_date)`** — prevents duplicate event entries from re-scraping.
3. **Author linking is best-effort** — match event title/description against known author names, nullable FK.
4. **HTML parsing for event discovery** — use Req + basic regex/string matching, not a full HTML parser dep.

## Implementation Steps

### Step 1: Create Ecto schemas
- `Stacks.Enrichment.BookstoreEvent` — maps `op.bookstore_events`
- `Stacks.Enrichment.ThirdSpace` — maps `op.third_spaces`
- `Stacks.Enrichment.ThirdSpaceEvent` — maps `op.third_space_events`

### Step 2: Create `Stacks.Discovery.SearxngClient`
- Behaviour: `Stacks.Discovery.SearxngClientBehaviour`
- `search/2` — accepts query + opts, returns `{:ok, [%{title, url, description}]}` or `{:error, reason}`
- Uses Finch, JSON response from SearXNG API (`/search?q=...&format=json`)
- URL via `Application.get_env(:core, :searxng_url)`
- Mock: `Stacks.Discovery.MockSearxngClient`
- No rate limiting needed (self-hosted)

### Step 3: Create `Stacks.Enrichment.Events` context
- `upsert_event/1` — insert or update bookstore event (conflict: `store_id + title + event_date`)
- `upcoming_events/1` — returns future events for a store_id or space_id
- `upsert_third_space_event/1` — insert or update third space event

### Step 4: Create `DiscoverBookstoreEventsJob` (Oban worker)
- Queue: `:default`, max_attempts: 3
- Args: `%{store_id: id}` or `%{batch: true}`
- Batch: queries all bookstores with `website_url` set
- For each store: fetch events page (Req GET to store website), parse event data
- Link to author if name matches known authors
- Persist via `Events.upsert_event/1`
- Emit `enrichment.events_discovered` event

### Step 5: Add unique index migration
- New migration for `bookstore_events`: unique index on `(store_id, title, event_date)`

### Step 6: Configuration
- Add to `config.exs`: `config :core, :searxng_client, Stacks.Discovery.SearxngClient`
- Add to `config.exs`: `config :core, :searxng_url, "http://localhost:8888"` (dev default)
- Add to `test.exs`: `config :core, :searxng_client, Stacks.Discovery.MockSearxngClient`

## File Inventory

### New files
- `apps/core/lib/stacks/enrichment/bookstore_event.ex`
- `apps/core/lib/stacks/enrichment/third_space.ex`
- `apps/core/lib/stacks/enrichment/third_space_event.ex`
- `apps/core/lib/stacks/enrichment/events.ex`
- `apps/core/lib/stacks/discovery/searxng_client_behaviour.ex`
- `apps/core/lib/stacks/discovery/searxng_client.ex`
- `apps/core/lib/stacks/discovery/mock_searxng_client.ex`
- `apps/core/lib/stacks/workers/discover_bookstore_events_job.ex`
- `apps/core/priv/repo/migrations/TIMESTAMP_add_bookstore_events_unique_index.exs`
- `apps/core/test/stacks/enrichment/events_test.exs`
- `apps/core/test/stacks/workers/discover_bookstore_events_job_test.exs`
- `apps/core/test/stacks/discovery/searxng_client_test.exs`

### Modified files
- `apps/core/config/config.exs` — searxng_client + URL config
- `apps/core/config/test.exs` — mock searxng client
- `apps/core/test/support/factory.ex` — bookstore_event, third_space, third_space_event factories
