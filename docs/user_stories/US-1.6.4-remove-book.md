# US-1.6.4 — Remove a Book from the Collection

## 1. User Story

> **As a** user, **I want to** permanently remove a book from my collection **so that** I can correct mistakes or declutter shelves without affecting other data.

**What the user wants to accomplish:** Get rid of a book that was added by mistake, or that they no longer want to track. This is different from moving between shelves -- this is removal.

**How they accomplish it:**
1. On the book detail overlay (see ADR-005), the user clicks "Remove from collection" (in a less prominent position -- danger zone).
2. A confirmation modal appears: "Are you sure you want to remove \"[Title]\" from your collection? This cannot be undone."
3. The user confirms.
4. The book's shelf placement is soft-deleted (`removed_at` set). The book record itself remains in the database.
5. The history of the book's journey is preserved in `bookshelf_placement_history`.

**What they see on the page:**
- "Remove from collection" button styled as `btn--danger btn--sm`.
- Confirmation modal with "Keep It" (secondary) and "Remove" (danger) buttons.
- After removal, the overlay closes and navigates to the previous route.

**Acceptance Criteria:**
- Soft-delete: `removed_at` timestamp set on the placement.
- `placement.removed` event emitted.
- Audit log entry created.
- All within an Ecto.Multi transaction.
- Ownership verified.
- Book record not deleted (only placement soft-deleted).
- PlacementHistory preserved.

---

## 2. UI Interaction Flow

### Happy Path
1. User views a book they own in the detail overlay.
2. User scrolls to the danger zone section at the bottom.
3. User clicks "Remove from collection" -> `OpenRemoveModal` msg -> `removeModalOpen = True`.
4. `Components.RemoveBookModal.removeBookModal` renders on top of overlay.
5. Modal shows: "Are you sure you want to remove \"[Title]\" from your collection? This cannot be undone."
6. User clicks "Remove" -> `ConfirmRemove` msg.
7. `Api.removeBook placement.id token RemoveCompleted` fires; `removeModalOpen` -> `False`; `removeState` -> `Loading`.
8. API call: `DELETE /api/placements/:id`.
9. `RemoveCompleted (Ok _)` -> `removeState = Success ()`; `NavigateTo previousRoute` (returns to shelf).

### Sad Paths
- **Not owner**: API returns 403 -> `RemoveCompleted (Err err)` -> "Failed to remove book. Please try again."
- **Placement not found**: API returns 404 -> error display.
- **Cancel**: User clicks "Keep It" -> `CloseRemoveModal` -> `removeModalOpen = False`.
- **No placement**: If `model.placement == Nothing`, `ConfirmRemove` is a no-op.
- **No token**: `ConfirmRemove` is a no-op.

### Elm State Machine
- **Page module**: `Page.BookDetail`
- **Model fields involved**: `removeModalOpen : Bool`, `removeState : RemoteData Http.Error ()`, `placement : Maybe Placement`, `previousRoute : Maybe Route`
- **Msg flow**: `OpenRemoveModal` -> modal renders -> `ConfirmRemove` -> API call -> `RemoveCompleted`
- **RemoteData states**: `removeState`: `NotAsked` -> `Loading` -> `Success ()` / `Failure err`
- **OutMsg pattern**: `NavigateTo previousRoute` on successful removal (returns user to their shelf).

---

## 3. API Calls

### `DELETE /api/placements/:id`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.delete/2`
- **Request body**: N/A
- **Response (success)**: HTTP 204 (no body)
- **Response (error)**: `{ error: "not found" }` -- HTTP 404; `{ error: "forbidden" }` -- HTTP 403; `{ errors: {...} }` -- HTTP 422
- **FallbackController handling**: 404 for missing placement; 403 for ownership failure; 422 for changeset errors.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: N/A -- deletion is an ownership operation.
- **Age gate**: N/A
- **Ownership checks**: Two-stage ownership verification in the controller:
  1. Controller loads placement with bookshelf preloaded: `Repo.get(Placement, placement_id) |> Repo.preload(:bookshelf)`
  2. Pattern match checks `%Placement{bookshelf: %Bookshelf{user_id: owner_id}} when owner_id != user.id` -> 403
  3. Context function `Shelving.remove_book/2` also checks `placement.bookshelf.user_id != user_id` -> `{:error, :unauthorized}`

---

## 5. Database Interactions

### Read: Load placement with bookshelf (controller)
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Repo.get(Placement, placement_id) |> Repo.preload(:bookshelf)`
- **Schema module**: `Stacks.Shelving.Placement`

### Read: Load placement with bookshelf (context, second load)
- **Table(s)**: Same
- **Query**: `Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)`
- **Schema module**: `Stacks.Shelving.Placement`

### Write: Soft-delete placement (Ecto.Multi step `:placement`)
- **Table(s)**: `op.bookshelf_placements`
- **Operation**: UPDATE -- sets `removed_at = DateTime.utc_now()`
- **Changeset validations**: `Placement.changeset(placement, %{removed_at: DateTime.utc_now()})`
- **Transaction**: Yes, `Ecto.Multi`
- **Denormalization**: N/A -- `removed_at` is the soft-delete marker; `is_nil(removed_at)` filters exclude removed placements from all queries.

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `placement.removed`
- **Aggregate**: `placement` / `placement.id`
- **Payload**: `%{book_id: placement.book_id}`
- **Emitted by**: `Stacks.Shelving.remove_book/2` (Ecto.Multi step `:emit_event`)
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Feeds.Handlers.PlacementHandler`
- **Action**: Updates RSS feeds for the affected bookshelf
- **Downstream effects**: Feed XML regeneration (book removed from feed)

Note: `placement.removed` is NOT registered with `DbtRefreshHandler` (unlike `placement.created` and `placement.moved`). This means dbt models may not immediately reflect removals.

---

## 7. Background Jobs (Oban)

N/A -- `placement.removed` does not trigger `DbtRefreshHandler` in the current registry. Feed handler runs synchronously or via its own mechanism.

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A -- book records and their associated cover images are not deleted. Only the placement is soft-deleted.

---

## 10. Cache Interactions

N/A -- bookshelf listings are not cached. The removal will be reflected on the next bookshelf browse.

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements`
- **Trigger**: NOT triggered by `placement.removed` in the current registry (potential gap)
- **Materialisation**: view
- **Consumer**: Placement counts and journey models would reflect removal on next manual or scheduled refresh

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A -- removal happens within the book detail overlay, which does not change the URL.

### Init
Remove state initialises as `removeState = NotAsked` in `Page.BookDetail.init`.

### Update cycle
- **Msg `OpenRemoveModal`**: `removeModalOpen` -> `True`
- **Msg `CloseRemoveModal`**: `removeModalOpen` -> `False`
- **Msg `ConfirmRemove`**: Requires `model.placement /= Nothing` and `maybeToken /= Nothing`; fires `Api.removeBook placement.id token RemoveCompleted`; `removeModalOpen` -> `False`; `removeState` -> `Loading`
- **Msg `RemoveCompleted (Ok _)`**: `removeState` -> `Success ()`; fires `NavigateTo (Maybe.withDefault Route.Library model.previousRoute)` -- navigates back to the shelf the user came from (defaults to Library)
- **Msg `RemoveCompleted (Err err)`**: `removeState` -> `Failure err`

### RemoveBookModal component
`Components.RemoveBookModal.removeBookModal` renders:
- `div.modal-overlay` -- backdrop
- `div.modal` -- centered modal card
  - `h2.modal__title` "Remove Book"
  - `p.modal__message` "Are you sure you want to remove \"[title]\" from your collection? This cannot be undone."
  - `div.modal__actions` containing:
    - `button.btn.btn--secondary` "Keep It" (fires `onCancel`)
    - `button.btn.btn--danger` "Remove" (fires `onConfirm`)

### View
- **Key elements**:
  - `viewDangerZone`: `section.book-detail__section.book-detail__danger-zone` with "Remove from collection" button (`btn btn--danger btn--sm`)
  - `viewRemoveState`: status messages -- `Loading`: "Removing...", `Failure _`: "Failed to remove book. Please try again.", `Success _`: empty (user has navigated away)
  - Modal overlay renders when `removeModalOpen = True` and `book = Success _`
- **ARIA attributes**: Standard button semantics; no explicit ARIA on the modal (could be enhanced with `role="alertdialog"`)
- **CSS classes**: `book-detail__danger-zone`, `btn btn--danger btn--sm`, `book-detail__status`, `book-detail__status--loading`, `book-detail__status--error`, `modal-overlay`, `modal`, `modal__title`, `modal__message`, `modal__actions`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/placements/:id", method="DELETE"}` | Phoenix.Telemetry | Counter | Increment per remove request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/placements/:id", status=204}` | Phoenix.Telemetry | Counter | Increment per successful removal (204 No Content) | >= 98% of requests |
| `http.response.status{endpoint="/api/placements/:id", status=403}` | Phoenix.Telemetry | Counter | Increment per ownership failure | Informational |
| `http.response.status{endpoint="/api/placements/:id", status=404}` | Phoenix.Telemetry | Counter | Increment per not-found placement | Informational |
| `db.query.count{table="op.bookshelf_placements", op="update", field="removed_at"}` | Ecto.Telemetry | Counter | Increment per soft-delete (UPDATE setting `removed_at`) | 1 per successful removal |
| `db.query.duration{transaction="remove_book"}` | Ecto.Telemetry | Histogram (ms) | Total Ecto.Multi transaction time (read placement + soft-delete + emit event) | p95 < 30ms |
| `event.emit.count{type="placement.removed"}` | Events module | Counter | Increment per `placement.removed` event emitted | 1 per successful removal |
| `error.rate{endpoint="/api/placements/:id", method="DELETE"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `remove.transaction_time` | Elm Performance API | Histogram (ms) | Time from `ConfirmRemove` msg to `RemoveCompleted (Ok _)` | p50 < 150ms, p95 < 400ms |
| `remove.confirmation_time` | Elm Performance API | Histogram (ms) | Time from `OpenRemoveModal` to `ConfirmRemove` (user decision time in modal) | Informational (UX friction / safety) |
| `remove.cancel_rate` | Elm event tracking | Gauge (%) | `CloseRemoveModal` / (`CloseRemoveModal` + `ConfirmRemove`) -- how often users cancel removal | Informational (safety check effectiveness) |
| `user.removes_per_session` | Elm event tracking | Counter per session | Increment on each `RemoveCompleted (Ok _)` | Informational (engagement) |
| `remove.failure_rate` | Elm event tracking | Gauge (%) | `RemoveCompleted (Err _)` / total `ConfirmRemove` msgs | < 2% |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of remove operations | Write operation: Ecto.Multi transaction with soft-delete (UPDATE `removed_at`) + event emission. Lighter than move (no history insert). |
| Neon DB (PostgreSQL) | Compute Units (CU) per transaction | Remove transactions (2x read + update + event) | Controller reads placement with preload (ownership check), then context reads again + UPDATEs `removed_at` + INSERTs event_log. ~4 statements total. |
| Neon DB (PostgreSQL) | Write IOPS | Soft-delete update + event_log insert | Each removal updates 1 row (set `removed_at`) and inserts 1 row (event_log). Note: `placement.removed` is NOT registered with `DbtRefreshHandler`, so no background dbt job is triggered. |
| Oban (background) | N/A | N/A | `placement.removed` does not trigger `DbtRefreshHandler` in the current event registry. Only `PlacementHandler` (RSS feed update) processes this event. |
