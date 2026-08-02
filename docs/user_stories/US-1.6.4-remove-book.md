# US-1.6.4 — Remove a Book from the Collection

## 1. User Story

> **As a** user, **I want to** permanently remove a book from my collection **so that** I can correct mistakes or declutter shelves without affecting other data.

**What the user wants to accomplish:** Get rid of a book that was added by mistake, or that they no longer want to track. This is different from moving between shelves -- this is removal.

**How they accomplish it:**
1. On the book detail overlay (see ADR-005), the user clicks "Remove from collection" (in a less prominent position -- danger zone).
2. A confirmation modal appears: "Are you sure you want to remove \"[Title]\" from your collection? You'll have a few seconds to undo it."
3. The user confirms.
4. The book's shelf placement is soft-deleted (`removed_at` set). The book record itself remains in the database.
5. The history of the book's journey is preserved in `bookshelf_placement_history`.
6. They land back on the shelf they came from, where a toast offers "Removed \"[Title]\" — Undo" for eight seconds (see §16).

**What they see on the page:**
- "Remove from collection" button styled as `btn--danger btn--sm`.
- Confirmation modal with "Keep It" (secondary) and "Remove" (danger) buttons.
- After removal, the overlay closes and navigates to the previous route.
- On arriving there, the undo toast (§16).

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
5. Modal shows: "Are you sure you want to remove \"[Title]\" from your collection? You'll have a few seconds to undo it."
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

Note: this used to say `placement.removed` is NOT registered with `DbtRefreshHandler`. It has been since #116 punch #14b -- `Stacks.Events.Registry` subscribes both `PlacementHandler` and `DbtRefreshHandler`, the latter mapped to `mart_community_read_count` (an incremental table, so a removal that did not trigger a refresh left a stale count). Corrected 2026-08-02 alongside the undo extension (§16).

---

## 7. Background Jobs (Oban)

`RegenerateFeedJob` (enqueued by `PlacementHandler`) and `DbtRefreshJob` for `mart_community_read_count` (enqueued by `DbtRefreshHandler`). Both are Oban jobs; see the correction in §6.

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
- **Trigger**: `placement.removed` -> `DbtRefreshHandler` -> `mart_community_read_count` (the gap this line described was closed by #116 punch #14b)
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
  - `p.modal__message` "Are you sure you want to remove \"[title]\" from your collection? You'll have a few seconds to undo it."
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
| Neon DB (PostgreSQL) | Write IOPS | Soft-delete update + event_log insert | Each removal updates 1 row (set `removed_at`) and inserts 1 row (event_log). An undo (§16) is a second UPDATE on the same row plus one more event_log insert -- no new rows either way. |
| Oban (background) | 2 jobs per removal | Remove operations | `RegenerateFeedJob` (RSS) + `DbtRefreshJob` for `mart_community_read_count`. An undo (§16) enqueues the same pair again. |

---

## 16. Undo Extension (#375, owner-ruled SPEC 2026-07-30)

> **As a** user who has just removed a book, **I want** a few seconds to take it
> back **so that** a mis-click does not cost me a placement I had annotated.

Written here rather than in a separate `US-1.6.4a` file so the story has **one
home**: an undo is not a feature of its own, it is the second half of removal,
and a reader deciding whether to press "Remove" needs both halves in front of
them. `docs/implementation-mapping.md` is edited in #320's single pass, not here.

### What changes for the reader

| Before | After |
|--------|-------|
| Modal warns "This cannot be undone." | Modal says "You'll have a few seconds to undo it." — the old line stopped being true |
| Removal is terminal (driven, epic #317 pre-check: ❌) | The shelf offers "Removed \"[Title]\" — Undo" for 8s |

### The rule that shapes everything else

**The undo restores the SAME placement row.** `POST /api/placements/:id/restore`
clears `removed_at` on the row `DELETE` stamped. It does not place the book
again.

That is not an implementation preference. A fresh placement gets a new UUID, so
`op.bookshelf_placement_history` no longer describes the placement on screen; a
fresh `placed_at`, so "on my shelf since March" becomes today; and default
`formats`, `personal_rating`, `notes`, `visibility`, `reading_status`,
`current_page`, `started_at`/`finished_at`, `book_edition_id`. An undo that
silently discards the reader's own annotations is not an undo. The row's
identity is asserted directly:
`ShelvingTest` → "restores the SAME row — same id, same placed_at, same annotations".

### The collision case — refused, not reconciled

`bookshelf_placements_book_active_idx` is `UNIQUE (book_id, bookshelf_id) WHERE
removed_at IS NULL`. If the reader re-added the same book to the same bookshelf
between the removal and the Undo, clearing `removed_at` would give that pair two
active rows.

**Decision: refuse with `409 already_shelved`.** The reader already has what undo
was going to give them — the book is on the shelf. Reconciling means choosing one
of the two rows to destroy, and every version of that choice deletes annotations
the reader entered without asking. A refusal costs nothing that is not already
recovered; the removed row stays exactly where it is, still exported by
`GDPR.Export` and still erased by `GDPR.Deletion`. The Elm copy says so plainly:
"That book is already back on your Library." — not an apology, because nothing
went wrong.

A re-add on a *different* bookshelf is not a collision (a book may legally sit on
several bookshelves — owner ruling 2026-07-30) and the undo proceeds.

### API

#### `POST /api/placements/:id/restore`
- **Auth**: Required. **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.restore/2`
- **Context**: `Stacks.Shelving.restore_placement/2`
- **200**: `{placement: {id, book_id, bookshelf_id, position, placed_at, removed_at}}` — `id` is the ORIGINAL placement id
- **409**: `{error: "already_shelved"}` — the collision above. Distinct from 422 on purpose: the request was well-formed and the caller did nothing wrong
- **403** `{error: "forbidden"}` · **404** `{error: "not found"}`
- **Idempotent**: restoring an already-active placement is a `200` no-op that emits nothing

### Events

`placement.restored` (v1, `book_id` + `bookshelf`), subscribed by
`Stacks.Feeds.Handlers.PlacementHandler` (the RSS feed regains an entry) and
`Stacks.Workers.DbtRefreshHandler` → `mart_community_read_count` (the read count
goes back up). Mapped to that one mart, matching `placement.removed` rather than
`placement.created`: `mart_platform_searchable` derives from
`int_book_detail_view`, which never references placements, so searchability was
never affected either way.

### Elm state machine (`Page.Bookshelf`)

`Main` carries the removal across the `Nav.pushUrl` that a removal provokes
(`Main.pendingUndo`, raised in the `BookDetail.NavigateTo` branches, consumed and
cleared by the very next `UrlChanged` via `Main.applyPendingUndo`), because the
shelf that shows the toast does not exist yet at the moment the removal is known.

`Bookshelf.UndoToast` is one type, not a `Maybe` + `Bool` + `Maybe String`:

    ToastHidden | ToastOffered Removal | ToastRestoring Removal | ToastFailed String

- `UndoRemove` acts on `ToastOffered` **and** `mutationToken model == Just token`
  — the #332 read-only guard, gone THROUGH rather than around. A read-only shelf
  yields `Nothing`, so the branch is not selectable at all.
- `ToastExpired` (from an uncancellable `Process.sleep undoToastMillis`, 8000ms)
  matches `ToastOffered` and nothing else, so a late timer cannot wipe a request
  in flight or a failure the reader still needs to read.
- `UndoCompleted (Ok ())` hides the toast and **refetches the bookshelf** rather
  than repainting the spine locally — `reloadShelves`' reason: the server decides
  which shelf row the restored placement lands on.

CSS: `.undo-toast`, `.undo-toast--failed`, `.undo-toast__message`,
`.undo-toast__action` (all present in `frontend/css/main.css`; `check-css.sh`
green, no orphan classes added).

### Deliberately NOT in scope

- **Reading Pile and Looking for a Home** are separate page modules
  (`Page.Bookshelf.ReadingPile`, `Page.Bookshelf.LookingForHome`) with their own
  models, so a removal that returns the reader to one of those shelves offers no
  toast. `Main.applyPendingUndo` falls through and the removal still stands —
  nothing is lost but the offer.
- **The per-placement remove in the multi-shelf notice** (`RemovePlacement`,
  #333) does not navigate away and is a different affordance — tidying up an
  extra copy, not leaving the collection. No toast.

### Validation

| Layer | Where |
|-------|-------|
| Context | `apps/core/test/stacks/shelving_test.exs` — `describe "restore_placement/2 — undo of a removal (#375)"` (11 tests: same-row identity, listing round-trip, 404/403, idempotence, collision refusal + no-announcement, different-bookshelf non-collision, event, audit, `placed_at` regression ×2) |
| API | `apps/core/test/stacks_web/bookshelf_placement_controller_test.exs` — `describe "POST /api/placements/:id/restore — restore"` (6 tests incl. the 409 and the same-id assertion) |
| Elm | `frontend/tests/Page/BookshelfUndoRemoveTest.elm` (13 tests, incl. `read_only_undo_is_inert_SECURITY` + `read_only_synthetic_undo_msg_SECURITY` and their positive control `owner_undo_is_observable`) |
