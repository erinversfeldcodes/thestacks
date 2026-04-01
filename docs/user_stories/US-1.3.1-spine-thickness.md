# US-1.3.1 — Spine Thickness by Page Count

## 1. User Story

> **As a** user, **I want** book spines to vary in thickness based on page count **so that** I can visually distinguish slim novellas from doorstop epics at a glance.

**What the user wants to accomplish:** Have their shelf look realistic, with visual weight corresponding to the actual size of each book.

**How they accomplish it:**
This is automatic -- no user action required. The system uses the book's page count metadata.

**What they see on the page:**
- Books under 200 pages have thin spines -- a sliver on the shelf.
- Books around 300-400 pages have a standard spine width.
- Books over 600 pages have thick, commanding spines that take up noticeable shelf space.
- The thickness scale is continuous, not stepped -- a 250-page book is visibly thinner than a 350-page book.

**Acceptance Criteria:**
- Spine width varies continuously based on page count.
- Minimum width: 35px. Maximum width: 55px.
- Formula: `max(35, min(55, round(pageCount / 12)))`.
- Default page count of 200 used when metadata is missing.

---

## 2. UI Interaction Flow

### Happy Path
1. Book data arrives from the API with `page_count` on the primary edition.
2. The `Components.Spine.spineWidth` function computes the pixel width from page count.
3. The spine renders at the computed width within the shelf row or book pile.

### Sad Paths
- **Missing page count**: `bookPageCount` returns `Nothing` -> helpers default to 200 pages -> `spineWidth 200 = max(35, min(55, round(200/12))) = max(35, min(55, 17)) = 35px` (minimum width).

### Elm State Machine
- **Page module**: `Components.Spine` (pure function, no state)
- **Model fields involved**: N/A -- `spineWidth` is a pure function of `pageCount : Int`
- **Msg flow**: N/A -- rendering is purely declarative, triggered during the view phase of any shelf page
- **RemoteData states**: N/A
- **OutMsg pattern**: N/A

---

## 3. API Calls

No dedicated API call. Page count is included in the bookshelf placement response as `primary_edition.page_count` (see US-1.2.x).

---

## 4. Auth & Middleware Guards

N/A -- spine rendering is a client-side view concern.

---

## 5. Database Interactions

### Read: Page count source
- **Table(s)**: `op.book_editions`
- **Query**: Page count is retrieved as part of the bookshelf placements query via `preload(book: [:author, :editions])`. The primary edition's `page_count` field is used.
- **Indexes used**: FK index on `book_id` in `book_editions`
- **Schema module**: `Stacks.Books.BookEdition`

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- rendering concern only.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A

---

## 8. External Service Calls

N/A -- page count is populated during book creation from Open Library / Google Books metadata.

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
N/A -- `Components.Spine` is a shared component used on all shelf pages and the Reading Pile.

### Init
N/A -- no state to initialise. `spineWidth` is a pure function.

### Core rendering functions

#### `spineWidth : Int -> Int`
```elm
spineWidth pageCount =
    max 35 (min 55 (round (toFloat pageCount / 12)))
```

**Behaviour:**
| Page Count | Width (px) | Visual |
|-----------|-----------|--------|
| 100 | 35 (clamped min) | Thin sliver |
| 200 | 35 (clamped min) | Thin sliver |
| 300 | 35 (clamped min) | Thin sliver |
| 420 | 35 | Standard min |
| 500 | 42 | Medium |
| 600 | 50 | Thick |
| 660+ | 55 (clamped max) | Maximum |

#### `spineHeight : Int -> Int`
Spine height also varies with page count:
```elm
spineHeight pageCount =
    let
        base = 238
        growth = min (toFloat pageCount / 750) 1 * 48
        jitter = modBy 8 (hash (String.fromInt pageCount))
    in
    round (toFloat base + growth) + jitter
```
Height ranges from ~238px (short books) to ~286px + jitter (long books).

#### `spineLean : String -> Float`
A slight tilt angle derived from the title hash:
```elm
spineLean titleStr =
    toFloat (modBy 16 (hash titleStr) - 8) / 10
```
Range: -0.8 to +0.7 degrees. Gives each book a unique, organic lean.

### Default page count handling
In `Page.Bookshelf.Helpers.groupIntoRows` and `viewSpine`/`viewClickableSpine`, missing page count defaults to 200:
```elm
pageCount = Maybe.withDefault 200 (bookPageCount bk)
```
This means unresolved books render at the minimum 35px width.

### Update cycle
N/A -- pure rendering, no update cycle.

### View
- **Key elements**: The `book` function in `Components.Spine` produces the full 3D structure: `.book > .book__spine + .book__top + .book__cover`. Width is set via inline `style "width" (String.fromInt widthPx ++ "px")`.
- **ARIA attributes**: `aria-label` on each `.book` includes page count: `"Book: [title] by [author], [pageCount] pages[, wearSuffix]"`
- **CSS classes**: `book`, `book__face`, `book__spine`, `book__top`, `book__cover`, `book__band` (for leather textures), `book__title`, `book__author`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `spine.page_count_missing{shelf}` | Elm rendering | Counter | Increment when `bookPageCount` returns `Nothing` and default of 200 is used | Informational (data quality indicator) |
| `spine.width_distribution{shelf}` | Elm rendering | Histogram (px) | Record computed `spineWidth` for each rendered book | Informational (visual diversity) |

Note: Spine thickness is a pure client-side rendering function (`Components.Spine.spineWidth`). No HTTP requests, database queries, or events are involved. The page count data arrives as part of the bookshelf placements API response (see US-1.2.x), so operational metrics for data retrieval are captured there.

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `spine.render_time_per_book` | Elm Performance API | Histogram (microseconds) | Time to compute `spineWidth`, `spineHeight`, `spineLean`, and render the 3D book element | p95 < 500us per book |
| `shelf.total_spine_render_time{shelf}` | Elm Performance API | Histogram (ms) | Aggregate rendering time for all spines on a shelf (book_count x per-spine cost) | p95 < 100ms for 200 books |
| `spine.default_page_count_rate` | Elm rendering | Gauge (%) | Percentage of books using the default 200-page fallback | < 10% (indicates good metadata coverage) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | N/A | N/A | Spine thickness is a pure client-side calculation. No server-side cost. |
| Neon DB (PostgreSQL) | N/A | N/A | Page count is retrieved as part of the bookshelf placements query (preloaded via `book: [:author, :editions]`). No additional queries. Cost is accounted for in the browse stories (US-1.2.x). |
| Browser CPU | Rendering cycles | Number of books on shelf | `spineWidth`, `spineHeight`, and `spineLean` are O(1) pure functions per book. Cost is trivial even for large shelves. |
