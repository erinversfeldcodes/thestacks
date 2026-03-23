# US-2.5.2 — Geographic Discovery Sweep

## 1. User Story

> **As a** user, **I want** the system to discover bookshops, reading groups, and literary spaces in my area based on my location **so that** my Third Spaces page is populated with relevant local results even before I add books.

The user sets their location in their profile. The system immediately triggers a geographic discovery sweep for the configured city and country. The agent searches for "bookshop {city}", "reading group {city}", "book club {city}", "literary festival {city}", "book cafe {city}" using Brave Search and SearXNG. Discovered spaces are evaluated by the LLM and queued for the platform owner's approval. The sweep repeats quarterly. Results merge with book-specific source discovery on the Third Spaces page.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to Settings and updates their location (city + country).
2. The `user.location_updated` event is emitted.
3. `LocationUpdatedHandler` enqueues a `GeographicDiscoveryJob`.
4. The job builds 5 search queries and enqueues a `SourceDiscoveryJob` for each.
5. Each `SourceDiscoveryJob` searches Brave/SearXNG, creates `DiscoveredSource` records, and enqueues `ScoreSourceJob` for scoring.
6. After approval by the platform owner (via `/admin/sources`), discovered spaces appear on the Third Spaces page.

### Sad Paths
- **No location set**: No event emitted, no sweep triggered.
- **Search failures**: `SourceDiscoveryJob` handles Brave/SearXNG failures with fallback and retry logic (see US-2.5.1).
- **No results**: Empty search results produce no new sources — no error, just no new data.

### Elm State Machine
- **Page module**: N/A — discovery is entirely background-driven. Results surface on existing pages (Third Spaces, Admin Source Approval).
- **Msg flow**: N/A
- **RemoteData states**: N/A

---

## 3. API Calls

### `PUT /api/settings/location` (trigger)
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UserSettingsController.update_location/2`
- **Request body**: `{ city: string, country_code: string }`
- **Response (success)**: Updated user settings — HTTP 200
- **Side effect**: Emits `user.location_updated` event

The geographic sweep itself has no dedicated API endpoint — it is fully background-driven.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `AuthPipeline` (for the settings update)
- **Visibility checks**: N/A — background process
- **Age gate**: N/A
- **Ownership checks**: User can only update their own location

---

## 5. Database Interactions

### Write: Create discovered sources
- **Table(s)**: `op.discovered_sources`
- **Operation**: INSERT (via `SourceDiscoveryJob` -> `Discovery.create_source/1`)
- **Changeset validations**: See US-2.5.1
- **Deduplication**: By URL before insert
- **discovered_via field**: Set to `"search:<query> location:<city>,<cc>"` for geographic results

### Read: Sources for location
- **Table(s)**: `op.discovered_sources`
- **Query**: `Discovery.sources_for_location(city, country_code)` — filters approved sources where `discovered_via ILIKE '%city%'` and `discovered_via ILIKE '%country_code%'`
- **Schema module**: `Stacks.Enrichment.DiscoveredSource`

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### Location update (trigger)
- **Event type**: `user.location_updated`
- **Aggregate**: `user` + user_id
- **Payload**: `{ city, country_code }`
- **Emitted by**: `Stacks.Accounts` (settings update)

#### Source discovery (downstream)
- **Event type**: `enrichment.sources_discovered`
- **See**: US-2.5.1 for details

### Event Handlers Triggered
- **Handler**: `Stacks.Discovery.Handlers.LocationUpdatedHandler`
- **Listens for**: `user.location_updated` (both atom-keyed and string-keyed payloads)
- **Action**: Enqueues `GeographicDiscoveryJob` with `{ city, country_code }`
- **Downstream effects**: 5 `SourceDiscoveryJob` instances enqueued, each with a location-aware search query

---

## 7. Background Jobs (Oban)

### GeographicDiscoveryJob
- **Worker**: `Stacks.Workers.GeographicDiscoveryJob`
- **Queue**: `:default`
- **Args**: `%{"city" => city, "country_code" => country_code}`
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Builds 5 search queries using `build_queries/2`:
     - `"bookshops in {city}"`
     - `"independent bookstores {city}"`
     - `"reading groups {city}"`
     - `"book clubs {city} {country_name}"`
     - `"literary events {city}"`
  2. Maps country codes to full names (ZA -> "South Africa", GB -> "United Kingdom", etc.)
  3. Enqueues a `SourceDiscoveryJob` for each query, passing `location: %{"city" => city, "country_code" => cc}`
- **On success**: 5 discovery jobs enqueued
- **On failure**: Individual enqueue failures logged; other queries still enqueued

### SourceDiscoveryJob (downstream)
See US-2.5.1 for full details. Each job runs with location context, which is encoded in the `discovered_via` field.

### ScoreSourceJob (downstream)
See US-2.5.1 for full details.

---

## 8. External Service Calls

### Brave Search API
See US-2.5.1 for full details. Geographic queries use the same search infrastructure.

### SearXNG
See US-2.5.1 for full details.

### Together AI (scoring)
See US-2.5.1 for full details.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

Same as US-2.5.1 — geographic discoveries feed into the same `int_source_approval_rate` and `int_source_health` models.

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A — geographic discovery is a background process. Results surface through:
- `Page.Admin.SourceApproval` (`/admin/sources`) for approval
- Third Spaces page for display

### Init
N/A — no dedicated page.

### Update cycle
N/A — triggered by `user.location_updated` event, not by UI interaction.

### View
N/A — discovered sources appear on existing pages after approval.

---

## 13. Operational Metrics

- **Oban job counts for `GeographicDiscoveryJob`**: enqueued (per `user.location_updated` event + quarterly sweeps), completed, failed, retried
- **Oban job counts for downstream `SourceDiscoveryJob`**: 5 jobs enqueued per `GeographicDiscoveryJob` run — tracked individually
- **Oban job counts for downstream `ScoreSourceJob`**: one per discovered source from geographic queries
- **Brave Search API call counts**: up to 5 queries per geographic sweep — significant budget impact (67/day limit). Track daily budget consumption vs geographic sweep frequency.
- **SearXNG fallback rate**: percentage of geographic queries that fall back to SearXNG due to Brave budget exhaustion
- **Event handler execution times**: `LocationUpdatedHandler` latency from `user.location_updated` to `GeographicDiscoveryJob` enqueue
- **dbt refresh job duration**: same models as US-2.5.1 (`int_source_approval_rate`, `int_source_health`)

---

## 14. Performance & Usability Metrics

- **Source discovery yield per geography**: sources found per city/country sweep — derivable from `enrichment.sources_discovered` events where `discovered_via` contains `location:` prefix
- **Geographic coverage**: number of distinct cities with at least one approved source — derivable from `discovered_via` field parsing
- **Query effectiveness by category**: yield per query type (bookshops, independent bookstores, reading groups, book clubs, literary events) — identifies which search templates produce the most relevant results
- **Duplicate rate for geographic queries**: percentage of search results already known from prior sweeps or book-specific discovery — higher duplicate rates suggest diminishing returns from quarterly re-sweeps
- **Time from location update to first approved source**: end-to-end latency including discovery, scoring, and platform owner approval

---

## 15. Cost Tracking

- **Brave Search API**: 5 queries per geographic sweep. At 2000 free queries/month, a single sweep consumes 0.25% of the monthly budget. Quarterly sweeps are low-impact; frequent location changes could strain the budget. Beyond free tier: $3-5/1000 queries.
- **Together AI** (source scoring): same per-source cost as US-2.5.1. Geographic sweeps may produce 10-50 sources per city, so scoring cost per sweep: $0.001-$0.005.
- **SearXNG**: self-hosted, no per-query cost. Geographic queries are the primary intended use case for the SearXNG fallback.
- **Fly.io compute**: core app machine time for `GeographicDiscoveryJob` (lightweight — just enqueues 5 downstream jobs) plus the downstream `SourceDiscoveryJob` and `ScoreSourceJob` workers. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: same as US-2.5.1. Geographic queries produce the same database operations (duplicate checks, source inserts, confidence updates). Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Budget planning**: a platform with 10 users updating locations monthly would consume ~50 Brave queries/month for geographic sweeps alone — 2.5% of the free tier.
