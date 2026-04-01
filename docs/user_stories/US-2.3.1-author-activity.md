# US-2.3.1 — View Author Information and Latest Activity

## 1. User Story

> **As a** user, **I want to** see author details including their website, RSS feed, and upcoming events **so that** I can stay connected to authors I care about.

Author information is auto-discovered during book addition. When a book's ISBN is resolved via Open Library or Google Books, the system extracts the author's name, website URL (if available), and searches for their RSS feed and social presence using the Source Discovery Agent (Brave Search / SearXNG). The system stores a confidence score for each piece of discovered data. Users can submit corrections via a "Report an issue" link.

The user sees: author name, website link, latest RSS post (title, date, excerpt, "Read more" link), upcoming events at bookstores, and a subtle "Auto-discovered" label. A "Report an issue" link allows flagging incorrect data.

---

## 2. UI Interaction Flow

### Happy Path
1. User opens a book detail overlay.
2. The "The Author" section renders with author data from the book record.
3. Author name displays in serif typeface with an avatar initial.
4. If the author has a website_url, a "Website" link renders opening in a new tab.
5. If enrichment data provides a latest RSS post, a card shows: post title, date, excerpt, and "Read more" link.
6. If upcoming events count > 0, a notice shows "N upcoming event(s) at bookstores near you."

### Sad Paths
- **No author data**: Shows "Author information unavailable."
- **No enrichment data**: RSS section shows "RSS feed coming soon"; events section shows "Events coming soon."
- **No recent posts**: When enrichment exists but no latest post, shows "No recent posts."
- **No upcoming events**: Shows "No upcoming events."

### Elm State Machine
- **Component module**: `Components.AuthorCard`
- **Model fields involved**: `Maybe Author` (from `Types.Book`), `Maybe AuthorEnrichment` (prop)
- **Msg flow**: No messages — pure view component
- **RemoteData states**: N/A — uses Maybe types
- **OutMsg pattern**: N/A

---

## 3. API Calls

Author data is returned as part of the book detail endpoint. Enrichment data (RSS posts, events) is populated by background workers.

### `GET /api/books/:id`
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Response (success)**: Book JSON with nested author data — HTTP 200

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Visibility checks**: Inherits from book detail visibility
- **Age gate**: `AgeGate.enforce/2` if applicable
- **Ownership checks**: N/A

---

## 5. Database Interactions

### Read: Author record
- **Table(s)**: `op.authors`
- **Query**: Loaded via book preload — `book.author`
- **Schema module**: `Stacks.Books.Author`
- **Key fields**: `name`, `bio`, `website_url` (Maybe), `rss_feed_url` (Maybe)

### Read: Authors without sources (for discovery)
- **Table(s)**: `op.authors`
- **Query**: `Authors.authors_without_sources()` — `WHERE website_url IS NULL OR rss_feed_url IS NULL`
- **Schema module**: `Stacks.Books.Author`

### Read: Authors with RSS feeds (for polling)
- **Table(s)**: `op.authors`
- **Query**: `Authors.authors_with_rss()` — `WHERE rss_feed_url IS NOT NULL`
- **Schema module**: `Stacks.Books.Author`

### Write: Update author sources
- **Table(s)**: `op.authors`
- **Operation**: UPDATE
- **Changeset validations**: Standard author changeset
- **Transaction**: No — single update
- **Denormalization**: None

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `enrichment.author_updated`
- **Aggregate**: `author` + author_id
- **Payload**: `{ author_id, new_entries: [{ title, url, published, summary }] }`
- **Emitted by**: `Stacks.Workers.FetchAuthorRSSJob`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered

#### AuthorDiscoveryHandler (trigger chain)
- **Handler**: `Stacks.Enrichment.Handlers.AuthorDiscoveryHandler`
- **Listens for**: `book.created`
- **Action**: Looks up author_id for the book; if author lacks website_url or rss_feed_url, enqueues `DiscoverAuthorSourcesJob`

#### DbtRefreshHandler
- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: On `enrichment.author_updated`, enqueues `DbtRefreshJob` for `["int_author_activity"]`

---

## 7. Background Jobs (Oban)

### FetchAuthorRSSJob
- **Worker**: `Stacks.Workers.FetchAuthorRSSJob`
- **Queue**: `:default`
- **Args**: `%{}` (no args — processes all authors with RSS feeds)
- **Max attempts**: 3
- **Uniqueness**: None configured (daily cron)
- **What it does**:
  1. Calls `Authors.authors_with_rss()` to get all authors with `rss_feed_url`
  2. For each author: calls `rss_fetcher().fetch_and_parse(author.rss_feed_url)`
  3. Extracts entries from the feed, filters to entries published within the last 24 hours
  4. Parses dates via ISO 8601 or RFC 2822/1123 (Timex-based fallback)
  5. If recent entries found, emits `enrichment.author_updated` event
  6. Records source health via `Monitoring.record_success/2` or `Monitoring.record_failure/3`
- **On success**: Event emitted with new RSS entries, source health marked healthy
- **On failure**: Individual author failures logged; other authors still processed

### DiscoverAuthorSourcesJob (upstream trigger)
- **Worker**: `Stacks.Workers.DiscoverAuthorSourcesJob` (referenced by `AuthorDiscoveryHandler`)
- **Queue**: `:default`
- **Args**: `%{"author_id" => uuid}`
- **What it does**: Discovers website and RSS feed URLs for an author via web search, updates author record via `Authors.update_author_sources/2`

---

## 8. External Service Calls

### RSS feed fetch
- **Service**: External RSS/Atom feeds (author websites)
- **Endpoint**: Author's `rss_feed_url`
- **Client module**: `Stacks.Enrichment.RssFetcher` (real) — configurable via `Application.get_env(:core, :rss_fetcher)`
- **Auth**: None
- **Circuit breaker**: None (per-author failure isolation via monitoring)
- **Fallback**: Author skipped; logged as warning
- **Mock in test**: `Stacks.Enrichment.MockRssFetcher`

### Brave Search / SearXNG (author discovery)
- **Service**: Brave Search API (primary), SearXNG (fallback)
- **Client module**: `Stacks.Discovery.BraveClient`, `Stacks.Discovery.SearxngClient`
- **Auth**: Brave: `X-Subscription-Token` API key; SearXNG: none (self-hosted)
- **Circuit breaker**: Brave daily budget (67 queries/day)
- **Fallback**: Falls back from Brave to SearXNG when budget exhausted

---

## 9. Storage (R2 / Local)

N/A — author data stored in database.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

### `int_author_activity`
- **Model**: `int_author_activity`
- **Trigger**: `enrichment.author_updated` via `DbtRefreshHandler`
- **Materialisation**: Intermediate model
- **Consumer**: Author activity analytics

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: N/A — component within the book detail overlay
- **URL**: N/A
- **Public or authenticated**: Inherits from book detail overlay context

### Init
- **`initPage` branch**: N/A — receives data as props
- **API calls on init**: None
- **Initial model state**: Props from parent

### Update cycle
N/A — `Components.AuthorCard` is a pure view function.

### View
- **Key elements**:
  - No author: "Author information unavailable"
  - Author present: Avatar initial, name (serif), optional bio, optional website link
  - Enrichment present + latest post: RSS card with title, date, excerpt, "Read more" link
  - Enrichment present + no post: "No recent posts"
  - No enrichment: "RSS feed coming soon" and "Events coming soon" stubs
  - Events count > 0: "N upcoming event(s) at bookstores near you"
- **ARIA attributes**: `role="region"`, `aria-labelledby="section-author"` on the section
- **CSS classes**: `book-detail__section`, `book-detail__author-card`, `book-detail__author-info`, `book-detail__author-rss`, `book-detail__author-events`

---

## 13. Operational Metrics

- **Oban job counts for `FetchAuthorRSSJob`**: enqueued, completed, failed, retried — daily cron, tracked via `mart_job_stats` and Oban telemetry
- **Oban job counts for `DiscoverAuthorSourcesJob`**: enqueued per `book.created` event via `AuthorDiscoveryHandler`
- **Brave Search API call counts**: per-query counts and latencies for author source discovery — tracked via `BraveClient` daily budget counter (`:persistent_term` + `:counters`)
- **SearXNG call counts**: fallback queries when Brave budget exhausted — self-hosted, no rate limit
- **RSS fetch success/failure rates**: per-author RSS feed fetch outcomes recorded in `op.source_health_checks`
- **Circuit breaker state**: Brave daily budget (67 queries/day) acts as a soft circuit breaker — `{:error, :daily_budget_exhausted}` triggers SearXNG fallback
- **Event handler execution times**: `AuthorDiscoveryHandler` and `DbtRefreshHandler` processing latency for `book.created` and `enrichment.author_updated` events
- **dbt refresh job duration**: time to rebuild `int_author_activity` model

---

## 14. Performance & Usability Metrics

- **Enrichment data freshness**: time since last RSS poll per author — `FetchAuthorRSSJob` runs daily, filtering entries published within the last 24 hours
- **Source discovery yield**: percentage of authors where `DiscoverAuthorSourcesJob` successfully discovers a `website_url` or `rss_feed_url` — derivable from `Authors.authors_without_sources()` count over time
- **RSS feed parse success rate**: percentage of author feeds that parse successfully (valid RSS/Atom XML) vs those that fail (malformed feeds, 404s, timeouts)
- **Author enrichment coverage**: percentage of authors with at least one of `website_url` or `rss_feed_url` populated
- **Date parsing robustness**: success rate of ISO 8601 vs RFC 2822/1123 fallback parsing in `FetchAuthorRSSJob`

---

## 15. Cost Tracking

- **Brave Search API**: 2000 free queries/month (67/day budget). Beyond free tier: $3 per 1000 queries (Basic plan) or $5 per 1000 queries (Pro). Author discovery typically uses 1 query per author needing sources.
- **SearXNG**: self-hosted, no per-query cost. Compute cost is the SearXNG container/instance running on the self-hoster's infrastructure.
- **Together AI** (if used for source scoring via `ScoreSourceJob`): ~$0.20 per 1M input tokens. Source scoring prompts are small (~200 tokens input, ~10 tokens output). Cost per score: <$0.0001.
- **Fly.io compute**: core app machine time for `FetchAuthorRSSJob` (daily cron) and `DiscoverAuthorSourcesJob` (event-triggered). Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: queries for `Authors.authors_with_rss/0`, `Authors.authors_without_sources/0`, author updates, and dbt refreshes. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **Network egress**: outbound HTTP for RSS feed fetches and Brave/SearXNG queries. Fly.io free tier: 100GB/month; $0.02/GB after.
