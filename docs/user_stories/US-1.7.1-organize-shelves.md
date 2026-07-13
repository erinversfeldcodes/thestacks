# US-1.7.1 — Organize Books into Shelves

## 1. User Story

> **As a** user, **I want to** organize the books within a bookshelf across several physical shelves **so that** my bookcase reads like a real one — ordered rows I arrange by hand, rather than one undifferentiated wall of spines.

**What the user wants to accomplish:** A single named bookshelf (say, the Library) can hold hundreds of spines. The user wants to break that mass into distinct horizontal **shelves** — the wooden planks of the bookcase — so they can group and sequence their books the way they would in a real room: a top shelf for the treasured hardbacks, a lower shelf for the paperbacks, and so on. Shelves are *ordered* (top to bottom), and books can be lifted from one shelf and set down on another within the same bookcase.

**Vocabulary — do not conflate (see MEMORY):**
- A **Bookshelf** is one of the five named virtual collections (`antilibrary`, `library`, `wishlist`, `reading_pile`, `looking_for_home`) — table `op.bookshelves`, `Stacks.Shelving.Bookshelf`. It is the *room* / *bookcase*.
- A **Shelf** is a single physical horizontal plank *inside* one bookcase — table `op.shelves`, `Stacks.Shelving.Shelf`. It is a *row*. This story is about **shelves**, the entity introduced by Issue #151.

**How they accomplish it:**
1. The user browses a bookshelf (US-1.2.1). The bookcase already renders as a stack of physical shelves (rows), each shelf carrying its own placements.
2. They add a new shelf to the bottom of the bookcase ("Add shelf").
3. They reorder shelves (drag the third shelf above the first) so the sequence matches how they want the room to read.
4. They move a book from one shelf to another within the same bookcase.
5. They delete a shelf they no longer want — but only once it has been emptied of books.

**Acceptance Criteria:**
- A bookshelf's shelves are returned in ascending `position` order, and both the shelf-list endpoint and the browse endpoint expose them.
- Creating a shelf appends it at the next free `position` (max + 1), scoped to the owning bookshelf.
- Reordering rewrites every shelf's `position` to match a caller-supplied ordering of shelf IDs, atomically, with no unique-constraint collision.
- A book can be moved to any shelf **belonging to the same bookshelf**; moving it to a shelf on a different bookshelf is rejected.
- A shelf may only be deleted when it holds no active (non-removed) placements.
- Every mutation verifies that the acting user owns the bookshelf/placement before touching data.

---

## Implementation Status

**This feature EXISTS in the codebase as of Issue #151** (`issues/complete/151-physical-shelf-entity.md`). Any older doc or memory note claiming "Shelf does not yet exist in the codebase" is **stale** — the `op.shelves` table, the `Stacks.Shelving.Shelf` schema, the full context API, the controllers, and shelf *rendering* in the SPA are all merged. What remains unbuilt is most of the shelf-*management* UI.

### Built — backend (complete, with tests)
- **Table `op.shelves`** — `apps/core/priv/repo/migrations/20260330130609_create_shelves.exs`. The migration also back-fills one position-0 shelf per existing bookshelf and adds a NOT-NULL `shelf_id` FK to `op.bookshelf_placements`.
- **Schema** `Stacks.Shelving.Shelf` — `apps/core/lib/stacks/gen/shelving/shelf.ex:14` (proto-generated; `belongs_to :bookshelf`, `has_many :placements`, `position`, `created_at`).
- **Context functions** in `apps/core/lib/stacks/shelving.ex`:
  - `list_shelves/1` — `shelving.ex:633`
  - `create_shelf/2` — `shelving.ex:642`
  - `delete_shelf/2` (empty-only guard) — `shelving.ex:662`
  - `reorder_shelves/3` — `shelving.ex:684`
  - `move_placement_to_shelf/3` — `shelving.ex:700`
  - `get_bookshelf_shelves/2` (shelves + preloaded active placements) — `shelving.ex:720`
- **Controllers** — `StacksWeb.ShelfController` (`apps/core/lib/stacks_web/controllers/shelf_controller.ex`, all four actions) and `StacksWeb.BookshelfPlacementController.move_to_shelf/2` (`bookshelf_placement_controller.ex:164`).
- **Routes** — `apps/core/lib/core_web/router.ex:192,195-198` (index/create/delete/reorder + `PUT /api/placements/:id/shelf`).
- **Read path wired through browse** — `BookshelfController.render_visible_bookshelf/5` returns `shelves: [...]` via `get_bookshelf_shelves/2` — `bookshelf_controller.ex:72-80`.
- **Tests** — `apps/core/test/stacks/shelving_shelf_test.exs` covers list/create/delete/reorder/move-to-shelf plus the "new placements get a shelf" invariant; `apps/core/test/stacks_web/shelf_controller_test.exs` covers the HTTP surface.

### Built — frontend (partial)
- **Shelf rendering** — `frontend/src/Page/Bookshelf.elm:319` (`viewShelf` → `div.bookcase__shelf[data-shelf-id]`), consuming `Types.Shelf` (`frontend/src/Types/Shelf.elm`) decoded from the browse response.
- **Create-shelf UI** — `AddShelf` / `ShelfAdded` msgs (`Page/Bookshelf.elm:110-111,170-193`), the `viewAddShelfButton` "Add shelf" control (`Page/Bookshelf.elm:329`), and `Api.addShelf` (`frontend/src/Api.elm:614`). This is the **only** management action exposed in the SPA.

### Missing — frontend management UI (the gap this story tracks)
The backend exposes four more mutations that the SPA does **not** surface. Verified absent from `frontend/src/` (no matching Msg, no `Api.elm` function):
- **Move a book onto a specific shelf** — no `MoveToShelf` msg, no `Api` call to `PUT /api/placements/:id/shelf`. A user cannot choose which shelf a book lands on. (Contrast US-1.6.1, which moves a book between *bookshelves* via `Components.ShelfMover`; there is no analogous *shelf* picker.)
- **Reorder shelves** — no drag/reorder msg, no `Api` call to `PUT /api/bookshelves/:name/shelves/reorder`.
- **Delete a shelf** — no `DeleteShelf` msg, no `Api` call to `DELETE /api/shelves/:id`, and no surfacing of the `422 shelf is not empty` sad path.
- **Rename a shelf** — **not implementable as built.** `op.shelves` has *no* `name` column (see schema below); shelves are ordered but anonymous. Renaming would require a schema/proto change and is out of scope until then. Older phrasing that implies "named shelves" refers to *bookshelves*, not shelves.

Sections 2–12 below describe the **full intended flow**, marking each step as built or gap.

---

## 2. UI Interaction Flow

### Happy Path
1. **View shelves.** User navigates to a bookshelf (e.g. `/library`). `Page.Bookshelf.init` fires `Api.getBookshelf "library" token ShelvesLoaded`; the response carries `shelves: [{id, position, placements}]`. On `ShelvesLoaded (Ok shelves)` each shelf renders as a `div.bookcase__shelf[data-shelf-id]` row, its placements grouped into spine rows. *(Built.)*
2. **Create a shelf.** User clicks "Add shelf" → `AddShelf` → `Api.addShelf config.apiName token ShelfAdded` (`POST …/shelves`). On `ShelfAdded (Ok shelf)` the new (empty) shelf is appended to `model.shelves` and a fresh plank appears at the bottom of the bookcase. *(Built.)*
3. **Reorder shelves.** *(Gap — intended.)* User drags a shelf to a new vertical position → an intended `ReorderShelves (List String)` msg fires `PUT …/shelves/reorder` with the new ID order. On success the local `shelves` list is re-sequenced to match.
4. **Move a book to another shelf.** *(Gap — intended.)* From the book detail overlay (ADR-005) or a shelf-to-shelf drag, the user picks a target shelf → an intended `MoveBookToShelf placementId shelfId` msg fires `PUT /api/placements/:id/shelf`. On success the placement is removed from its old shelf's list and appended to the target shelf's list.
5. **Delete a shelf.** *(Gap — intended.)* User empties a shelf (moves its books elsewhere), then clicks a delete control → intended `DeleteShelf shelfId` msg fires `DELETE /api/shelves/:id`. On success the shelf row is removed from `model.shelves`.

### Sad Paths
- **Delete a non-empty shelf**: API returns `422 {"error":"shelf is not empty"}` → intended UI shows "Move the books off this shelf before removing it." The user recovers by moving each book to another shelf (step 4), then retrying delete. *(Backend enforced via `shelf_has_active_placements?/1`; frontend surfacing is a gap.)*
- **Move a book to a shelf on a different bookcase**: API returns `422 {"error":"shelf belongs to a different bookshelf"}` (`{:error, :wrong_bookshelf}`) → intended UI rejects the drop and snaps the book back. Shelves are only ever offered within the current bookcase, so this is a defensive guard.
- **Reorder with a stale/foreign shelf ID**: if the submitted ID set is not exactly the bookshelf's current shelf IDs, API returns `422 {"error":"invalid shelf IDs"}` (`{:error, :invalid_ids}`) → intended UI reloads shelves from the server and abandons the drag.
- **Not the owner**: any mutation on a bookshelf/placement the user does not own returns `403 {"error":"forbidden"}` → intended UI shows a generic failure and leaves state unchanged.
- **Shelf not found on delete**: `404 {"error":"not found"}` (`{:error, :not_found}`) → intended UI drops the phantom shelf from local state.
- **No token / no bookshelf yet**: `AddShelf` with `model.token == Nothing` is a no-op (`Page/Bookshelf.elm:177`); `create` against a bookshelf that does not exist yet returns `404 {"error":"bookshelf not found"}`.

### Elm State Machine
- **Page module**: `Page.Bookshelf` (unified, config-driven — `libraryConfig` etc.).
- **Model fields involved**: `shelves : RemoteData Http.Error (List Shelf)`, `token : Maybe String`, `config : Config`, `viewMode : ShelfViewMode`. *(Intended additions for full management: a `pendingShelfOp`/drag field, plus per-op `RemoteData` for delete/reorder/move — none exist yet.)*
- **Msg flow (built)**: `init → ShelvesLoaded` (render); `AddShelf → ShelfAdded` (create).
- **Msg flow (intended)**: `ReorderShelves ids → ShelvesReordered`; `MoveBookToShelf pid sid → BookMovedToShelf`; `DeleteShelf sid → ShelfDeleted`.
- **RemoteData states**: `shelves`: `NotAsked` (no token) → `Loading` → `Success shelves` / `Failure err`.
- **OutMsg pattern**: `NavigateTo (BookDetail id)` on spine click; `SessionExpired` on 401; `NoOut` for shelf ops.

---

## 3. API Calls

### `GET /api/bookshelves/:bookshelf_name/shelves`
- **Auth**: Required
- **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.ShelfController.index/2`
- **Request body**: N/A (GET)
- **Response (success)**: `{ shelves: [{ id, bookshelf_id, position, created_at, placements: [] }] }` — HTTP 200. (Note: `index` returns `placements: []` — a shelf skeleton; the *populated* shelves come from the browse endpoint below.)
- **Response (error)**: `{ error: "invalid bookshelf name" }` — HTTP 404. Unknown-but-valid bookshelf name (no row yet) returns `{ shelves: [] }` — HTTP 200.

### `GET /api/bookshelves/:bookshelf_name` (populated shelves, shared with US-1.2.1)
- **Controller**: `StacksWeb.BookshelfController.show/2` → `render_visible_bookshelf/5` (`bookshelf_controller.ex:68`)
- **Response (success)**: `{ bookshelf, count, shelves: [{ id, position, placements: [ …book… ] }] }` — HTTP 200, shelves ascending by `position`, each with visibility-filtered active placements.

### `POST /api/bookshelves/:bookshelf_name/shelves`
- **Auth**: Required — **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.ShelfController.create/2`
- **Request body**: N/A (position auto-assigned server-side)
- **Response (success)**: `{ shelf: { id, bookshelf_id, position, created_at, placements: [] } }` — HTTP 201
- **Response (error)**: `403 {"error":"forbidden"}` (not owner); `404 {"error":"bookshelf not found"}`; `404 {"error":"invalid bookshelf name"}`

### `PUT /api/bookshelves/:bookshelf_name/shelves/reorder`
- **Auth**: Required — **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.ShelfController.reorder/2`
- **Request body**: `{ shelf_ids: ["<uuid>", "<uuid>", …] }` — the complete set of the bookshelf's shelf IDs in the desired top-to-bottom order.
- **Response (success)**: `{ ok: true }` — HTTP 200
- **Response (error)**: `422 {"error":"shelf_ids is required"}` (missing/non-list); `422 {"error":"invalid shelf IDs"}` (set ≠ existing shelf IDs); `403 {"error":"forbidden"}`; `404 {"error":"bookshelf not found"}`

### `PUT /api/placements/:id/shelf`
- **Auth**: Required — **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.move_to_shelf/2` (`bookshelf_placement_controller.ex:164`)
- **Request body**: `{ shelf_id: "<uuid>" }`
- **Response (success)**: `{ placement: { …placement_ref… } }` — HTTP 200
- **Response (error)**: `422 {"error":"shelf_id is required"}`; `422 {"error":"shelf belongs to a different bookshelf"}`; `403 {"error":"forbidden"}`

### `DELETE /api/shelves/:id`
- **Auth**: Required — **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.ShelfController.delete/2`
- **Response (success)**: `{ ok: true }` — HTTP 200
- **Response (error)**: `422 {"error":"shelf is not empty"}`; `403 {"error":"forbidden"}`; `404 {"error":"not found"}`

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` → `AuthPipeline` (all shelf routes sit in the `:authenticated` block, `router.ex:184-199`). No `ViewAsPlug` on the mutation routes — shelf editing is always first-person.
- **Visibility checks**: N/A for mutations. On the browse read path, per-placement `Visibility.resolve_visibility/2` still applies inside `ProtoJSON.shelf_with_placements/2`.
- **Age gate**: N/A at the shelf-management level (enforced only at book detail).
- **Ownership checks** (the core guard for every mutation):
  - `create_shelf/2`, `reorder_shelves/3`: load `Bookshelf`, reject when `bookshelf.user_id != user_id` → `{:error, :unauthorized}` → 403.
  - `delete_shelf/2`: preload `shelf.bookshelf`, reject on `shelf.bookshelf.user_id != user_id` → 403 (checked *before* the empty check).
  - `move_placement_to_shelf/3`: preload `placement.bookshelf`, reject on `placement.bookshelf.user_id != user_id` → 403; then reject cross-bookcase moves via `shelf.bookshelf_id != placement.bookshelf_id` → `{:error, :wrong_bookshelf}` → 422.

---

## 5. Database Interactions

### Read: List shelves
- **Table(s)**: `op.shelves`
- **Query**: `Shelf |> where(bookshelf_id == ^id) |> order_by(:position) |> Repo.all()` — `shelving.ex:633`
- **Indexes used**: FK index on `bookshelf_id`; ordering served by the `(bookshelf_id, position)` unique index.
- **Schema module**: `Stacks.Shelving.Shelf`

### Read: Shelves with active placements (browse)
- **Table(s)**: `op.shelves` JOIN `op.bookshelves`, preload `op.bookshelf_placements`
- **Query**: `get_bookshelf_shelves/2` (`shelving.ex:720`) — inner-join to the owner's named bookshelf, ordered by `position`, preloading placements where `removed_at IS NULL`, ordered `[position, placed_at]`, with `book: [:author, :editions]`.

### Write: Create shelf
- **Table(s)**: `op.shelves` — **Operation**: INSERT
- **Position**: `shelf_max_position/1` (`MAX(position)`, or `-1` when empty) `+ 1` (`shelving.ex:651-654`).
- **Changeset**: `shelf_changeset/2` casts `[:bookshelf_id, :position, :created_at]`, requires `[:bookshelf_id, :position]`, and defaults `created_at` via `put_created_at/1`.
- **Constraints**: unique `(bookshelf_id, position)`.

### Write: Reorder shelves (transaction)
- **Table(s)**: `op.shelves` — **Operation**: bulk UPDATE `position`
- **Transaction**: Yes — `Repo.transaction` (`shelving.ex:778`). **Two-phase** to dodge the unique constraint: Phase 1 `update_all(inc: [position: n])` shifts every shelf out of the `0..n-1` range; Phase 2 `apply_shelf_positions/1` sets each shelf to its final 0-based index. Guarded by a `MapSet.equal?` check that the supplied IDs exactly match the bookshelf's existing shelf IDs, else `{:error, :invalid_ids}`.

### Write: Move placement to shelf
- **Table(s)**: `op.bookshelf_placements` — **Operation**: UPDATE `shelf_id`
- **Changeset**: `placement_changeset(placement, %{shelf_id: shelf_id})` (`shelving.ex:713`). No history row is written (contrast US-1.6.1's cross-*bookshelf* move, which writes `bookshelf_placement_history`). Intra-bookcase shelf moves are not journeyed.

### Write: Delete shelf
- **Table(s)**: `op.shelves` — **Operation**: DELETE (hard delete, `Repo.delete!`)
- **Guard**: `shelf_has_active_placements?/1` (`EXISTS` on placements with `shelf_id == id AND removed_at IS NULL`) blocks deletion of a non-empty shelf.
- **Cascade note**: the FK `bookshelf_placements.shelf_id` is `ON DELETE nilify_all` (migration line 45). The empty-only guard means an *active* placement never gets nilled, but a *removed* (soft-deleted) placement still pointing at the shelf would have its `shelf_id` set NULL on delete. There is **no reflow** of surviving books to a neighbour shelf — the intended model is "empty it first, then delete."

---

## 6. Event Flow & Lifecycle

### Events Emitted
**None, currently.** Unlike `place_book`, `move_book`, and `abandon_book` (which call `Events.emit_safe/1`), the shelf functions (`create_shelf/2`, `delete_shelf/2`, `reorder_shelves/3`, `move_placement_to_shelf/3`) emit **no** events — verified: no `Events.emit*` calls exist in the `shelving.ex` shelf section (lines 629–820).

- **Intended (future)**: `shelf.created`, `shelf.deleted`, `shelf.reordered`, `placement.shelved` (aggregate `shelf` / `placement`) would let feeds and dbt react to shelf structure changes. Not yet wired.

### Event Handlers Triggered
N/A today (no events). If added, `DbtRefreshHandler` would refresh `stg_shelves` / `stg_bookshelf_placements`.

---

## 7. Background Jobs (Oban)

N/A — no shelf operation enqueues a job today. (If shelf events are added later, `Stacks.Workers.DbtRefreshHandler` on the `:dbt_refresh` queue would be the consumer.)

---

## 8. External Service Calls

N/A — shelf organisation is purely internal (Postgres only).

---

## 9. Storage (R2 / Local)

N/A — no storage operations. Cover images on placed books are pre-stored URLs surfaced through the browse read path.

---

## 10. Cache Interactions

N/A — bookshelf/shelf listings are not cached (`BookDetailCache` serves individual book detail only). Every shelf mutation is reflected on the next browse straight from Postgres.

---

## 11. dbt Model Dependencies

- **Model**: `stg_shelves` (proto-generated staging model for `op.shelves`), alongside `stg_bookshelf_placements`.
- **Trigger**: today, only placement events (`placement.created`, `placement.moved`) drive `DbtRefreshHandler`; shelf structural changes do **not** trigger a refresh because they emit no events (see §6). Staging still reflects the current table state on the next scheduled/triggered refresh.
- **Materialisation**: view (staging).
- **Consumer**: downstream marts that reason about how users physically arrange collections (not yet a specific dashboard).

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Library` / `Route.AntiLibrary` / `Route.WishList` (config-driven `Page.Bookshelf`).
- **URL**: `/library`, `/antilibrary`, `/wishlist`, etc.
- **Pipeline**: Authenticated.

### Init
- **`initPage` branch**: bookshelf route → `Page.Bookshelf.init config maybeToken userId`.
- **API calls on init**: `Api.getBookshelf config.apiName token ShelvesLoaded` (returns populated shelves).
- **Initial model state**: `shelves = Loading`; empty 4-row bookcase renders immediately during load.

### Update cycle
**Built:**
- **Msg `ShelvesLoaded (Ok shelves)`**: `shelves → Success shelves`; `NoOut`.
- **Msg `ShelvesLoaded (Err _)`**: 403 → `showAgeGate = True`; 401 → `SessionExpired`; else `Failure`.
- **Msg `AddShelf`**: if `token == Just t`, fire `Api.addShelf`; else no-op.
- **Msg `ShelfAdded (Ok shelf)`**: append `shelf` to `Success shelves` (or seed `Success [shelf]`).
- **Msg `ShelfAdded (Err _)`**: no-op (silently ignored — a gap; no user-facing failure surfaced).

**Intended (gap — not implemented):**
- **Msg `MoveBookToShelf placementId shelfId`**: fire `PUT /api/placements/:id/shelf`; on success move the placement between shelf lists locally.
- **Msg `ReorderShelves ids`**: fire `PUT …/shelves/reorder`; on success re-sequence `shelves`; on `invalid_ids` reload.
- **Msg `DeleteShelf shelfId`**: fire `DELETE /api/shelves/:id`; on `not_empty` show the "empty it first" message; on success drop the row.

### View
- **Key elements**:
  - `viewShelf wearLevel shelf` → `div.bookcase__shelf[data-shelf-id]` per shelf (`Page/Bookshelf.elm:319`), placements grouped into spine rows.
  - `viewAddShelfButton` → `button.bookshelf__add-shelf` "Add shelf" (`Page/Bookshelf.elm:329`).
  - `minShelfRows 4` pads the bookcase to at least four planks so an empty room still reads as a bookcase.
  - *(Intended)*: per-shelf delete affordance, drag handles for reorder, and a shelf picker in the book detail overlay — none present.
- **ARIA attributes**: `aria-live="polite"` on the content region; spine buttons carry `role="listitem"`.
- **CSS classes** (E2E anchors): `bookcase`, `bookcase__shelf`, `shelf-row`, `shelf-row__books`, `shelf-row__plank`, `shelf-row__lip`, `bookshelf__add-shelf`, and the `data-shelf-id` attribute on each shelf.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/:name/shelves", method="POST"}` | Phoenix.Telemetry | Counter | Increment per create | N/A (baseline) |
| `http.response.status{endpoint="…/shelves/reorder", status=200}` | Phoenix.Telemetry | Counter | Increment per successful reorder | ≥ 98% of reorder requests |
| `http.response.status{endpoint="/api/placements/:id/shelf", status=422}` | Phoenix.Telemetry | Counter | Increment per rejected move (wrong bookshelf / missing param) | Informational |
| `http.response.status{endpoint="/api/shelves/:id", status=422}` | Phoenix.Telemetry | Counter | Increment per blocked non-empty delete | Informational (UX friction signal) |
| `db.query.duration{transaction="reorder_shelves"}` | Ecto.Telemetry | Histogram (ms) | Two-phase reorder transaction time | p95 < 40ms |
| `db.query.count{table="op.shelves", op="insert"}` | Ecto.Telemetry | Counter | Increment per create | 1 per successful create |
| `error.rate{scope="shelves"}` | Phoenix.Telemetry | Gauge (%) | 5xx / total over 5-min window | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `shelf.reorder_time` | Elm Performance API | Histogram (ms) | `ReorderShelves` msg → `ShelvesReordered (Ok _)` | p50 < 200ms, p95 < 500ms |
| `shelf.move_book_time` | Elm Performance API | Histogram (ms) | `MoveBookToShelf` → success | p50 < 200ms, p95 < 500ms |
| `shelf.delete_blocked_rate` | Elm event tracking | Gauge (%) | `422 not_empty` responses / total delete attempts | Informational (are users trying to delete full shelves?) |
| `user.shelves_per_bookcase` | API response | Gauge | `length(shelves)` per browse | Informational (capacity / layout) |
| `user.shelf_ops_per_session` | Elm event tracking | Counter | Increment per create/delete/reorder/move | Informational (engagement) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Shelf mutation volume | Small writes; reorder is the heaviest (bulk update inside a transaction). |
| Neon DB (PostgreSQL) | Compute Units per txn | Reorder transactions | Two `update_all` statements per reorder (shift + set); create/delete/move are single-statement. |
| Neon DB | Write IOPS | Position rewrites | Reorder rewrites `position` on every shelf of the bookcase; cost scales with shelves-per-bookcase (typically single digits). |
| Oban (background) | — | — | No jobs today (no shelf events). |

---

## 16. Cross-References

- **Issue #151** (complete): `issues/complete/151-physical-shelf-entity.md` — introduced the `Shelf` entity between `Bookshelf` (named collection) and `Placement` (book-on-shelf); the browse API returns `shelves: [{id, position, placements}]` rather than a flat placement list. **This is the source of the built backend and the record-correction that "shelves now exist."**
- **US-1.2.1** [Browse the Library Bookshelf](US-1.2.1-browse-library.md) — the read path that renders shelves as rows; this story adds the *management* of those rows.
- **US-1.6.1** [Move a Book Between Bookshelves](US-1.6.1-move-book.md) — moves a book across *bookshelves* (writes `PlacementHistory`, emits `placement.moved`). Distinct from moving a book across *shelves* within one bookcase (this story: no history, no event).
- **ADR-005** [Book Detail as Overlay](../decisions/005-book-detail-overlay-not-route.md) — the natural host for an intended per-book shelf picker.
- **Terminology**: MEMORY.md — "Bookshelf vs Shelf." Older lines stating "Shelf ... does NOT yet exist in the codebase" are **stale** as of #151.
