# US-1.3.2 — Spine Wear by Engagement

## 1. User Story

> **As a** user, **I want** book spines to show wear based on my reading history **so that** my shelves tell the story of how I've engaged with each book.

**What the user wants to accomplish:** See visual evidence of their reading journey in the texture and condition of each spine.

**How they accomplish it:**
This is automatic -- wear state is determined by the book's shelf and reading history.

**What they see on the page:**
- **Pristine** (WishList): Sharp edges, clean texture, vibrant colours. Untouched.
- **Softened** (AntiLibrary): Slight softening of edges and corners. Owned, handled, but unread.
- **Cracking** (Reading Pile): Hairline cracks along the spine. The book is being actively bent open.
- **Well-read** (Library, read once): Rounded corners, slightly muted colours.
- **Well-loved** (Library, read multiple times): Creased spine, faded colour, dog-eared look.
- **Bookmarks/tabs** (any shelf, if user has written about it): Small coloured tabs or a bookmark ribbon.

**Acceptance Criteria:**
- Spine wear level varies by bookshelf context.
- Wear is visually distinct between Pristine and Softened states.
- ARIA labels include wear state information.

---

## 2. UI Interaction Flow

### Happy Path
1. Book data arrives from the API as part of a bookshelf listing.
2. The shelf page passes its `config.wearLevel` to `viewShelfRowClickable` (or `viewBookPile` for Reading Pile).
3. `Components.Spine.book` receives the `wearLevel` and renders the spine accordingly.
4. The ARIA label includes wear state information (e.g., ", well-loved" suffix for `Softened`).

### Sad Paths
N/A -- wear level is always deterministic from the shelf config.

### Elm State Machine
- **Page module**: `Components.Spine` (rendering) + `Page.Bookshelf` / `Page.Bookshelf.ReadingPile` (wear level source)
- **Model fields involved**: `Config.wearLevel : WearLevel` in `Page.Bookshelf`; hardcoded `Softened` in `ReadingPile`
- **Msg flow**: N/A -- wear is set at config time, not via user interaction
- **RemoteData states**: N/A
- **OutMsg pattern**: N/A

---

## 3. API Calls

### `GET /api/spine_data/:placement_id` (server-side wear calculation, not yet used by frontend)
The `Stacks.Shelving.spine_data/1` function provides server-side wear calculation based on move count from `PlacementHistory`:

| Move Count | Wear Level |
|-----------|-----------|
| 0 | `:new` |
| 1-2 | `:light` |
| 3-5 | `:moderate` |
| 6+ | `:heavy` |

Currently, the frontend uses a simpler per-shelf wear level from the config rather than the server-calculated per-book wear level.

---

## 4. Auth & Middleware Guards

N/A -- wear rendering is a client-side view concern.

---

## 5. Database Interactions

### Read: Server-side wear calculation (via `Shelving.spine_data/1`)
- **Table(s)**: `op.bookshelf_placements`, `op.bookshelf_placement_history`, `op.book_editions`
- **Query**: `PlacementHistory |> where([h], h.book_id == ^book_id) |> Repo.aggregate(:count, :id)` to get move count; then `compute_wear_level(move_count)`.
- **Indexes used**: FK index on `book_id` in `bookshelf_placement_history`
- **Schema module**: `Stacks.Shelving.PlacementHistory`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- rendering concern.

### Event Handlers Triggered
N/A -- wear level changes as a side effect of `placement.moved` events, but the wear rendering itself triggers nothing.

---

## 7. Background Jobs (Oban)

N/A

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

N/A

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A -- wear is applied on any shelf route.

### Init
N/A -- wear level comes from the shelf config or is hardcoded.

### WearLevel type
```elm
type WearLevel
    = Pristine
    | Softened
```

Currently only two levels are implemented in the Elm codebase. The user story describes five levels (Pristine, Softened, Cracking, Well-read, Well-loved), but the frontend currently maps them as:

| Shelf | Config `wearLevel` | User Story Intent |
|-------|--------------------|-------------------|
| WishList | `Pristine` | Pristine -- untouched |
| AntiLibrary | `Pristine` | Softened -- owned but unread |
| Reading Pile | `Softened` (hardcoded) | Cracking -- actively being read |
| Library | `Softened` | Well-read / Well-loved |

### Wear level per shelf (current implementation)

**`Page.Bookshelf` configs:**
- `libraryConfig.wearLevel = Softened`
- `antiLibraryConfig.wearLevel = Pristine`
- `wishListConfig.wearLevel = Pristine`

**`Page.Bookshelf.ReadingPile`:**
- Hardcoded `Softened` in `viewPiledBook`

### ARIA label wear suffix
In `Components.Spine.book`:
```elm
wearSuffix =
    case config.wearLevel of
        Pristine -> ""
        Softened -> ", well-loved"
```
The ARIA label reads: `"Book: [title] by [author], [pageCount] pages[wearSuffix]"`

### Server-side wear model (`Shelving.spine_data/1`)
Returns a map with:
- `placement_id` -- the placement UUID
- `formats` -- list of edition format labels
- `page_count` -- from primary edition
- `move_count` -- number of PlacementHistory records for the book
- `wear_level` -- `:new`, `:light`, `:moderate`, or `:heavy`

This server-side model is richer than the current frontend model and could be used in future to drive per-book wear rather than per-shelf wear.

### Texture system
The wear level does not currently modify the texture rendering. Both `Pristine` and `Softened` render identically in terms of colours and textures. The visual differentiation described in the user story (rounded corners, muted colours, creases) would be implemented via CSS classes keyed on wear level -- this is a future enhancement.

### Update cycle
N/A -- pure rendering.

### View
- **Key elements**: Wear level is passed through the rendering chain: `Page.Bookshelf.view` -> `viewShelfRowClickable wearLevel BookClicked rows` -> `viewClickableSpine wearLevel onBookClicked placement` -> `Components.Spine.book { wearLevel = wearLevel, ... }`
- **ARIA attributes**: Wear state included in `aria-label` on each `.book` element.
- **CSS classes**: No wear-specific CSS classes are currently applied. The `book` class is the same regardless of wear level.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `spine_data.query.count` | Ecto.Telemetry | Counter | Increment per `Shelving.spine_data/1` call (server-side wear calculation) | Informational (not yet called by frontend) |
| `spine_data.query.duration` | Ecto.Telemetry | Histogram (ms) | Time to aggregate `PlacementHistory` count for wear level | p95 < 20ms |
| `db.query.count{table="op.bookshelf_placement_history", op="aggregate"}` | Ecto.Telemetry | Counter | Increment per move_count aggregation | Informational |

Note: In the current implementation, wear level is determined client-side from the shelf config (`Pristine` or `Softened`), not from server-side `spine_data/1`. The server-side metrics above will become active when per-book wear is wired to the frontend.

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `wear.render_time_per_book` | Elm Performance API | Histogram (microseconds) | Time to apply wear-level-specific rendering (currently a pattern match on `WearLevel`) | p95 < 100us per book (trivial in current implementation) |
| `wear.level_distribution{shelf}` | Elm rendering | Counter per level | Count of books rendered at each wear level per shelf | Informational (visual diversity) |
| `wear.server_level_distribution` | Server-side (`spine_data/1`) | Counter per level | Count of books at each server-calculated wear level (`:new`, `:light`, `:moderate`, `:heavy`) | Informational (future per-book wear) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | N/A (current) | N/A | Wear level is currently determined client-side from shelf config. No server cost. |
| Neon DB (PostgreSQL) | Compute Units per query (future) | Per-book `PlacementHistory` aggregation | When server-side `spine_data/1` is wired to the API, each book detail request would incur one `COUNT(*)` on `bookshelf_placement_history`. Indexed on `book_id`, so cost is minimal. |
| Browser CPU | Rendering cycles | Number of books on shelf | Wear-level CSS class application is O(1) per book. Future visual differentiation (rounded corners, muted colours) will add CSS filter/transform cost per book. |
