# US-2.5.3 — Business Opt-Out from Platform Listings

## 1. User Story

> **As a** business owner whose venue or shop has been discovered and listed on a Stacks instance, **I want to** request removal of my listing **so that** I have control over whether my business appears on the platform.

Every discovered (non-partner) listing includes a discreet "Is this your business?" link. Clicking opens a simple form: business name, contact email, and a choice between "Remove my listing" and "I'd like to become a partner instead." For removal requests: the listing is taken down and the URL is added to an exclusion list so future discovery sweeps do not re-add it. The form does not require account creation. A confirmation email is sent.

The platform owner sees removal requests in the Metrics Dashboard alongside partner requests.

---

## 2. UI Interaction Flow

### Happy Path
1. Business owner sees their business listed on the Third Spaces page or in "Where to Buy" sections.
2. They click the "Is this your business?" link at the bottom of the card.
3. A form opens (no authentication required) with fields: URL (pre-filled), email, and reason (remove/partner).
4. For removal: submits to `POST /api/opt-out` with URL and email.
5. System marks the source as `excluded`, sets `excluded_at` and `exclusion_email`.
6. Business owner receives confirmation.
7. The listing disappears from reader-facing pages.

### Sad Paths
- **URL not found**: API returns 404 — "No discovered source matches the provided URL."
- **Invalid email**: API returns 422 — "The provided email address is not valid."
- **Missing fields**: API returns 422 — "url and email are required."
- **Changeset error**: API returns 422 — "Unable to process opt-out request."

### Elm State Machine
- **Page module**: N/A — the opt-out form is a simple HTML form or minimal Elm component, not a full page module in the current codebase.
- **Msg flow**: Form submit -> POST to API -> success/error display
- **RemoteData states**: N/A

---

## 3. API Calls

### `POST /api/opt-out`
- **Auth**: None (public, unauthenticated)
- **Pipeline**: `:api` -> `:rate_limit_public`
- **Controller**: `StacksWeb.OptOutController.create/2`
- **Request body**: `{ "url": "https://example.com", "email": "owner@example.com" }`
- **Response (success)**: `{ "message": "Source has been opted out successfully." }` — HTTP 200
- **Response (error)**:
  - `{ "error": "No discovered source matches the provided URL." }` — HTTP 404
  - `{ "error": "The provided email address is not valid." }` — HTTP 422
  - `{ "error": "url and email are required" }` — HTTP 422
  - `{ "error": "Unable to process opt-out request." }` — HTTP 422
- **FallbackController handling**: Not used — controller handles errors directly

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `RateLimiter(bucket: :public)`
- **Visibility checks**: N/A — public endpoint
- **Age gate**: N/A
- **Ownership checks**: None — business ownership verified via email (out-of-band confirmation)

---

## 5. Database Interactions

### Read: Find source by URL
- **Table(s)**: `op.discovered_sources`
- **Query**: `Discovery.get_source_by_url(url)` — `WHERE url = ?`
- **Indexes used**: Unique constraint on `url`
- **Schema module**: `Stacks.Enrichment.DiscoveredSource`

### Write: Opt out source
- **Table(s)**: `op.discovered_sources`
- **Operation**: UPDATE
- **Changeset validations**: `status_changeset` — sets `status: :excluded`, `excluded_at: now`, `exclusion_email: email`
- **Transaction**: No — single update
- **Denormalization**: None
- **Post-exclusion**: Future `SourceDiscoveryJob` runs check for existing URLs via `Discovery.get_source_by_url/1` before creating new records, so excluded URLs are not re-added.

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — the opt-out flow does not currently emit a domain event. The status change is recorded directly on the `DiscoveredSource` record.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A — opt-out is a synchronous API call, not a background job. The exclusion is immediate.

---

## 8. External Service Calls

N/A — no external services called during the opt-out flow.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A — opt-out does not trigger dbt refreshes. The excluded source is filtered out of downstream queries by its `status: :excluded`.

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A — the opt-out form is not a routed Elm page in the current codebase. It is invoked from a link on source cards.

### Init
N/A

### Update cycle
N/A

### View
N/A — the opt-out interaction is minimal: a link leading to a form that POSTs to `/api/opt-out`.

---

## 13. Operational Metrics

- **Opt-out request counts**: total `POST /api/opt-out` calls — successful (200) vs failed (404, 422) breakdown
- **Rate limiter activity**: `:rate_limit_public` bucket hits for opt-out endpoint — monitors for abuse or automated bulk opt-out attempts
- **Source exclusion counts**: number of `DiscoveredSource` records transitioned to `status: :excluded` over time
- **Duplicate exclusion attempts**: requests where the URL is already excluded — indicates re-discovery prevention is working or that the "Is this your business?" link remains visible after exclusion

---

## 14. Performance & Usability Metrics

- **Opt-out response latency**: `POST /api/opt-out` end-to-end response time — should be <200ms (single DB read + update, no external calls)
- **Opt-out completion rate**: percentage of business owners who land on the form and successfully submit vs abandon
- **Re-discovery prevention effectiveness**: after exclusion, verify that `SourceDiscoveryJob` correctly skips excluded URLs via `Discovery.get_source_by_url/1` — zero re-additions expected
- **Partner conversion rate**: ratio of "I'd like to become a partner instead" selections vs "Remove my listing" — measures partner acquisition potential from discovered sources

---

## 15. Cost Tracking

- **Fly.io compute**: negligible — opt-out is a synchronous API call with minimal compute (one DB read + one DB write). No background jobs, no external service calls.
- **Neon compute**: two database operations per opt-out (read by URL + update status). Effectively zero marginal cost. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **No external API costs**: opt-out flow is entirely internal. No Brave, SearXNG, Together AI, or scraper calls.
- **Indirect cost savings**: each exclusion removes a URL from future discovery duplicate checks, marginally reducing `SourceDiscoveryJob` processing time.
