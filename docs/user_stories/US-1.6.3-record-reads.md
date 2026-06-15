# US-1.6.3 — Record Multiple Reads

## 1. User Story

> **As a** user, **I want** the system to track when I've read a book multiple times **so that** its spine wear reflects how well-loved it is.

**What the user wants to accomplish:** Have re-reads recorded and reflected in the book's visual presentation.

**How they accomplish it:**
1. A book already in the Library bookshelf can be moved back to the Reading Pile and then returned to the Library.
2. Each round trip increments the read count.
3. The spine wear progresses from "well-read" to "well-loved" after multiple reads.

**What they see on the page:**
- On the book detail overlay, a small "Read 3 times" indicator appears below the title (planned -- not yet implemented in the overlay).
- The spine on the Library shelf shows increasingly heavy wear (planned -- currently all Library books show `Softened` wear).

**Acceptance Criteria:**
- Re-reading a book creates a new placement and PlacementHistory record.
- `placement.reread` event emitted.
- Audit log entry created.
- Move count from PlacementHistory drives wear level (server-side via `spine_data/1`).

---

## 2. UI Interaction Flow

### Happy Path (Re-read via Move)
1. User opens book detail overlay for a book in the Library.
2. User clicks "Choose Bookshelf" -> selects "Reading Pile" -> clicks "Move".
3. Book moves to Reading Pile (standard move, US-1.6.1).
4. User reads the book again.
5. User opens book detail overlay from Reading Pile.
6. User clicks "Choose Bookshelf" -> selects "Library" -> clicks "Move".
7. Book returns to Library with an additional PlacementHistory record.

### Happy Path (Re-read via `reread_book/1`)
The `Shelving.reread_book/1` function provides a dedicated re-read flow:
1. Takes a `placement_id` of an existing placement.
2. Creates a NEW placement on the Library bookshelf (does not update the existing one).
3. Records a PlacementHistory entry from the original bookshelf to the Library.
4. Emits a `placement.reread` event.
5. This function is not yet exposed via a controller endpoint.

### Sad Paths
- **Not owner**: Same as US-1.6.1.
- **Placement not found**: `Repo.get!` raises -- would 500 (should be handled gracefully).

### Elm State Machine
- **Page module**: `Page.BookDetail` (same as US-1.6.1)
- **Model fields involved**: Same move-related fields as US-1.6.1
- **Msg flow**: Same as US-1.6.1 -- currently no dedicated re-read Msg or UI element. Re-reads are accomplished via two sequential moves (Library -> Reading Pile -> Library).
- **RemoteData states**: Same as US-1.6.1
- **OutMsg pattern**: `NoOut`

---

## 3. API Calls

### Current: Two sequential `PUT /api/placements/:id/move` calls
1. First move: `{ bookshelf: "reading_pile" }` (Library -> Reading Pile)
2. Second move: `{ bookshelf: "library" }` (Reading Pile -> Library)

### Planned: Dedicated re-read endpoint
A future `POST /api/placements/:id/reread` would call `Shelving.reread_book/1` directly, creating a new placement and emitting `placement.reread` in a single operation.

---

## 4. Auth & Middleware Guards

Same as US-1.6.1 for the move-based approach.

For `Shelving.reread_book/1` (not yet exposed via API):
- Ownership is verified by loading the placement's bookshelf and checking `user_id`.

---

## 5. Database Interactions

### Via move approach (current)
Two Ecto.Multi transactions (same as US-1.6.1, executed twice):
1. Move to Reading Pile: UPDATE placement, INSERT history, emit event, audit log.
2. Move back to Library: UPDATE placement, INSERT history, emit event, audit log.

### Via `reread_book/1` (planned endpoint)

#### Write: Create new placement (Ecto.Multi step `:placement`)
- **Table(s)**: `op.bookshelf_placements`
- **Operation**: INSERT (new placement, not update)
- **Changeset validations**: `Placement.changeset(%Placement{}, %{book_id: placement.book_id, bookshelf_id: library_bookshelf.id})`

#### Write: Create placement history (Ecto.Multi step `:history`)
- **Table(s)**: `op.bookshelf_placement_history`
- **Operation**: INSERT
- **Fields**: `book_id`, `from_bookshelf` (original bookshelf ID), `to_bookshelf` (library bookshelf ID), `moved_at`

### Read: Wear level calculation
- **Table(s)**: `op.bookshelf_placement_history`
- **Query**: `PlacementHistory |> where([h], h.book_id == ^book_id) |> Repo.aggregate(:count, :id)` in `Shelving.spine_data/1`
- **Wear level mapping**: 0 moves = `:new`, 1-2 = `:light`, 3-5 = `:moderate`, 6+ = `:heavy`

---

## 6. Event Flow & Lifecycle

### Events Emitted (via move approach)
Two `placement.moved` events (one per move).

### Events Emitted (via `reread_book/1`)
- **Event type**: `placement.reread`
- **Aggregate**: `placement` / `new_placement.id`
- **Payload**: `%{book_id: placement.book_id, to_bookshelf: "library"}`
- **Emitted by**: `Stacks.Shelving.reread_book/1`
- **Emission method**: `Events.emit_safe/1`

Note: `placement.reread` is NOT registered in `Stacks.Events.Registry` -- no handlers are currently subscribed to this event type.

### Event Handlers Triggered (via move approach)
Same as US-1.6.1 for each move:
- `Stacks.Feeds.Handlers.PlacementHandler`
- `Stacks.Workers.DbtRefreshHandler`

---

## 7. Background Jobs (Oban)

Same as US-1.6.1 -- dbt refresh triggered per move event.

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placement_history`
- **Trigger**: `placement.moved` (or `placement.reread` once registered) via `DbtRefreshHandler`
- **Materialisation**: view
- **Consumer**: `wh.mart_community_read_count` uses placement history to calculate read counts

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A -- happens within the book detail overlay via sequential moves.

### Init
Same as US-1.4.1.

### Update cycle
Same as US-1.6.1. No dedicated re-read Msg or state exists. Re-reads are two sequential move operations by the user.

### Planned Elm enhancements
To fully implement this story:
- Add `readCount : Maybe Int` to the Book type (populated from `community_read_count` or per-user read count)
- Display "Read N times" below the title in `viewHero`
- Optionally add a "Mark as Re-read" button that calls a dedicated `/reread` endpoint
- Update spine wear rendering to use per-book move count rather than per-shelf config wear level

### View
Same as US-1.6.1 for the move flow. No re-read-specific UI elements exist yet.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/placements/:id/move", method="PUT"}` | Phoenix.Telemetry | Counter | Increment per move request (re-reads use two sequential moves) | N/A (volume baseline) |
| `http.response.status{endpoint="/api/placements/:id/move", status=200}` | Phoenix.Telemetry | Counter | Increment per successful move | >= 98% of requests |
| `db.query.count{table="op.bookshelf_placements", op="update"}` | Ecto.Telemetry | Counter | Increment per placement update (2 per re-read cycle) | 2 per re-read (Library -> Reading Pile, Reading Pile -> Library) |
| `db.query.count{table="op.bookshelf_placement_history", op="insert"}` | Ecto.Telemetry | Counter | Increment per history record (2 per re-read cycle) | 2 per re-read |
| `db.query.duration{transaction="move_book"}` | Ecto.Telemetry | Histogram (ms) | Ecto.Multi transaction time per move | p95 < 50ms |
| `db.query.count{table="op.bookshelf_placement_history", op="aggregate"}` | Ecto.Telemetry | Counter | Increment per `spine_data/1` wear level calculation | Informational (when wired to frontend) |
| `event.emit.count{type="placement.moved"}` | Events module | Counter | Increment per `placement.moved` event (2 per re-read cycle) | 2 per re-read |
| `event.emit.count{type="placement.reread"}` | Events module | Counter | Increment per `placement.reread` event (via `reread_book/1`, not yet exposed) | 0 currently (planned endpoint) |
| `error.rate{endpoint="/api/placements/:id/move"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `reread.cycle_time` | Elm Performance API | Histogram (ms) | Combined time for both move operations in a re-read cycle | p50 < 400ms, p95 < 1000ms (two sequential API calls) |
| `reread.frequency_per_book` | Server-side (`spine_data/1`) | Counter per book | Count of PlacementHistory records for each book (move_count) | Informational (engagement depth) |
| `reread.wear_level_distribution` | Server-side (`spine_data/1`) | Counter per level | Distribution of books across wear levels (`:new`, `:light`, `:moderate`, `:heavy`) | Informational (collection maturity) |
| `user.rereads_per_session` | Elm event tracking | Counter per session | Count of Library -> Reading Pile -> Library round trips | Informational (engagement) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of re-read operations (2 moves per re-read) | Each re-read requires two sequential move transactions. Double the server CPU of a single move. Planned `/reread` endpoint would reduce to one transaction. |
| Neon DB (PostgreSQL) | Compute Units (CU) per transaction | Two Ecto.Multi transactions per re-read | Current: 2 x (SELECT + UPDATE + INSERT history + INSERT event) = ~8 statements per re-read. Planned `reread_book/1` endpoint: 1 x (INSERT placement + INSERT history + INSERT event) = ~3 statements. |
| Neon DB (PostgreSQL) | Write IOPS | PlacementHistory inserts (2 per re-read) + event_log inserts (2 per re-read) | 4 new rows per re-read cycle. Planned endpoint would reduce to 2 rows. |
| Oban (background) | CPU-ms per job | `DbtRefreshHandler` jobs (2 per re-read cycle) | Two `placement.moved` events each trigger a dbt refresh. Planned: `placement.reread` is not yet registered with handlers. |
