# US-1.6.5 — Empty Shelf States

## 1. User Story

> **As a** user, **I want to** see an inviting empty state when a shelf has no books **so that** I feel encouraged to add books rather than confused by a blank screen.

**What the user wants to accomplish:** Understand that an empty shelf is normal (especially when they're just starting out) and know how to add their first book.

**How they accomplish it:**
This is automatic -- no user action. The system renders an empty state when a shelf has zero active placements.

**What they see on the page:**
- **Library (empty):** "Your library is waiting. Move a book here when you've finished reading it."
- **AntiLibrary (empty):** "Books you own but haven't read yet. Upload a photo to start building your collection."
- **WishList (empty):** "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
- **Reading Pile (empty):** "Nothing on the pile right now. Move a book from your Antilibrary to start reading."
- **Looking for Home (empty):** "Nothing here yet -- these are books looking for a new home."

**Acceptance Criteria:**
- Each shelf has a unique, contextual empty state message.
- Empty bookshelves (Library, AntiLibrary, WishList) render inside a bookcase with empty shelf rows.
- Reading Pile empty state shows the armchair scene with message text.
- Looking for Home empty state uses the `Components.EmptyBookshelf` component.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to a shelf with no active placements.
2. API returns `{ bookshelf: "...", count: 0, placements: [] }`.
3. `BooksLoaded (Ok [])` -> `books = Success []` -> `List.isEmpty placements == True`.
4. Empty state view renders.

### Sad Paths
N/A -- empty state is the happy path for a new user.

### Elm State Machine
- **Page module**: `Page.Bookshelf` (Library, AntiLibrary, WishList), `Page.Bookshelf.ReadingPile`, `Page.Bookshelf.LookingForHome`
- **Model fields involved**: `books : RemoteData Http.Error (List Placement)`, `config : Config`
- **Msg flow**: `BooksLoaded (Ok [])` -> `Success []` -> empty state renders
- **RemoteData states**: `Success []` triggers the empty state branch
- **OutMsg pattern**: N/A

---

## 3. API Calls

Same as the respective browse stories (US-1.2.1 through US-1.2.4). The API returns `count: 0, placements: []` for empty bookshelves. If the bookshelf row does not exist yet in `op.bookshelves`, the controller returns `{ bookshelf: "...", count: 0, placements: [] }` without creating the row.

---

## 4. Auth & Middleware Guards

Same as the respective browse stories.

---

## 5. Database Interactions

### Read: Bookshelf lookup
- **Table(s)**: `op.bookshelves`
- **Query**: `Bookshelf |> where([b], b.user_id == ^user_id and b.name == ^bookshelf_name) |> preload(:user)` via `Shelving.get_bookshelf/2`
- **Result**: Returns `nil` if bookshelf row does not exist (new user who hasn't placed any books).
- **Controller handling**: When `nil`, controller returns `%{bookshelf: bookshelf_name, count: 0, placements: []}` directly without querying placements.

### Read: Empty placements query
If bookshelf exists, `Shelving.get_bookshelf_books/2` returns `[]` -- the query runs but finds no rows matching `is_nil(removed_at)`.

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- empty state is a read-only view.

### Event Handlers Triggered
N/A

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
Empty states render on the same routes as their non-empty counterparts:
- `/library`, `/antilibrary`, `/wishlist`, `/reading-pile`, `/looking-for-home`

### Init
Same as respective browse stories. The API call fires and returns an empty placements list.

### Empty state rendering per shelf

#### Library, AntiLibrary, WishList (`Page.Bookshelf`)
When `books = Success placements` and `List.isEmpty placements`:
```elm
viewEmptyBookshelf model =
    div [ class "bookshelf" ]
        [ viewBookcase
            (minShelfRows 4 [ viewEmptyShelfMessage model.config.emptyMessage ])
        ]
```
- The empty bookcase renders with the bookcase frame (side panels and inner area).
- A single `shelf-row--empty` contains the message text.
- 3 additional empty shelf rows are appended via `minShelfRows 4` to fill the bookcase.

Empty messages per config:
| Shelf | `config.emptyMessage` |
|-------|-----------------------|
| Library | "Your library is waiting. Move a book here when you've finished reading it." |
| AntiLibrary | "Books you own but haven't read yet. Upload a photo to start building your collection." |
| WishList | "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN." |

#### Reading Pile (`Page.Bookshelf.ReadingPile`)
When `books = Success placements` and `List.isEmpty placements`:
```elm
div [ class "reading-pile__empty-msg" ]
    [ text "Nothing on the pile right now. Move a book from your Antilibrary to start reading." ]
```
- The armchair and floor still render (decorative scene).
- The empty message appears in the chair area where the book pile would be.

#### Looking for Home (`Page.Bookshelf.LookingForHome`)
When `books = Success placements` and `List.isEmpty placements`:
```elm
emptyBookshelf
    { bookshelf = "looking_for_home"
    , message = "Nothing here yet -- these are books looking for a new home."
    }
```
- Uses `Components.EmptyBookshelf.emptyBookshelf` component.

### Update cycle
No update cycle specific to empty states. The empty state is purely a view concern.

### View
- **Key elements (shelf bookshelves)**:
  - `div.bookshelf` > `viewBookcase` > `div.bookcase` with side panels
  - `div.shelf-row.shelf-row--empty` containing the message
  - `p.shelf-row__empty-text` with the empty message text
  - Additional `div.shelf-row.shelf-row--empty` rows (empty shelves with back, plank, lip but no books)
- **Key elements (Reading Pile)**:
  - `div.reading-pile__empty-msg` with the empty message
  - `div.armchair` with all sub-elements still rendered
- **Key elements (Looking for Home)**:
  - `Components.EmptyBookshelf` component output
- **ARIA attributes**: No explicit ARIA on empty states. The `aria-live="polite"` region on the content area ensures screen readers announce the empty message.
- **CSS classes**:
  - Shelf bookshelves: `bookshelf`, `bookcase`, `bookcase__side`, `bookcase__inner`, `shelf-row shelf-row--empty`, `shelf-row__back`, `shelf-row__books shelf-row__books--message`, `shelf-row__empty-text`, `shelf-row__plank`, `shelf-row__lip`
  - Reading Pile: `reading-pile__empty-msg`
  - Looking for Home: Component-specific classes from `Components.EmptyBookshelf`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/bookshelves/:name", method="GET", result="empty"}` | Phoenix.Telemetry | Counter | Increment per bookshelf request returning `count: 0` | Informational (new user funnel) |
| `http.response.status{endpoint="/api/bookshelves/:name", status=200, count=0}` | Phoenix.Telemetry | Counter | Increment per 200 response with empty placements | Informational |
| `db.query.count{table="op.bookshelves", op="select", result="nil"}` | Ecto.Telemetry | Counter | Increment when bookshelf row does not exist (new user) | Informational (new user detection) |
| `db.query.duration{table="op.bookshelves", op="select"}` | Ecto.Telemetry | Histogram (ms) | Bookshelf lookup time (fast path when nil -- no placements query needed) | p95 < 10ms |
| `error.rate{endpoint="/api/bookshelves/:name"}` | Phoenix.Telemetry | Gauge (%) | 5xx responses / total responses | < 0.1% |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `page.load_time{route, state="empty"}` | Elm Performance API | Histogram (ms) | Time from navigation to empty state rendering complete | p50 < 200ms, p95 < 500ms (faster than populated shelf -- no spine rendering) |
| `empty_shelf.render_time{shelf}` | Elm Performance API | Histogram (ms) | Time to render empty bookcase with 4 shelf rows + empty message | p95 < 30ms (minimal DOM) |
| `empty_shelf.view_rate{shelf}` | Elm event tracking | Gauge (%) | Percentage of shelf loads that result in empty state (`Success []`) | Informational (content health) |
| `empty_shelf.time_to_first_book{shelf}` | Server-side (event_log) | Histogram (days) | Time from first empty shelf view to first `placement.created` on that shelf | Informational (onboarding funnel) |
| `empty_shelf.bounce_rate{shelf}` | Elm event tracking | Gauge (%) | Percentage of empty shelf views where user navigates away without taking action | Informational (UX effectiveness of empty state messaging) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Number of empty shelf loads | Cheapest shelf load path: when bookshelf row is nil, controller returns immediately without querying placements. When bookshelf exists but has no placements, one additional query returns empty results. |
| Neon DB (PostgreSQL) | Compute Units (CU) per query | Bookshelf lookup (1 query) + optional empty placements query | New user (no bookshelf row): 1 query, immediate nil return. Existing user (bookshelf exists, no placements): 2 queries, both fast. |
| Neon DB (storage) | N/A | N/A | No data to store or retrieve beyond the bookshelf metadata lookup. |
| R2 presigned URLs | N/A | N/A | No cover images to display on empty shelves. |
