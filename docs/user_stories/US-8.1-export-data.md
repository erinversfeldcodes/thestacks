# US-8.1 — Export Personal Data

## 1. User Story

> **As a** user, **I want to** export all my personal data **so that** I can exercise my right to access and portability under GDPR.

The user navigates to Settings and clicks "Export My Data." The system compiles all personal data: shelf contents, reading history, linked writing, preferences, audit logs. The export is available as JSON and CSV. Potentially also OPDS format for book data portability. A download link is provided.

**What they see on the page:**
- A settings section titled "Your Data" with a warm, reassuring tone.
- "Export My Data" button. On click: "Preparing your export..." with a progress indicator.
- When ready: download links for JSON, CSV, and (if supported) OPDS formats.
- A description of what's included in each format.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to Settings > Your Data.
2. User clicks "Export My Data" button.
3. System responds with HTTP 202 and message "Data export has been queued."
4. Oban `DataExportJob` runs asynchronously, collecting all user data.
5. When complete, the export file is available for download (stub: currently logged only).

### Sad Paths
- **Not authenticated**: User is redirected to login. The `:authenticated` pipeline rejects unauthenticated requests with 401.
- **Export job failure**: `DataExportJob` retries up to 3 times. On final failure, error is logged. The user would need to re-request.

### Elm State Machine
- **Page module**: No dedicated Elm page yet; the export is triggered from Settings via an API call.
- **Model fields involved**: N/A (fire-and-forget HTTP POST).
- **Msg flow**: `UserClicksExport -> PostExportRequest -> GotExportResponse (202 accepted)`.
- **RemoteData states**: NotAsked -> Loading -> Success (accepted).

---

## 3. API Calls

### `POST /api/gdpr/export`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api`, `:authenticated`
- **Controller**: `StacksWeb.GDPRController.export/2`
- **Request body**: None
- **Response (success)**: `{ status: "accepted", message: "Data export has been queued." }` -- HTTP 202
- **Response (error)**: 401 if unauthenticated
- **FallbackController handling**: Standard auth pipeline rejects before reaching controller

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` (`:authenticated` scope) -> controller action
- **Visibility checks**: N/A -- user can only export their own data
- **Age gate**: N/A
- **Ownership checks**: Implicit -- `Guardian.Plug.current_resource(conn)` provides the authenticated user; the export runs only for that user's ID.

---

## 5. Database Interactions

### Read: Collect user profile
- **Table(s)**: `op.users`
- **Query**: `Accounts.get_user!(user_id)` -- fetches by primary key
- **Schema module**: `Stacks.Accounts.User`

### Read: Collect bookshelves
- **Table(s)**: `op.bookshelves`
- **Query**: `from bs in Bookshelf, where: bs.user_id == ^user_id`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Read: Collect placements with books and editions
- **Table(s)**: `op.bookshelf_placements`, `op.books`, `op.book_editions`
- **Query**: `from p in Placement, where: p.bookshelf_id in ^bookshelf_ids, preload: [book: :editions]`
- **Schema module**: `Stacks.Shelving.Placement`

### Read: Collect placement history
- **Table(s)**: `op.bookshelf_placement_history`
- **Query**: `from h in PlacementHistory, where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids`
- **Schema module**: `Stacks.Shelving.PlacementHistory`

### Read: Collect writing assistant sessions
- **Table(s)**: `op.blog_assistant_sessions`
- **Query**: `from s in BlogAssistantSession, where: s.user_id == ^user_id`

### Read: Collect writing assistant feedback
- **Table(s)**: `op.turn_feedback`
- **Query**: Join through `blog_assistant_sessions` on `user_id`

### Read: Collect embeddings summary
- **Table(s)**: `op.embeddings`
- **Query**: `from e in Embedding, where: e.user_id == ^user_id, select: [:source_type, :source_id, :metadata, :inserted_at]`
- **Note**: `embedding` (vector) field excluded — not human-readable and not required for portability

### Write: None
The export is read-only.

---

## 6. Event Flow & Lifecycle

### Events Emitted
No events are emitted by the export process itself. The export request is logged via Oban job insertion.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.DataExportJob`
- **Worker**: `Stacks.Workers.DataExportJob`
- **Queue**: `:default`
- **Args**: `%{ "user_id" => user_id }`
- **Max attempts**: 3
- **Uniqueness**: None configured
- **What it does**:
  1. Calls `Stacks.GDPR.Export.export_user_data(user_id)`.
  2. The export function collects: user profile (id, email, display_name, role, profile_visibility, age_verified, consent_analytics, consent_analytics_at, created_at), all bookshelves (id, name, visibility, created_at), all placements (id, book_isbn via `Books.primary_edition/1`, book_title, bookshelf_id, position, placed_at, removed_at, formats, personal_rating, notes), and all placement history (id, book_id, from_bookshelf, to_bookshelf, moved_at).
  3. Returns a JSON-serialisable map keyed by `exported_at`, `user`, `bookshelves`, `placements`, `placement_history`, `writing_assistant_sessions`, `writing_assistant_feedback`, `embeddings_summary`.
     - `writing_assistant_sessions`: all `op.blog_assistant_sessions` for the user — full chat turn history per post
     - `writing_assistant_feedback`: all `op.turn_feedback` records for the user
     - `embeddings_summary`: a human-readable list of what has been embedded (source type, source title, shelf name, date embedded) — the raw vectors are not included as they are not human-readable
  4. Stub: currently logs the export size. In production, would write to object storage and notify the user.
- **On success**: Logs "export generated for user {id}, keys={count}". Returns `:ok`.
- **On failure**: Logs error. Returns `{:error, reason}` for Oban retry.

---

## 8. External Service Calls

N/A -- The export reads from the local database only.

---

## 9. Storage (R2 / Local)

- **Operation**: Stub -- in production, the export JSON would be uploaded to R2/Local storage for user download.
- **Key pattern**: Not yet implemented.
- **Module**: Would use `Stacks.Storage`.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A -- The export reads from operational tables, not dbt models.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: Settings route (no dedicated export route)
- **URL**: `/settings`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Settings page loads with "Export My Data" as one section.
- **API calls on init**: None for export specifically.
- **Initial model state**: Button idle, no export in progress.

### Update cycle
- **Msg**: `UserClicksExport`
- **Model change**: Sets loading state on export button.
- **Cmd**: `POST /api/gdpr/export`
- **OutMsg**: None

### View
- **Key elements**: Export button shows "Export My Data" (idle), "Preparing your export..." (loading), "Export queued" (success).
- **ARIA attributes**: N/A (not yet implemented).
- **CSS classes**: Standard settings page classes.

---

## 13. Operational Metrics

- **GDPR export request count**: Total `DataExportJob` enqueue events, segmented by success/failure. Tracks how often users exercise their right to data portability.
- **Export job outcome rate**: Success vs. failure vs. retry counts for `DataExportJob`. Alerts if failure rate exceeds threshold.
- **Audit log write throughput**: Indirect -- export requests generate Oban job insertions which are observable via Oban telemetry. No direct audit entry is written for exports currently.

---

## 14. Performance & Usability Metrics

- **GDPR export generation time**: Wall-clock duration of `Stacks.GDPR.Export.export_user_data/1` inside `DataExportJob`. Measured from job start to `:ok` return. Expected to scale with bookshelf/placement count.
- **Export payload size**: Byte size of the generated JSON map (keys: user, bookshelves, placements, placement_history). Useful for capacity planning when R2 upload is implemented.
- **Time-to-download**: Once R2 delivery is implemented, latency from user click to download link availability.

---

## 15. Cost Tracking

- **Neon**: Compute cost for the read-heavy queries (user profile, bookshelves, placements with preloads, placement history). Single-user scope keeps per-request cost low.
- **R2 storage** (future): Upload cost for the export file once object storage delivery is implemented. One-time write per export request.
- **Resend** (future): Email cost for notifying the user that the export is ready for download.
- Most of the current export pipeline is DB-read-only with no external service calls -- minimal incremental cost per request.
