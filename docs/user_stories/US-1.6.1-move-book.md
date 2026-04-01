# US-1.6.1 — Move a Book Between Shelves

## 1. User Story

> **As a** user, **I want to** move a book from one shelf to another **so that** I can track my reading journey as a book progresses from wish to read.

**What the user wants to accomplish:** Record the natural journey of a book: WishList to AntiLibrary to Reading Pile to Library -- and optionally onward to Looking for a Home when they're ready to part with it.

**How they accomplish it:**
1. On the book detail overlay, the user clicks "Choose Bookshelf" to open the shelf mover.
2. They select the target shelf from a dropdown. All five bookshelves are available: Library, Antilibrary, Wish List, Reading Pile, Looking for a Home (the current shelf is excluded from the list).
3. They click "Move" to confirm.
4. The system moves the placement, records a PlacementHistory entry, emits events, and logs an audit entry -- all atomically via Ecto.Multi.
5. The overlay updates to show the new current bookshelf.

**What they see on the page:**
- The dropdown styled as a `select` element with bookshelf options.
- On success: "Moved successfully." status message; `currentBookshelf` updates.
- On failure: "Failed to move book. Please try again."

**Acceptance Criteria:**
- Move changes the placement's `bookshelf_id` to the target bookshelf.
- PlacementHistory record created with `from_bookshelf` and `to_bookshelf` UUIDs.
- `placement.moved` event emitted.
- Audit log entry created.
- All within an Ecto.Multi transaction.
- Ownership verified before move.

---

## 2. UI Interaction Flow

### Happy Path
1. User opens book detail overlay (US-1.4.1).
2. User clicks "Choose Bookshelf" button -> `OpenBookshelfMover` msg -> `bookshelfMoverOpen = True`.
3. `Components.ShelfMover.shelfMover` renders with dropdown of available shelves (current shelf excluded).
4. User selects a target shelf -> `SelectBookshelf shelfName` -> `selectedBookshelf` updated.
5. User clicks "Move" -> `ConfirmMove` msg.
6. `Api.moveBook placement.id selectedBookshelf token MoveCompleted` fires; `moveState = Loading`.
7. API call: `PUT /api/placements/:id/move` with `{ bookshelf: "target_name" }`.
8. `MoveCompleted (Ok _)` -> `moveState = Success ()`; `currentBookshelf` -> `selectedBookshelf`; shelf mover closes.
9. "Moved successfully." message appears.

### Sad Paths
- **Not owner**: API returns 403 -> `MoveCompleted (Err (Http.BadStatus 403))` -> "Failed to move book. Please try again."
- **Invalid shelf name**: API returns 422 -> same error display.
- **No placement**: If `model.placement == Nothing`, `ConfirmMove` is a no-op.
- **No token**: `ConfirmMove` is a no-op.

### Elm State Machine
- **Page module**: `Page.BookDetail`
- **Model fields involved**: `bookshelfMoverOpen : Bool`, `selectedBookshelf : String`, `currentBookshelf : String`, `moveState : RemoteData Http.Error ()`, `placement : Maybe Placement`
- **Msg flow**: `OpenBookshelfMover` -> user selects shelf -> `SelectBookshelf` -> `ConfirmMove` -> API call -> `MoveCompleted`
- **RemoteData states**: `moveState`: `NotAsked` -> `Loading` -> `Success ()` / `Failure err`
- **OutMsg pattern**: `NoOut` for all move-related messages.

---

## 3. API Calls

### `PUT /api/placements/:id/move`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.move/2`
- **Request body**: `{ bookshelf: "target_bookshelf_name" }`
- **Response (success)**: `{ placement: { id, book_id, bookshelf_id, position, placed_at, removed_at } }` -- HTTP 200
- **Response (error)**: `{ error: "forbidden" }` -- HTTP 403 (not owner); `{ error: "bookshelf parameter is required" }` -- HTTP 422; `{ error: "..." }` -- HTTP 422 (transaction error)
- **FallbackController handling**: 403 for ownership failure; 422 for missing params or Multi errors.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline`
- **Visibility checks**: N/A -- move is an ownership operation, not a visibility operation.
- **Age gate**: N/A
- **Ownership checks**: `Shelving.move_book/3` loads the placement, preloads its bookshelf, and checks `placement.bookshelf.user_id != user_id` -- returns `{:error, :unauthorized}` on mismatch.

---

## 5. Database Interactions

### Read: Load placement with bookshelf
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Repo.get!(Placement, placement_id) |> Repo.preload(:bookshelf)`
- **Schema module**: `Stacks.Shelving.Placement`

### Write: Update placement bookshelf (Ecto.Multi step `:placement`)
- **Table(s)**: `op.bookshelf_placements`
- **Operation**: UPDATE `bookshelf_id` to target bookshelf's ID
- **Changeset validations**: `Placement.changeset(placement, %{bookshelf_id: to_bookshelf.id})`
- **Transaction**: Yes, `Ecto.Multi` wraps all steps

### Write: Create placement history (Ecto.Multi step `:history`)
- **Table(s)**: `op.bookshelf_placement_history`
- **Operation**: INSERT
- **Changeset validations**: `PlacementHistory.changeset(%PlacementHistory{}, %{book_id: placement.book_id, from_bookshelf: from_bookshelf.id, to_bookshelf: to_bookshelf.id, moved_at: DateTime.utc_now()})`
- **Required fields**: `book_id`, `from_bookshelf`, `to_bookshelf`

### Write: Get or create target bookshelf
- **Table(s)**: `op.bookshelves`
- **Operation**: SELECT then conditional INSERT
- **Query**: `Repo.get_by(Bookshelf, user_id: user_id, name: to_bookshelf_name)` -- if nil, inserts new bookshelf
- **Changeset validations**: `Bookshelf.changeset` validates `name` in `~w(antilibrary library wishlist reading_pile looking_for_home)`, `visibility` in `~w(owner group platform)`

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `placement.moved`
- **Aggregate**: `placement` / `placement.id`
- **Payload**: `%{from_bookshelf: "source_name", to_bookshelf: "target_name"}`
- **Emitted by**: `Stacks.Shelving.move_book/3` (Ecto.Multi step `:emit_event`)
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **Handler**: `Stacks.Feeds.Handlers.PlacementHandler`
- **Action**: Updates RSS feeds for affected bookshelves
- **Downstream effects**: Feed XML regeneration

- **Handler**: `Stacks.Workers.DbtRefreshHandler`
- **Action**: Enqueues dbt model refresh
- **Downstream effects**: `stg_bookshelf_placements`, `stg_bookshelf_placement_history` refresh

---

## 7. Background Jobs (Oban)

- **Worker**: `DbtRefreshHandler` (enqueued by event handler)
- **Queue**: `:dbt_refresh`
- **Args**: Event payload
- **What it does**: Triggers dbt model refresh for placement-related staging models
- **On success**: Models refreshed
- **On failure**: Retried per Oban config

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A -- bookshelf listings are not cached. The move will be reflected on the next bookshelf browse.

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements`, `stg_bookshelf_placement_history`
- **Trigger**: `placement.moved` event via `DbtRefreshHandler`
- **Materialisation**: view
- **Consumer**: Downstream analytics marts (read counts, journey tracking)

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A -- move happens within the book detail overlay, which does not change the URL.

### Init
Move state initialises as `moveState = NotAsked` in `Page.BookDetail.init`.

### Update cycle
- **Msg `OpenBookshelfMover`**: `bookshelfMoverOpen` -> `True`
- **Msg `CloseBookshelfMover`**: `bookshelfMoverOpen` -> `False`
- **Msg `SelectBookshelf shelf`**: `selectedBookshelf` -> `shelf`
- **Msg `ConfirmMove`**: Requires `model.placement /= Nothing` and `maybeToken /= Nothing`; fires `Api.moveBook`; `bookshelfMoverOpen` -> `False`; `moveState` -> `Loading`
- **Msg `MoveCompleted (Ok _)`**: `moveState` -> `Success ()`; `currentBookshelf` -> `selectedBookshelf`; `selectedBookshelf` -> `firstAvailableBookshelf newBookshelf`; `placement.bookshelfName` updated; `bookshelfMoverOpen` -> `False`
- **Msg `MoveCompleted (Err err)`**: `moveState` -> `Failure err`

### ShelfMover component
`Components.ShelfMover.shelfMover` renders:
- A `span.shelf-mover__label` "Move to:"
- A `select.shelf-mover__select` with `aria-label="Target bookshelf"` containing all 5 bookshelves (current excluded)
- A `button.shelf-mover__btn` "Move"

Available bookshelves in the dropdown:
| Value | Label |
|-------|-------|
| `library` | Library |
| `antilibrary` | Antilibrary |
| `wishlist` | Wish List |
| `reading_pile` | Reading Pile |
| `looking_for_home` | Looking for a Home |

### View
- **Key elements**: `viewShelfActions model` renders the "Move to Shelf" section with heading showing current bookshelf. If `bookshelfMoverOpen`, shows `shelfMover` + Cancel button; otherwise shows "Choose Bookshelf" button. `viewMoveState` shows status messages.
- **ARIA attributes**: `role="region"`, `aria-labelledby="section-shelf-actions"`, `aria-label="Target bookshelf"` on select
- **CSS classes**: `book-detail__section book-detail__shelf-actions`, `shelf-mover`, `shelf-mover__label`, `shelf-mover__select`, `shelf-mover__btn`, `book-detail__status`, `book-detail__status--loading`, `book-detail__status--success`, `book-detail__status--error`, `btn btn--secondary`, `btn btn--ghost btn--sm`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/placements/:id/move", method="PUT"}` | Phoenix.Telemetry | Counter | Increment per move request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/placements/:id/move", status=200}` | Phoenix.Telemetry | Counter | Increment per successful move | >= 98% of requests |
| `http.response.status{endpoint="/api/placements/:id/move", status=403}` | Phoenix.Telemetry | Counter | Increment per ownership failure | Informational |
| `http.response.status{endpoint="/api/placements/:id/move", status=422}` | Phoenix.Telemetry | Counter | Increment per validation error | Informational |
| `db.query.count{table="op.bookshelf_placements", op="update"}` | Ecto.Telemetry | Counter | Increment per placement update | 1 per successful move |
| `db.query.count{table="op.bookshelf_placement_history", op="insert"}` | Ecto.Telemetry | Counter | Increment per history record creation | 1 per successful move |
| `db.query.duration{transaction="move_book"}` | Ecto.Telemetry | Histogram (ms) | Total Ecto.Multi transaction time (placement update + history insert + event emit) | p95 < 50ms |
| `event.emit.count{type="placement.moved"}` | Events module | Counter | Increment per `placement.moved` event emitted | 1 per successful move |
| `error.rate{endpoint="/api/placements/:id/move"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `move.transaction_time` | Elm Performance API | Histogram (ms) | Time from `ConfirmMove` msg to `MoveCompleted (Ok _)` | p50 < 200ms, p95 < 500ms |
| `move.time_to_confirmation` | Elm Performance API | Histogram (ms) | Time from opening shelf mover to clicking "Move" (user decision time) | Informational (UX friction) |
| `user.moves_per_session` | Elm event tracking | Counter per session | Increment on each `MoveCompleted (Ok _)` | Informational (engagement) |
| `move.target_shelf_distribution` | Elm event tracking | Counter per shelf | Count of moves to each target shelf | Informational (journey patterns) |
| `move.source_shelf_distribution` | API request context | Counter per shelf | Count of moves from each source shelf | Informational (journey patterns) |
| `move.failure_rate` | Elm event tracking | Gauge (%) | `MoveCompleted (Err _)` / total `ConfirmMove` msgs | < 2% |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of move operations | Write operation: Ecto.Multi transaction with 3-4 steps (read placement, update bookshelf_id, insert history, emit event). More CPU than read-only browse. |
| Neon DB (PostgreSQL) | Compute Units (CU) per transaction | Move transactions (read + update + insert + event) | Ecto.Multi wraps: SELECT placement with preload, UPDATE bookshelf_id, INSERT placement_history, INSERT event_log. ~4 statements per move. |
| Neon DB (PostgreSQL) | Write IOPS | PlacementHistory inserts + event_log inserts | Each move creates 2 new rows (history + event). Indexed writes on both tables. |
| Oban (background) | CPU-ms per job | `DbtRefreshHandler` jobs triggered by `placement.moved` | Each move event triggers a dbt refresh job. Cost depends on dbt model complexity. |
