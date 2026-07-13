# US-1.6.6 — Track Reading Progress

## 1. User Story

> **As a** reader, **I want to** record how far I am through a book on my Reading Pile **so that** my shelf reflects where I actually am in the story, and reaching the final page invites me to log a completed read.

**What the user wants to accomplish:** Mark a book as *To Read*, *Reading*, *Finished*, or *Abandoned*, and — while reading — note the page they are on. The status and page should persist, surface on the book (a progress indicator on the Reading Pile card, the detail overlay, and eventually the spine), and, when the reader marks the book *Finished*, dovetail into recording a completed read (US-1.6.3) so the spine gathers its well-loved wear (US-1.3.2).

**How they accomplish it:**
1. On a book that sits on a readable bookshelf (Reading Pile, Library), the reader taps the reading-status badge to open an inline form.
2. They pick a status; if the status is *Reading*, a "current page" field appears.
3. They save. The system updates the placement, stamps `started_at` on the first transition to *Reading* and `finished_at` on the transition to *Finished*, emits the reading-lifecycle events, and returns the new progress.
4. The badge and progress text update in place ("Reading · p. 142 / 320").
5. Marking the book *Finished* offers to move it to the Library and record the read.

**What they see on the page:**
- A status badge with dark-academic colour coding (To Read / Reading / Finished / Abandoned).
- While *Reading*: a page-progress line, `p. {current} / {total}`, where `{total}` is the primary edition's page count.
- While *Finished*: a `Finished · {date}` line.

**Acceptance Criteria:**
- Updating progress persists `reading_status` and (when reading) `current_page` on the placement.
- First transition to `reading` stamps `started_at`; transition to `completed` stamps `finished_at` — neither is overwritten once set (`started_at`).
- `reading_status` is constrained to `to_read | reading | completed | abandoned`; `current_page` may not be negative.
- `placement.reading_started` emitted on the first *Reading* transition; `placement.reading_completed` emitted on the *Finished* transition.
- Ownership verified before any write; a non-owner is refused.
- The reader can see their status and page on the Reading Pile card and the detail overlay.

---

## Implementation Status

This is a **gap story**: the full server side is built and tested, but the reader-facing front end that would let anyone *set* or *see* progress in the running app is not wired up.

**Built (backend, end to end):**
- **Route** — `put "/placements/:id/progress", BookshelfPlacementController, :update_progress` (`apps/core/lib/core_web/router.ex:191`), inside the `:api` → `:authenticated` pipeline.
- **Controller** — `BookshelfPlacementController.update_progress/2` (`apps/core/lib/stacks_web/controllers/bookshelf_placement_controller.ex:132`). Pattern-matches a required `reading_status`, takes only `["reading_status", "current_page"]` from the body, delegates to the context, and serialises via `ProtoJSON.reading_progress/1`. Fallback clause returns 422 `"reading_status is required"` (`:157`).
- **Context** — `Shelving.update_reading_progress/3` (`apps/core/lib/stacks/shelving.ex:536`) → `do_update_reading_progress/2` (`:550`). Loads + preloads the placement's bookshelf, checks ownership, then runs an `Ecto.Multi` (update + emit events). Auto-stamps `started_at`/`finished_at` (`:567`–`:573`, `:623`–`:627`).
- **Changeset** — `reading_progress_changeset/2` (`apps/core/lib/stacks/shelving.ex:81`): `validate_required(:reading_status)`, `validate_inclusion(:reading_status, ~w(to_read reading completed abandoned))`, `validate_number(:current_page, greater_than_or_equal_to: 0)`.
- **Schema fields** on `op.bookshelf_placements` — `reading_status :string`, `current_page :integer`, `started_at :utc_datetime_usec`, `finished_at :utc_datetime_usec` (`apps/core/lib/stacks/gen/shelving/placement.ex:29`–`32`).
- **Migration** — `apps/core/priv/repo/migrations/20260322000001_add_reading_progress_to_placements.exs` adds the four columns (`reading_status` defaults to `'to_read'`, `NOT NULL`) plus CHECK constraints `reading_status_valid` and `current_page_non_negative`.
- **Serializer** — `ProtoJSON.reading_progress/1` (`apps/core/lib/stacks_web/proto_json.ex:545`) → `%{id, reading_status, current_page, started_at, finished_at}`.
- **Elm data model** — `Types.Placement` already carries `readingStatus : Maybe ReadingStatus` and `currentPage : Maybe Int`, decoded from the book-detail placement (`frontend/src/Types/Placement.elm:37`, `:186`–`187`).
- **Orphan component** — `Components.PlacementCard` (`frontend/src/Components/PlacementCard.elm`) is a *complete* progress UI (status badge, inline edit form, status `select`, current-page `input`, save/cancel, `p. X / Y` progress line, `Finished · date`) with a unit test (`frontend/tests/PlacementCardTest.elm`).

**Missing (front end + downstream wiring):**
- **No API client function.** `frontend/src/Api.elm` has `moveBook`, `removeBook`, etc. but **no** `updateProgress` — nothing in the SPA calls `PUT /api/placements/:id/progress`.
- **`PlacementCard` is never mounted.** It is imported only by its test — not by `Page.Bookshelf.ReadingPile`, `Page.BookDetail`, or any page. Its `ProgressUpdateRequested` OutMsg has no consumer. `ReadingPile.elm` renders no progress; `BookDetail.elm` has no progress UI.
- **No page-count ceiling.** Neither the changeset nor the DB constraint rejects `current_page` **above** the book's page count — only negatives are rejected. This validation must be added (see §5).
- **Reading-lifecycle events are unregistered.** `placement.reading_started` / `placement.reading_completed` are emitted but do **not** appear in `Stacks.Events.Registry` (`apps/core/lib/stacks/events/registry.ex` lists only `placement.created | moved | removed`). No handler fires — no dbt refresh, no feed update, no community-read increment results from progress today.
- **No "reached the end → record a read" bridge** to US-1.6.3.
- **`Shelving.list_in_progress/1`** (`apps/core/lib/stacks/shelving.ex:614`) exists but is exposed by no controller — there is no "currently reading" endpoint.

The intended full flow is described in §2–§15 below.

---

## 2. UI Interaction Flow

### Happy Path
1. Reader opens their Reading Pile (US-1.2.4) or a book detail overlay (US-1.4.1) for a book on a readable bookshelf.
2. Each book renders a `Components.PlacementCard` showing its status badge and (if reading) `p. {current} / {total}`.
3. Reader clicks the badge → `BadgeClicked` → `editing = True`; the inline edit form opens.
4. Reader selects a status from the dropdown → `StatusChanged` → `draftStatus` updates. Choosing "Reading" reveals the "Current page" number input.
5. Reader types a page → `PageChanged` → `draftPage` updates.
6. Reader clicks "Save" → `SaveClicked` → the card emits `ProgressUpdateRequested`; the parent page fires `Api.updateProgress placement.id draftStatus draftPage token ProgressSaved` (client function **to be built**). Request state → `Loading`.
7. API call: `PUT /api/placements/:id/progress` with `{ reading_status, current_page }`.
8. `ProgressSaved (Ok progress)` → the placement's `readingStatus` / `currentPage` / `finishedAt` update from the response; badge + progress line re-render; form closes.
9. If the new status is *Finished*, the page surfaces a gentle prompt: "Move to your Library and record this read?" linking into US-1.6.3.

### Sad Paths
- **Invalid page (beyond page count)**: reader enters a page greater than the edition's total → API returns 422 `{ errors: { current_page: [...] } }` → inline field error "That page is past the end of the book." → reader corrects it. *(Requires the ceiling validation in §5; today the server would accept it.)*
- **Negative page**: `current_page < 0` → 422 (DB `current_page_non_negative` + changeset `validate_number`) → same inline error treatment.
- **Invalid status**: a status outside the four allowed values → 422 `validate_inclusion` failure → generic "Couldn't save progress. Please try again."
- **Missing status**: request without `reading_status` → 422 `"reading_status is required"` (controller fallback clause).
- **Progress on a non-readable / non-existent placement**: a placement that cannot be found → 404 `"not found"`. (Reading status is a property of any placement, so there is no server-side "wrong bookshelf" refusal today; the front end should only surface the control on readable bookshelves — Reading Pile, Library.)
- **Not owner**: another user's placement → 403 `"forbidden"` → "You can only track your own reading."
- **Unauthenticated**: no/invalid token → `:authenticated` pipeline rejects with 401 before the controller runs.

### Elm State Machine
- **Component module**: `Components.PlacementCard` (built); host page `Page.Bookshelf.ReadingPile` and/or `Page.BookDetail` (**wiring to be built**).
- **Model fields involved**: `placement : Placement`, `editing : Bool`, `draftStatus : ReadingStatus`, `draftPage : String` (component); a `RemoteData Http.Error Progress` save state on the host page.
- **Msg flow**: `BadgeClicked → StatusChanged / PageChanged → SaveClicked → (OutMsg ProgressUpdateRequested) → Api.updateProgress → ProgressSaved`.
- **RemoteData states**: host save state `NotAsked → Loading → Success Progress / Failure err`.
- **OutMsg pattern**: `Components.PlacementCard` emits `ProgressUpdateRequested`; the host page performs the API call and folds the result back into its placement list.

---

## 3. API Calls

### `PUT /api/placements/:id/progress`
- **Auth**: Required
- **Pipeline**: `:api` → `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.update_progress/2`
- **Request body**: `{ reading_status: "to_read" | "reading" | "completed" | "abandoned", current_page: integer? }` — `reading_status` is required; only `reading_status` and `current_page` are read from the body (`Map.take/2`), so client-supplied `started_at` / `finished_at` are ignored (the server stamps them).
- **Response (success)**: `{ placement: { id, reading_status, current_page, started_at, finished_at } }` — HTTP 200 (via `ProtoJSON.reading_progress/1`).
- **Response (error)**:
  - `{ error: "reading_status is required" }` — HTTP 422 (fallback clause, missing status)
  - `{ errors: { current_page: [...], reading_status: [...] } }` — HTTP 422 (changeset: inclusion / non-negative / **page-count ceiling once added**)
  - `{ error: "not found" }` — HTTP 404 (no such placement)
  - `{ error: "forbidden" }` — HTTP 403 (not owner)
- **FallbackController handling**: `:unauthorized` → 403; `:not_found` → 404; changeset error → 422 via `format_errors/1`.

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` → `AuthPipeline` (`:authenticated`).
- **Visibility checks**: N/A — reading progress is an owner-only mutation, not a visibility read.
- **Age gate**: N/A.
- **Ownership checks**: `Shelving.update_reading_progress/3` loads the placement, preloads `:bookshelf`, and matches `%Placement{bookshelf: %Bookshelf{user_id: id}} when id != user_id -> {:error, :unauthorized}` (`apps/core/lib/stacks/shelving.ex:545`). A missing placement returns `{:error, :not_found}` before any ownership check.

---

## 5. Database Interactions

### Read: Load placement with bookshelf
- **Table(s)**: `op.bookshelf_placements` JOIN `op.bookshelves`
- **Query**: `Repo.get(Placement, placement_id) |> Repo.preload(:bookshelf)`
- **Schema module**: `Stacks.Shelving.Placement`

### Write: Update reading progress (Ecto.Multi step `:placement`)
- **Table(s)**: `op.bookshelf_placements`
- **Operation**: UPDATE `reading_status`, `current_page`, and — when the transition warrants — `started_at` / `finished_at`.
- **Changeset validations** (`reading_progress_changeset/2`): `validate_required(:reading_status)`; `validate_inclusion(:reading_status, ~w(to_read reading completed abandoned))`; `validate_number(:current_page, greater_than_or_equal_to: 0)`.
- **Auto-stamping**: `is_first_reading = reading_status == "reading" and is_nil(started_at)` → sets `started_at = now` (never overwrites an existing one); `is_completing = reading_status == "completed"` → sets `finished_at = now`.
- **DB constraints**: `reading_status_valid` CHECK (`in (to_read, reading, completed, abandoned)`); `current_page_non_negative` CHECK (`current_page >= 0`).
- **Transaction**: Yes — `Ecto.Multi` wraps the update and the event emission; `Repo.transaction/1`.

### Planned: page-count ceiling validation (**must build**)
- `current_page` must not exceed the book's primary-edition `page_count`. Because page count lives on the edition (not the placement), enforce it in the context by loading the edition and adding `validate_number(:current_page, less_than_or_equal_to: page_count)` (or a custom validation), returning a changeset error the front end can surface. There is **no** ceiling in the DB or changeset today.

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **Event type**: `placement.reading_started`
  - **Aggregate**: `placement` / `placement.id`
  - **Payload**: `%{book_id: placement.book_id}`
  - **Emitted by**: `Shelving.emit_reading_events/3` (`apps/core/lib/stacks/shelving.ex:588`) on the first `:reading` transition.
  - **Emission method**: `Events.emit_safe/1`
- **Event type**: `placement.reading_completed`
  - **Aggregate**: `placement` / `placement.id`
  - **Payload**: `%{book_id: placement.book_id}`
  - **Emitted by**: same function, on the `:completed` transition.
  - **Emission method**: `Events.emit_safe/1`

### Event Handlers Triggered
- **None currently.** `Stacks.Events.Registry` registers only `placement.created`, `placement.moved`, and `placement.removed` (`apps/core/lib/stacks/events/registry.ex:46`–`54`). `placement.reading_started` / `placement.reading_completed` are emitted with **no subscribers** — so no feed regeneration, no dbt refresh, and no community-read increment happen as a result of progress today.
- **Planned wiring**: register `placement.reading_completed` → `DbtRefreshHandler` (refresh reading-status staging) and, for the re-read/wear story (US-1.6.3, US-1.3.2), let completion feed the community-read count and spine wear. Register `placement.reading_started` if a "now reading" feed or activity surface is wanted.

---

## 7. Background Jobs (Oban)

- **None today** — because the reading-lifecycle events have no registered handlers, no jobs are enqueued.
- **Planned**: once `placement.reading_completed` is registered, a `DbtRefreshHandler` job on the `:dbt_refresh` queue would refresh `stg_bookshelf_placements` (reading-status columns) and any completion-driven marts.

---

## 8. External Service Calls

N/A.

---

## 9. Storage (R2 / Local)

N/A.

---

## 10. Cache Interactions

- No dedicated cache today. When `placement.reading_completed` is later wired to touch book-level derived data, the relevant `BookDetailCache` entry for the affected book should be invalidated so the detail overlay reflects the finished state on the next open.

---

## 11. dbt Model Dependencies

- **Model**: `stg_bookshelf_placements` — includes the `reading_status`, `current_page`, `started_at`, `finished_at` columns (proto-generated staging).
- **Trigger**: none today (events unregistered). **Planned**: `placement.reading_completed` via `DbtRefreshHandler`.
- **Materialisation**: view.
- **Consumer**: reading-journey and completion analytics; a future "currently reading" / "finished this year" mart. Community read counts (US-1.6.3) are driven by placement **history**, not by reading status directly — but completion is the natural point to record a read.

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A — progress is edited in place on the Reading Pile card or the book detail overlay; no URL change.

### Init
- On the Reading Pile, each placement becomes a `Components.PlacementCard.init placement`, seeding `draftStatus` from `readingStatus` (default `ToRead`) and `draftPage` from `currentPage`. Host save state initialises `NotAsked`.

### Update cycle
- **Msg `BadgeClicked`**: `editing = True`.
- **Msg `StatusChanged s`**: `draftStatus = readingStatusFromString s`.
- **Msg `PageChanged s`**: `draftPage = s`.
- **Msg `SaveClicked`**: `editing = False`; emits **OutMsg** `ProgressUpdateRequested`.
- **Msg `CancelClicked`**: `editing = False`; drafts reset to the placement's current values.
- **OutMsg `ProgressUpdateRequested`** (host page, **to build**): fire `Api.updateProgress` with `draftStatus` + parsed `draftPage`; on `Ok`, replace the card's placement with the returned progress and, if `Completed`, surface the "record a read" prompt (US-1.6.3); on `Err`, show an inline error.

### View
- **Key elements** (`Components.PlacementCard.view`): `viewStatusBadge` (button, `testId "reading-status-badge"`), `viewProgress` (`testId "reading-progress"` while reading, `testId "finished-at"` when finished), and `viewEditForm` (`testId "reading-status-form"`) with `testId "status-select"`, `testId "current-page-input"`, `testId "save-progress-btn"`, `testId "cancel-progress-btn"`.
- **ARIA attributes**: badge carries `aria-label="Reading status: {label}. Click to update."`. The current-page input should be a labelled `type="number"` (present).
- **CSS classes**: `placement-card`, `placement-card__badge` (+ `--to-read | --reading | --completed | --abandoned`), `placement-card__progress`, `placement-card__edit-form`, `placement-card__field`, `placement-card__select`, `placement-card__input`, `placement-card__actions`.
- **Planned spine indicator**: mirror progress onto the book's spine (US-1.3.2 engagement/wear neighbourhood) — a subtle fill or bookmark ribbon at `current_page / page_count` — so the shelf reads as a set of half-open books, not just badges.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/placements/:id/progress", method="PUT"}` | Phoenix.Telemetry | Counter | Increment per progress update | N/A (volume baseline) |
| `http.response.status{endpoint="/api/placements/:id/progress", status=200}` | Phoenix.Telemetry | Counter | Increment per successful update | >= 98% of requests |
| `http.response.status{endpoint="/api/placements/:id/progress", status=422}` | Phoenix.Telemetry | Counter | Increment per validation error (bad status / negative or over-count page) | Informational |
| `http.response.status{endpoint="/api/placements/:id/progress", status=403}` | Phoenix.Telemetry | Counter | Increment per ownership failure | Informational |
| `http.response.status{endpoint="/api/placements/:id/progress", status=404}` | Phoenix.Telemetry | Counter | Increment per missing placement | Informational |
| `db.query.count{table="op.bookshelf_placements", op="update"}` | Ecto.Telemetry | Counter | Increment per progress update | 1 per successful update |
| `db.query.duration{transaction="update_reading_progress"}` | Ecto.Telemetry | Histogram (ms) | Ecto.Multi time (update + emit) | p95 < 50ms |
| `event.emit.count{type="placement.reading_started"}` | Events module | Counter | Increment on first `reading` transition | 1 per book started |
| `event.emit.count{type="placement.reading_completed"}` | Events module | Counter | Increment on `completed` transition | 1 per book finished |
| `error.rate{endpoint="/api/placements/:id/progress"}` | Phoenix.Telemetry | Gauge (%) | 5xx / total responses | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `progress.update_time` | Elm Performance API | Histogram (ms) | Time from `SaveClicked` to `ProgressSaved (Ok _)` | p50 < 200ms, p95 < 500ms |
| `progress.pages_per_update` | Server-side | Histogram | Delta between successive `current_page` values | Informational (reading cadence) |
| `progress.completion_rate` | Server-side (reading_status) | Gauge (%) | Placements reaching `completed` / placements ever `reading` | Informational (finish-through) |
| `progress.abandon_rate` | Server-side (reading_status) | Gauge (%) | Placements reaching `abandoned` / placements ever `reading` | Informational (see US-1.6.2) |
| `progress.time_to_finish` | Server-side | Histogram (days) | `finished_at - started_at` per completed placement | Informational (reading pace) |
| `progress.update_failure_rate` | Elm event tracking | Gauge (%) | `ProgressSaved (Err _)` / total `SaveClicked` | < 2% |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of progress updates | Single Ecto.Multi transaction (load + preload, update, emit) — cheaper than a move; readers may update frequently while reading. |
| Neon DB (PostgreSQL) | Compute Units (CU) per transaction | Progress transactions | SELECT placement + preload bookshelf, UPDATE placement, INSERT event_log (0–2 rows). ~2–4 statements per update. |
| Neon DB (PostgreSQL) | Write IOPS | `event_log` inserts on start/finish transitions | Most page-bump updates emit no event (only status transitions do), so write amplification is low. |
| Oban (background) | CPU-ms per job | `DbtRefreshHandler` jobs (once `placement.reading_completed` is registered) | Zero today (events unregistered). Once wired, one refresh per completion. |
