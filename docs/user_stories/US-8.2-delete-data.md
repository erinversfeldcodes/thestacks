# US-8.2 — Delete All Personal Data

## 1. User Story

> **As a** user, **I want to** delete all my personal data **so that** I can exercise my right to erasure under GDPR.

The user navigates to Settings and clicks "Delete My Data." A confirmation dialog explains exactly what will be deleted and what will be anonymised. The user confirms with a typed confirmation (e.g., typing "DELETE" to proceed). The system performs a cascade delete: all personal data, shelves, reading history, linked writing, and preferences are removed. Analytics data is anonymised in the warehouse.

**What they see on the page:**
- A serious but respectful dialog: "This will permanently delete all your data from The Stacks. Analytics data will be anonymised. This cannot be undone."
- A text input requiring the user to type "DELETE" to confirm.
- After deletion: a farewell page confirming the action is complete, with no remaining session or data.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to Settings > Your Data.
2. User clicks "Delete My Data."
3. Confirmation dialog appears explaining consequences.
4. User types "DELETE" to confirm.
5. System logs an audit entry for the deletion request.
6. System responds with HTTP 202: "Account deletion has been queued."
7. `AccountDeletionJob` runs asynchronously, cascade-deleting all data.
8. Session is invalidated; user sees a farewell page.

### Sad Paths
- **Not authenticated**: Rejected by `:authenticated` pipeline with 401.
- **Deletion job fails at a step**: `AccountDeletionJob` has `max_attempts: 1` -- no retries. The error is logged with the failed step name. Manual intervention required.
- **User not found during deletion**: The `Ecto.Multi` transaction returns `{:error, :user_not_found}` and all changes are rolled back.

### Elm State Machine
- **Page module**: Settings page with deletion section.
- **Model fields involved**: Confirmation text field, deletion request state.
- **Msg flow**: `UserTypesConfirmation -> UserClicksDelete -> PostDeleteRequest -> GotDeleteResponse (202)`.
- **RemoteData states**: NotAsked -> Loading -> Success (accepted).

---

## 3. API Calls

### `DELETE /api/gdpr/account`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api`, `:authenticated`
- **Controller**: `StacksWeb.GDPRController.delete_account/2`
- **Request body**: None
- **Response (success)**: `{ status: "accepted", message: "Account deletion has been queued." }` -- HTTP 202
- **Response (error)**: 401 if unauthenticated
- **FallbackController handling**: Standard auth pipeline

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` (`:authenticated` scope) -> controller action
- **Visibility checks**: N/A
- **Age gate**: N/A
- **Ownership checks**: Implicit via `Guardian.Plug.current_resource(conn)` -- the user can only delete their own account.

---

## 5. Database Interactions

The deletion runs inside a single `Ecto.Multi` transaction in `Stacks.GDPR.Deletion.delete_user_data/1`:

### Read: Fetch user's bookshelves
- **Table(s)**: `op.bookshelves`
- **Query**: `from bs in Bookshelf, where: bs.user_id == ^user_id`
- **Schema module**: `Stacks.Shelving.Bookshelf`

### Write: Delete placement history
- **Table(s)**: `op.bookshelf_placement_history`
- **Operation**: DELETE
- **Query**: `from h in PlacementHistory, where: h.from_bookshelf in ^bookshelf_ids or h.to_bookshelf in ^bookshelf_ids`
- **Transaction**: Step `:delete_history` in `Ecto.Multi`

### Write: Delete placements
- **Table(s)**: `op.bookshelf_placements`
- **Operation**: DELETE
- **Query**: `from p in Placement, where: p.bookshelf_id in ^bookshelf_ids`
- **Transaction**: Step `:delete_placements` in `Ecto.Multi`

### Write: Delete bookshelves
- **Table(s)**: `op.bookshelves`
- **Operation**: DELETE
- **Query**: `from bs in Bookshelf, where: bs.user_id == ^user_id`
- **Transaction**: Step `:delete_bookshelves` in `Ecto.Multi`

### Write: Delete user
- **Table(s)**: `op.users`
- **Operation**: DELETE
- **Query**: `repo.get(User, user_id)` then `repo.delete(user)`
- **Transaction**: Step `:delete_user` in `Ecto.Multi`

### Write: Audit log entry
- **Table(s)**: `audit.audit_log`
- **Operation**: INSERT
- **Transaction**: Step `:audit` in `Ecto.Multi`
- **Entry**: `Audit.log(nil, "user.data_deleted", resource_type: "user", resource_id: user_id)` -- note `nil` user_id in audit since user is being deleted

**Important**: The `event_log` is NOT modified. As documented in the module: "Event payloads contain no real-world PII (name, email, etc.) -- only opaque UUIDs and system metadata -- so there is nothing to scrub."

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Pre-deletion audit event**: The controller calls `Audit.log(user.id, "user.deletion_requested", ...)` before enqueuing the job. This is NOT an `Events.emit` call -- it writes directly to the audit log.
- **Post-deletion audit event**: Inside the Multi transaction, `Audit.log(nil, "user.data_deleted", ...)` records the completed deletion.

### Event Handlers Triggered
N/A -- no event handlers are registered for deletion events.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.AccountDeletionJob`
- **Worker**: `Stacks.Workers.AccountDeletionJob`
- **Queue**: `:default`
- **Args**: `%{ "user_id" => user_id }`
- **Max attempts**: 1 (no retries -- deletion is destructive and non-idempotent)
- **Uniqueness**: None configured
- **What it does**:
  1. Calls `Stacks.GDPR.Deletion.delete_user_data(user_id)`.
  2. Inside a single `Ecto.Multi` transaction:
     a. Fetches all bookshelves for the user.
     b. Extracts bookshelf IDs.
     c. Deletes all placement history referencing those bookshelves.
     d. Deletes all placements on those bookshelves.
     e. Deletes all bookshelves.
     f. Deletes the user record.
     g. Inserts an audit log entry recording the deletion.
  3. The entire transaction succeeds or fails atomically.
- **On success**: Logs success. Returns `:ok`.
- **On failure**: Logs the failed step name and reason. Returns `{:error, "deletion failed at {step}"}`. No retry (max_attempts: 1).

### `Stacks.Workers.ConfirmDeletionJob`
- **Worker**: `Stacks.Workers.ConfirmDeletionJob`
- **Queue**: `:default`
- **Max attempts**: 3
- **What it does**: Stub -- would send a deletion confirmation email in production. Currently logs only.

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A -- Image cleanup is handled separately by the image retention system (US-8.4). The deletion pipeline does not currently delete uploaded images as part of the cascade.

---

## 10. Cache Interactions

N/A -- No explicit cache invalidation is performed during deletion. Caches keyed on user_id will naturally expire.

---

## 11. dbt Model Dependencies

N/A -- The deletion operates on operational tables. Warehouse anonymisation would be handled separately.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: Settings route
- **URL**: `/settings`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Settings page loads with "Delete My Data" as a section.
- **API calls on init**: None for deletion specifically.
- **Initial model state**: Confirmation text empty, delete button disabled.

### Update cycle
- **Msg**: `UserTypesDeleteConfirmation String` -> enables delete button when text == "DELETE"
- **Msg**: `UserClicksDeleteAccount` -> `DELETE /api/gdpr/account`
- **Model change**: Sets loading/success/failure state on deletion section
- **Cmd**: HTTP DELETE call
- **OutMsg**: On success, would trigger session logout and redirect to farewell page.

### View
- **Key elements**: Warning text, confirmation text input, delete button (disabled until "DELETE" typed), farewell message on success.
- **ARIA attributes**: N/A (not yet implemented).
- **CSS classes**: Standard settings page classes with destructive action styling.

---

## 13. Operational Metrics

- **GDPR deletion request count**: Total `AccountDeletionJob` enqueue events. Tracks how often users exercise their right to erasure.
- **Deletion job outcome rate**: Success vs. failure counts. Since `max_attempts: 1`, any failure requires manual intervention -- alert immediately on failure.
- **Cascade step completion**: Track which `Ecto.Multi` step failed (`:delete_history`, `:delete_placements`, `:delete_bookshelves`, `:delete_user`, `:audit`). Identifies recurring data integrity issues.
- **Audit log write throughput**: Two audit entries per deletion flow -- `user.deletion_requested` (pre-enqueue) and `user.data_deleted` (inside the Multi transaction).

---

## 14. Performance & Usability Metrics

- **Account deletion cascade time**: Wall-clock duration of `Stacks.GDPR.Deletion.delete_user_data/1` inside the `Ecto.Multi` transaction. Scales with the user's bookshelf, placement, and placement history volume. Monitor for users with very large libraries.
- **Row counts per cascade**: Number of rows deleted in each Multi step (history, placements, bookshelves, user). Useful for understanding deletion cost distribution.
- **Confirmation UX latency**: Time from HTTP 202 response to session invalidation and farewell page render (client-side, future instrumentation).

---

## 15. Cost Tracking

- **Neon**: Compute cost for the cascade DELETE transaction. Multiple table scans and deletes within a single transaction. Users with large libraries will incur higher compute time. The `max_attempts: 1` policy limits retry cost but increases manual intervention risk.
- **Resend** (future): Email cost for the deletion confirmation notification via `ConfirmDeletionJob` (currently a stub).
- **R2 storage**: Image cleanup is handled separately by the image retention system (US-8.4), not by this deletion pipeline. No direct R2 cost here.
- All operations are DB-only with no external service calls -- cost is dominated by Neon compute for the cascade transaction.
