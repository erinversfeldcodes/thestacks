# US-2.4.1 — Discover Relevant Bookstore Events

## 1. User Story

> **As a** user, **I want to** be notified of bookstore events related to authors and books in my collection **so that** I can attend signings, readings, and launches in person.

The system scrapes bookstores with physical locations for upcoming events (signings, readings, launches, book clubs). Events are matched against the user's collection -- if the user owns books by the featured author, the event is surfaced. Events appear on the book detail overlay (under "The Author") and on the Third Spaces page.

The user sees a highlighted event card: "Exclusive Books Rosebank: Damon Galgut signing, March 15 -- you own 2 of his books." The card includes date, time, venue, a brief description, and a link to the event page. Events are styled with a warm amber highlight.

---

## 2. UI Interaction Flow

### Happy Path
1. The system runs `DiscoverBookstoreEventsJob` periodically (batch mode) or per-store.
2. Events scraped from bookstore websites are parsed and persisted to `op.bookstore_events`.
3. Events with a matching `author_id` (linked to an author the user has books by) are surfaced.
4. On the book detail overlay, the `Components.AuthorCard` displays the event count.
5. On the Third Spaces page, events appear as amber-highlighted cards.

### Sad Paths
- **Store website fetch failure**: Logged and recorded in monitoring; store appears as degraded/broken in metrics.
- **No events found**: No cards rendered; "No upcoming events" shown in author section.
- **Store not found**: `{:cancel, "store not found"}` returned; job does not retry.

### Elm State Machine
- **Component module**: `Components.AuthorCard` (events count display)
- **Model fields involved**: `AuthorEnrichment.upcomingEventsCount`
- **Msg flow**: N/A — data passed as props
- **RemoteData states**: N/A — uses Maybe
- **OutMsg pattern**: N/A

---

## 3. API Calls

Event data is served as part of the book detail response (author enrichment). The events themselves are populated by background workers.

### `GET /api/books/:id`
- **Auth**: Optional
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Visibility checks**: Inherits from book detail
- **Age gate**: If applicable
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Read: Upcoming bookstore events
- **Table(s)**: `op.bookstore_events`
- **Query**: `Events.upcoming_events(store_id)` -- `WHERE store_id = ? AND event_date >= NOW() ORDER BY event_date ASC`
- **Indexes used**: Index on `(store_id, event_date)`
- **Schema module**: `Stacks.Enrichment.BookstoreEvent`

### Write: Upsert bookstore event
- **Table(s)**: `op.bookstore_events`
- **Operation**: INSERT ON CONFLICT UPDATE
- **Changeset validations**: Required: `store_id`, `title`, `event_date`, `scraped_at`. Optional: `description`, `location`, `url`, `author_id`
- **Transaction**: No — individual upserts per event
- **Denormalization**: `author_id` links events to known authors
- **Conflict target**: `(store_id, title, event_date)`

### Read: Known authors (for event matching)
- **Table(s)**: `op.authors`
- **Query**: `SELECT id, name FROM op.authors` — loaded in `DiscoverBookstoreEventsJob.load_known_authors/0`
- **Schema module**: `Stacks.Books.Author`

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `enrichment.events_discovered`
- **Aggregate**: `bookstore` + store_id
- **Payload**: `{ events_count: N, store_name: "..." }`
- **Emitted by**: `Stacks.Workers.DiscoverBookstoreEventsJob`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: On `enrichment.events_discovered`, enqueues `DbtRefreshJob` for `["int_event_matches"]`
- **Downstream effects**: Event matching models refreshed

---

## 7. Background Jobs (Oban)

### DiscoverBookstoreEventsJob
- **Worker**: `Stacks.Workers.DiscoverBookstoreEventsJob`
- **Queue**: `:default`
- **Args**: `%{"store_id" => uuid}` (single) or `%{"batch" => true}` (batch)
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Single mode: fetches the specific store; batch mode: filters `Prices.all_stores()` to those with `website_url`
  2. For each store: builds events URL by appending `/events` to the store's `website_url`
  3. Fetches the page via `Finch` (GET, text/html, 15s timeout)
  4. Parses events using regex: `<h2>` / `<h3>` tags for titles, ISO date pattern for dates
  5. Matches event titles against known author names (case-insensitive substring match)
  6. Upserts each event via `Events.upsert_event/1`
  7. Records source health via `Monitoring.record_success/2` or `Monitoring.record_failure/3`
  8. Emits `enrichment.events_discovered` event if any events were successfully persisted
- **On success**: Events persisted, monitoring updated, dbt refresh triggered
- **On failure**: Failure logged and recorded in monitoring; other stores still processed in batch

---

## 8. External Service Calls

### Bookstore websites (HTML scraping)
- **Service**: Individual bookstore websites
- **Endpoint**: `{website_url}/events` (constructed by `build_events_url/1`)
- **Client module**: Direct `Finch` HTTP call (no dedicated client module)
- **Auth**: None
- **Circuit breaker**: None (failure isolated per store via monitoring)
- **Fallback**: Event discovery skipped for that store
- **Mock in test**: No dedicated mock — test at the job level

---

## 9. Storage (R2 / Local)

N/A — event data stored in the database.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

### `int_event_matches`
- **Model**: `int_event_matches`
- **Trigger**: `enrichment.events_discovered` via `DbtRefreshHandler`
- **Materialisation**: Intermediate model
- **Consumer**: Third Spaces page, author card event count

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: N/A — event data surfaced within book detail overlay and Third Spaces page
- **URL**: N/A
- **Public or authenticated**: Context-dependent

### Init
N/A — data passed as enrichment props to `Components.AuthorCard`.

### Update cycle
N/A — pure view rendering of event counts.

### View
- **Key elements**:
  - Events count > 0: "N upcoming event(s) at bookstores near you" (in `Components.AuthorCard`)
  - Events count = 0: "No upcoming events"
  - No enrichment: "Events coming soon"
- **ARIA attributes**: Inherits from `Components.AuthorCard` region
- **CSS classes**: `book-detail__author-events`, `stub-notice`

---

## 13. Operational Metrics

- **Oban job counts for `DiscoverBookstoreEventsJob`**: enqueued, completed, failed, retried — tracked via `mart_job_stats` and Oban telemetry
- **External HTTP call counts and latencies**: per-store `Finch` GET requests to `{website_url}/events` — 15s timeout, success/failure rates recorded via `Monitoring.record_success/2` and `Monitoring.record_failure/3`
- **Event upsert counts**: number of `BookstoreEvent` records upserted per batch run
- **Author matching rate**: percentage of scraped events that match a known author via case-insensitive substring match
- **Event handler execution times**: `DbtRefreshHandler` processing time for `enrichment.events_discovered` events
- **dbt refresh job duration**: time to rebuild `int_event_matches` model
- **Source health per store**: individual store scrape status visible in `op.source_health_checks` — degraded/broken stores indicate website layout changes or downtime

---

## 14. Performance & Usability Metrics

- **Enrichment data freshness**: time since last event scrape per store — derived from `bookstore_events.scraped_at` vs `NOW()`
- **Event discovery yield**: events found per store per sweep — derivable from `enrichment.events_discovered` event payloads (`events_count`)
- **Author match precision**: ratio of correctly matched events to total matched events — false positives possible with substring matching (e.g., common author names)
- **Event relevance**: percentage of discovered events that are upcoming (not past `event_date`) at time of user view
- **Parse success rate**: percentage of store pages where regex parsing (`<h2>`/`<h3>` tags + ISO date pattern) successfully extracts at least one event

---

## 15. Cost Tracking

- **Fly.io compute**: core app machine time for `DiscoverBookstoreEventsJob` Oban worker. Direct `Finch` HTTP calls to bookstore websites — no dedicated microservice. Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: queries for `Prices.all_stores/0` (filtered to stores with `website_url`), `Events.upsert_event/1` writes, author lookups for matching, and dbt model rebuilds. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Network egress**: outbound HTTP GET to each bookstore's `/events` page. Typically small HTML pages. Fly.io free tier: 100GB/month; $0.02/GB after.
- **No external API costs**: event scraping uses direct HTTP, not paid search APIs. Cost is purely compute + network.
