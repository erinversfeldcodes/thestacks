# US-X.X.X — [Title]

## 1. User Story

> **As a** [role], **I want to** [action] **so that** [outcome].

[Paste the full user story text from docs/user-stories.md, including acceptance criteria and any notes.]

---

## 2. UI Interaction Flow

### Happy Path
Step-by-step description of what the user sees and does:
1. User navigates to [page/route]
2. User sees [UI element]
3. User interacts with [button/form/etc.]
4. System responds with [feedback]
5. ...

### Sad Paths
For each error scenario:
- **[Error name]**: User does [action] → system shows [error state] → user can [recovery action]
- **[Error name]**: ...

### Elm State Machine
- **Page module**: `Page.X` or `Components.X`
- **Model fields involved**: `field1`, `field2`, ...
- **Msg flow**: `UserAction → ApiCall → GotResponse → UpdateModel`
- **RemoteData states**: NotAsked → Loading → Success/Failure
- **OutMsg pattern** (if applicable): what messages propagate to Main

---

## 3. API Calls

For each HTTP request in the flow:

### `METHOD /api/endpoint`
- **Auth**: Required / Optional / None
- **Pipeline**: `:api`, `:authenticated`, `:optional_auth`, `:require_owner`
- **Controller**: `StacksWeb.XController.action/2`
- **Request body**: `{ field: type, ... }`
- **Response (success)**: `{ field: type, ... }` — HTTP 200/201/202
- **Response (error)**: `{ error: "message" }` — HTTP 4xx
- **FallbackController handling**: which error tuples map to which HTTP status

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` → `AuthPipeline` → `RequireConfirmedEmail` → `RequireRole` → `RateLimiter` → `ViewAsPlug` → ...
- **Visibility checks**: `Visibility.resolve_visibility/2` — who can see what
- **Age gate**: `AgeGate.enforce/2` — is the content age-gated?
- **Ownership checks**: how ownership is verified (e.g., `verify_ownership/2`, `check_ownership/2`)

---

## 5. Database Interactions

For each query/mutation:

### Read: [description]
- **Table(s)**: `op.table_name`
- **Query**: description of the Ecto query (joins, filters, ordering)
- **Indexes used**: which indexes serve this query
- **Schema module**: `Stacks.X.Y`

### Write: [description]
- **Table(s)**: `op.table_name`
- **Operation**: INSERT / UPDATE / DELETE
- **Changeset validations**: required fields, constraints, unique indexes
- **Transaction**: is this wrapped in `Ecto.Multi`? What steps?
- **Denormalization**: any fields updated on related tables (e.g., `placement.listing_status`)

---

## 6. Event Flow & Lifecycle

### Events Emitted
For each event:
- **Event type**: `domain.action` (e.g., `book.created`)
- **Aggregate**: type + ID
- **Payload**: `{ field: value, ... }`
- **Emitted by**: which context function
- **Emission method**: `Events.emit/1` or `Events.emit_safe/1`

### Event Handlers Triggered
For each handler that fires:
- **Handler**: `Stacks.X.Handlers.YHandler`
- **Action**: what the handler does (enqueue job, invalidate cache, etc.)
- **Downstream effects**: what jobs/refreshes/cache invalidations result

---

## 7. Background Jobs (Oban)

For each job enqueued or triggered:
- **Worker**: `Stacks.Workers.XJob`
- **Queue**: `:default` / `:vision` / `:events` / `:dbt_refresh` / ...
- **Args**: `%{ key: value, ... }`
- **Max attempts**: N
- **Uniqueness**: period, keys
- **What it does**: step-by-step description
- **On success**: what state changes, events emitted
- **On failure**: retry behaviour, circuit breakers, error logging

---

## 8. External Service Calls

For each external service interaction:
- **Service**: Vision sidecar / Rust scraper / Open Library / Google Books / Together AI / Brave Search / SearXNG / Resend / R2
- **Endpoint**: `POST /classify`, `GET https://openlibrary.org/...`, etc.
- **Client module**: `Stacks.AI.Client`, `Stacks.Enrichment.ScraperClient`, etc.
- **Auth**: HMAC, API key, Bearer token
- **Circuit breaker**: fuse name, thresholds
- **Fallback**: what happens when the service is unavailable
- **Mock in test**: which mock module is used

---

## 9. Storage (R2 / Local)

For each storage interaction:
- **Operation**: upload / presigned URL / delete
- **Key pattern**: `uploads/{image_id}`, `covers/{isbn}-cover.jpg`
- **Module**: `Stacks.Storage`
- **Backend**: `Storage.R2` (prod) / `Storage.Local` (dev) / `Storage.Mock` (test)
- **TTL**: presigned URL expiry (default 900s)

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache` / `RateLimiter` / `BudgetTracker`
- **Operation**: get / put / invalidate
- **Key**: what key is used
- **TTL**: expiry time
- **Invalidation trigger**: which events invalidate this cache entry

---

## 11. dbt Model Dependencies

For each dbt model affected by this story:
- **Model**: `mart_x` / `int_x` / `stg_x`
- **Trigger**: which event triggers refresh via `DbtRefreshHandler`
- **Materialisation**: view / incremental / table
- **Consumer**: which API endpoint or dashboard section reads this model

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.X`
- **URL**: `/path`
- **Public or authenticated**: which pipeline

### Init
- **`initPage` branch**: what happens when the route loads
- **API calls on init**: which endpoints are fetched
- **Initial model state**: key fields and their initial values

### Update cycle
For each user interaction:
- **Msg**: `UserClickedX`
- **Model change**: which fields update
- **Cmd**: API call, port, Dom focus, navigation
- **OutMsg** (if applicable): what Main.elm does with it

### View
- **Key elements**: what renders in each state (Loading, Success, Failure)
- **ARIA attributes**: role, aria-label, aria-live
- **CSS classes**: main structural classes (for E2E test reference)
