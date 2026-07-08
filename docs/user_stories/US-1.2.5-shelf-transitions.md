# US-1.2.5 — Bookshelf Navigation Transitions

## 1. User Story

> **As a** user, **I want** navigating between bookshelves to feel physical and spatial **so that** the experience of moving through my collection feels like walking between rooms.

**What the user wants to accomplish:** Experience seamless, immersive transitions between bookshelves that reinforce the physical-space metaphor.

**How they accomplish it:**
1. Clicking between adjacent bookshelf tabs (Library, AntiLibrary, WishList) triggers a horizontal slide transition -- the current bookshelf slides out and the next slides in, like turning in a room to face a different wall.
2. Clicking to the Reading Pile or Third Spaces triggers a fade through darkness -- the screen dims to near-black and the new space fades in, as if the user has walked down a hallway to a different room.
3. The transition duration is brief (300-500ms).

**What they see on the page:**
- Adjacent bookshelves: a smooth horizontal slide with a slight parallax effect on the wallpaper.
- Room transitions (Reading Pile, Third Spaces): a gentle fade to warm darkness, a beat of stillness, then the new space fades in from the centre outward.
- The top navigation remains fixed, with the active bookshelf tab subtly illuminated.

**Acceptance Criteria:**
- Horizontal slide for adjacent bookshelf navigation.
- Fade-through-darkness for room transitions (Reading Pile).
- Navigation bar remains fixed during transitions.
- Transition duration 300-500ms.

---

## 2. UI Interaction Flow

### Happy Path
1. User is on the Library bookshelf (`/library`).
2. User clicks "AntiLibrary" in the navigation.
3. `Main.elm` receives a URL change to `/antilibrary`.
4. The current `Page.Bookshelf` model is replaced by a new `Page.Bookshelf` model initialised with `antiLibraryConfig`.
5. CSS transition classes on the page wrapper drive the visual animation.
6. The new bookshelf loads its data independently via `Api.getBookshelf "antilibrary"`.

### Room Transition Path
1. User is on the Library bookshelf.
2. User clicks "Reading Pile" in the navigation.
3. Route changes to `/reading-pile`.
4. `Main.elm` replaces the `BookshelfPage` model with a `ReadingPilePage` model.
5. CSS transition class changes from `shelf-library` to `shelf-reading-pile`, triggering the fade-through-darkness animation.

### Sad Paths
- **Slow network**: The destination bookshelf renders its loading state (empty bookcase or "Loading...") during the transition. The transition animation is CSS-driven and does not wait for data.
- **Navigation during loading**: Navigating away before data arrives is safe -- the old model is discarded and the new init begins.

### Elm State Machine
- **Page module**: Transitions are handled in `Main.elm` via route changes, not within individual page modules.
- **Model fields involved**: The top-level `Main.Model` page union type switches between `BookshelfPage Model` and `ReadingPilePage Model` etc.
- **Msg flow**: `UrlChanged url` -> `Route.parse url` -> `initPage newRoute` -> old page model discarded, new page model + init Cmd installed.
- **RemoteData states**: Each destination page independently goes through its own `NotAsked` -> `Loading` -> `Success`/`Failure` cycle.
- **OutMsg pattern**: N/A -- transitions are route-driven, not OutMsg-driven.

---

## 3. API Calls

No dedicated API call for transitions. Each destination bookshelf triggers its own `GET /api/bookshelves/:bookshelf_name` on init (see US-1.2.1 through US-1.2.4).

---

## 4. Auth & Middleware Guards

N/A -- transitions are purely client-side UI. Auth is checked independently by each destination bookshelf's API call.

---

## 5. Database Interactions

N/A -- transitions are CSS animations. Database queries are handled by the destination bookshelf's init.

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A -- navigation transitions do not emit events.

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
- **Route variants involved**: `Route.Library`, `Route.AntiLibrary`, `Route.WishList`, `Route.ReadingPile`, `Route.LookingForHome`
- **URLs**: `/library`, `/antilibrary`, `/wishlist`, `/reading-pile`, `/looking-for-home`
- **Public or authenticated**: All authenticated (`:authenticated` pipeline)

### Init
- **`initPage` branch**: Each route variant triggers its own init function. The transition animation is a side effect of the CSS class changing on the page wrapper.
- **API calls on init**: Each destination fires its own `Api.getBookshelf` call.
- **Initial model state**: Each destination has its own initial model (see individual US-1.2.x stories).

### Transition types by route pair

| From | To | Transition Type | CSS Mechanism |
|------|----|----------------|---------------|
| Library | AntiLibrary | Horizontal slide | `themeClass` changes from `shelf-library` to `shelf-antilibrary` |
| Library | WishList | Horizontal slide | `themeClass` changes |
| AntiLibrary | WishList | Horizontal slide | `themeClass` changes |
| Any bookshelf | Reading Pile | Fade through darkness | Page type changes from `page--shelf` to `shelf-reading-pile` |
| Any bookshelf | Looking for Home | Fade through darkness | Page type changes |
| Reading Pile | Any bookshelf | Fade through darkness | Reverse room transition |

### Update cycle
- **Msg `UrlChanged url`**: Main.elm parses the new route, discards the current page model, calls `initPage` for the new route.
- **Model change**: `Main.Model.page` field switches to the new page variant.
- **Cmd**: New page's init Cmd (API call) is returned.
- **No OutMsg**: Transitions are driven by route changes, not by page OutMsgs.

### View
- **Key elements**: The `page` CSS class on the wrapper div carries both `page--shelf` (for shelf pages) or page-type-specific classes. CSS transitions are defined on these classes.
- **ARIA attributes**: N/A for transitions specifically.
- **CSS classes**: Transition animation classes are driven by the `themeClass` field in each `Page.Bookshelf` config (`shelf-library`, `shelf-antilibrary`, `shelf-wishlist`) plus the room-page classes `shelf-reading-pile` and `shelf-looking-for-home` (the latter two come from the separate Reading Pile and Looking For Home modules, not the unified `Page.Bookshelf` config). The wallpaper classes (`wallpaper--damask`, `wallpaper--botanical`, `wallpaper--floral`, `wallpaper--dragons`) also change, contributing to the parallax effect.

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `navigation.transition.count{from, to}` | Elm event tracking | Counter | Increment on each `UrlChanged` that triggers a bookshelf-to-bookshelf transition | Informational (navigation patterns) |
| `navigation.transition.type{type="slide"}` | Elm event tracking | Counter | Increment for adjacent-bookshelf horizontal slides | Informational |
| `navigation.transition.type{type="fade"}` | Elm event tracking | Counter | Increment for room transitions (fade through darkness) | Informational |

Note: Transitions are purely client-side CSS animations. No HTTP requests or database queries are executed by the transition itself. The destination bookshelf's API call metrics are captured in the respective browse story (US-1.2.1 through US-1.2.4).

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `transition.duration{type="slide"}` | CSS animation timing | Fixed (ms) | CSS `transition-duration` on `themeClass` change | 300-500ms (design spec) |
| `transition.duration{type="fade"}` | CSS animation timing | Fixed (ms) | CSS `transition-duration` on page type change | 300-500ms (design spec) |
| `navigation.frequency_per_session` | Elm event tracking | Counter per session | Count of `UrlChanged` msgs that trigger bookshelf transitions | Informational (engagement) |
| `page.time_on_shelf{shelf}` | Elm event tracking | Histogram (s) | Time between entering a bookshelf route and navigating away | Informational (dwell time) |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | N/A | N/A | Transitions are purely client-side CSS animations. No server-side cost. |
| Neon DB (PostgreSQL) | N/A | N/A | No database queries during transitions. Destination bookshelf queries are accounted for in their respective browse stories. |
| Browser CPU | Rendering cycles | Number of transitions per session | CSS transitions consume client-side GPU/CPU for animation compositing. Cost is borne by the user's browser, not the platform. |
