# US-1.6.2 — Abandon a Book Back to AntiLibrary

## 1. User Story

> **As a** user, **I want to** move a book from the Reading Pile back to the AntiLibrary **so that** I can acknowledge I've stopped reading it without removing it from my collection.

**What the user wants to accomplish:** Gracefully abandon a book without judgement -- it returns to the unread shelf.

**How they accomplish it:**
1. On the book detail overlay (see ADR-005), while the book is in the Reading Pile, the user selects "Antilibrary" from the Move to Shelf dropdown.
2. The system records the transition, including that it was an abandonment (moved backwards in the journey).

**What they see on the page:**
- The user story envisions: "Back to the AntiLibrary. No rush -- it'll be here when you're ready."
- Current implementation shows the generic "Moved successfully." message (the abandon-specific messaging is not yet implemented).

**Acceptance Criteria:**
- Moving from Reading Pile to AntiLibrary uses the same move mechanism as US-1.6.1.
- PlacementHistory records the backward move.
- The book's spine wear should eventually soften from "cracking" back to "softened" (not yet implemented visually).

---

## 2. UI Interaction Flow

### Happy Path
1. User opens book detail overlay for a book currently on the Reading Pile.
2. `currentBookshelf` shows "reading_pile".
3. User clicks "Choose Bookshelf" -> selects "Antilibrary" -> clicks "Move".
4. `ConfirmMove` -> `Api.moveBook placement.id "antilibrary" token MoveCompleted`.
5. `PUT /api/placements/:id/move` with `{ bookshelf: "antilibrary" }`.
6. Backend calls `Shelving.move_book(placement_id, user_id, "antilibrary")`.
7. `MoveCompleted (Ok _)` -> `currentBookshelf` = "antilibrary"; "Moved successfully."

### Sad Paths
Same as US-1.6.1.

### Elm State Machine
- **Page module**: `Page.BookDetail` (same as US-1.6.1)
- **Model fields involved**: Same as US-1.6.1
- **Msg flow**: Same as US-1.6.1 -- there is no separate abandon flow in the code. Abandonment is just a move where `to_bookshelf = "antilibrary"` and `from_bookshelf = "reading_pile"`.
- **RemoteData states**: Same as US-1.6.1
- **OutMsg pattern**: `NoOut`

---

## 3. API Calls

### `PUT /api/placements/:id/move`
Same endpoint and contract as US-1.6.1 with `{ bookshelf: "antilibrary" }`.

Note: The `Shelving` context also exposes `abandon_book/2` which is a thin wrapper:
```elixir
def abandon_book(placement_id, user_id) do
  move_book(placement_id, user_id, "looking_for_home")
end
```
However, this function moves to "looking_for_home" (not "antilibrary") and is not currently called by any controller endpoint. The frontend uses the generic `move` endpoint.

---

## 4. Auth & Middleware Guards

Same as US-1.6.1.

---

## 5. Database Interactions

Same as US-1.6.1. The Ecto.Multi transaction:
1. Updates `bookshelf_placements.bookshelf_id` to the antilibrary bookshelf's ID.
2. Inserts a `bookshelf_placement_history` row with `from_bookshelf = reading_pile_bookshelf_id` and `to_bookshelf = antilibrary_bookshelf_id`.

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `placement.moved`
- **Aggregate**: `placement` / `placement.id`
- **Payload**: `%{from_bookshelf: "reading_pile", to_bookshelf: "antilibrary"}`
- **Emitted by**: `Stacks.Shelving.move_book/3`
- **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
Same as US-1.6.1:
- `Stacks.Feeds.Handlers.PlacementHandler` -- updates RSS feeds
- `Stacks.Workers.DbtRefreshHandler` -- refreshes dbt models

---

## 7. Background Jobs (Oban)

Same as US-1.6.1 -- dbt refresh triggered by `placement.moved` event.

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

Same as US-1.6.1: `stg_bookshelf_placements`, `stg_bookshelf_placement_history` refreshed via `DbtRefreshHandler`.

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A -- happens within the book detail overlay.

### Init
Same as US-1.6.1 / US-1.4.1.

### Update cycle
Same as US-1.6.1. The abandon flow is not a separate code path -- it is simply the generic move flow where the user selects "antilibrary" as the target.

### Key distinction from US-1.6.1
The user story describes abandon-specific UX (gentle messaging, gradual wear state transition). In the current implementation:
- The ShelfMover dropdown includes "Antilibrary" as an available target when `currentBookshelf = "reading_pile"`.
- The move confirmation uses the generic "Moved successfully." text.
- No abandon-specific messaging ("Back to the AntiLibrary. No rush...") is implemented.
- No gradual wear state transition from "cracking" to "softened" is implemented -- the wear level changes immediately to the target shelf's config wear level on next browse.

### View
Same as US-1.6.1. See US-1.6.1 section 12 for full CSS class and ARIA details.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/placements/:id/move", method="PUT", to="antilibrary"}` | Phoenix.Telemetry | Counter | Increment per abandon (move to antilibrary) request | N/A (volume baseline) |
| `http.response.status{endpoint="/api/placements/:id/move", status=200}` | Phoenix.Telemetry | Counter | Increment per successful abandon | >= 98% of requests |
| `http.response.status{endpoint="/api/placements/:id/move", status=403}` | Phoenix.Telemetry | Counter | Increment per ownership failure | Informational |
| `db.query.count{table="op.bookshelf_placements", op="update"}` | Ecto.Telemetry | Counter | Increment per placement update | 1 per successful abandon |
| `db.query.count{table="op.bookshelf_placement_history", op="insert"}` | Ecto.Telemetry | Counter | Increment per history record (from reading_pile to antilibrary) | 1 per successful abandon |
| `db.query.duration{transaction="move_book"}` | Ecto.Telemetry | Histogram (ms) | Ecto.Multi transaction time | p95 < 50ms |
| `event.emit.count{type="placement.moved", payload.to="antilibrary"}` | Events module | Counter | Increment per `placement.moved` event with `to_bookshelf: "antilibrary"` | 1 per successful abandon |
| `error.rate{endpoint="/api/placements/:id/move"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `abandon.transaction_time` | Elm Performance API | Histogram (ms) | Time from `ConfirmMove` to `MoveCompleted (Ok _)` for reading_pile -> antilibrary moves | p50 < 200ms, p95 < 500ms |
| `abandon.frequency` | Elm event tracking | Counter | Count of moves where source = reading_pile and target = antilibrary | Informational (reading behaviour) |
| `abandon.time_on_reading_pile` | Server-side calculation | Histogram (days) | Time between placement on reading_pile and abandon move (from PlacementHistory timestamps) | Informational (engagement insight) |
| `user.abandons_per_session` | Elm event tracking | Counter per session | Increment on each abandon (reading_pile -> antilibrary move) | Informational |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of abandon operations | Same cost profile as US-1.6.1 (generic move). Write operation with Ecto.Multi transaction. |
| Neon DB (PostgreSQL) | Compute Units (CU) per transaction | Abandon transactions | Same as US-1.6.1: SELECT + UPDATE + INSERT history + INSERT event. ~4 statements per abandon. |
| Neon DB (PostgreSQL) | Write IOPS | PlacementHistory inserts + event_log inserts | Each abandon creates 2 new rows. Same cost as any move. |
| Oban (background) | CPU-ms per job | `DbtRefreshHandler` triggered by `placement.moved` event | Same as US-1.6.1. |
