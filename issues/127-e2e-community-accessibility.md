# Issue #127: E2E Test Suite — Community Shelf & Accessibility

## Summary
Comprehensive E2E test coverage for the Looking for a Home shelf with marketplace exception (US-18.1.1), ARIA label coverage (US-19.1.1), keyboard navigation (US-19.1.2), and list view toggle (US-19.2.1).

## User Stories
US-18.1.1 (Browse the Looking for a Home Shelf), US-19.1.1 (ARIA Labels for Visual Elements), US-19.1.2 (Keyboard Navigation), US-19.2.1 (List View Toggle)

## Goal
Validate the Looking for a Home shelf rendering and marketplace integration, comprehensive ARIA label audit across all components, keyboard navigation with skip link and focus management, and the list view toggle with sortable columns.

## Scope Check
- Does this issue touch more than 3 controllers? No (BookshelfController for LFH; rest is frontend-only).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (LFH is the community shelf; accessibility applies to it and all other pages).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **LFH shelf render**: Navigate to `/looking-for-home` -> books displayed in `div.pile-view` with cover cards
- **LFH empty state**: No placements -> "Nothing here yet — these are books looking for a new home."
- **LFH age gate**: 403 response -> age gate overlay with "Verify Age" and "Dismiss" buttons
- **LFH loading state**: "Loading your books looking for a home..." message during load
- **LFH in nav**: "Looking for a Home" nav item between Reading Pile and Catalogue
- **LFH swipe**: Part of swipe navigation sequence (5th/last shelf)
- **Skip link**: Focus on page -> Tab -> skip link becomes visible at top
- **Skip link activation**: Tab to skip link -> Enter -> focus moves to `#main-content`
- **Focus indicators**: All focusable elements show amber outline on `focus-visible`
- **Book detail overlay focus**: Open overlay -> focus on close button; close -> focus returns to triggering spine
- **Escape key on overlay**: Overlay closes, focus returns to spine
- **Escape key on menu**: User menu closes
- **List view toggle**: Click "List view" button -> table renders with Title, Author, Pages, Date Added, Formats columns
- **Spine view toggle**: Click "Spine view" button -> visual spine bookshelf renders
- **Column sort**: Click column header -> sort ascending; click again -> descending
- **Sort indicators**: "^" for ascending, "v" for descending in header
- **Row click**: Click table row -> book detail overlay opens
- **Toggle keyboard**: Tab + Enter/Space activates view mode toggle

### 2. Playwright Navigation & Visual Tests
- **LFH auth guard**: Unauthenticated user at `/looking-for-home` sees login page
- **Toggle active state**: Active toggle button gets `view-mode-toggle__btn--active` class
- **Format badges**: Physical, eBook, Audiobook badges render in list view

### 3. API Endpoint Tests
- `GET /api/bookshelves/looking_for_home` — 200 with placements
- `GET /api/bookshelves/looking_for_home` — 401 without auth
- `GET /api/bookshelves/looking_for_home` — 403 for age-gated content
- `GET /api/bookshelves/looking_for_home` — supports `?view_as=<perspective>` query param
- N/A for ARIA, keyboard, list view (all frontend-only)

### 4. Database Assertion Tests
- LFH query: `bookshelf_placements` joined with `bookshelves` where `name == "looking_for_home"` and `removed_at IS NULL`
- Preloads: book data (title, author, page count, editions, subjects)
- N/A for ARIA, keyboard, list view

### 5. Event Flow Tests
- N/A — browsing LFH does not emit events
- N/A for ARIA, keyboard, list view

### 6. Background Job Tests
- N/A

### 7. External Service Tests
- N/A

### 8. Storage Tests
- N/A
- List view: view preference not currently persisted (resets on navigation)

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- `stg_bookshelf_placements` and `stg_bookshelves` staging models consume LFH data

### 11. Elm State Machine Tests
- **LFH**: `LookingForHome.init maybeToken` -> `{ books = Loading, showAgeGate = False }`, fires `Api.getBookshelf "looking_for_home"`
- `BooksLoaded (Ok placements)` -> `books = Success placements`
- `BooksLoaded (Err (Http.BadStatus 403))` -> `showAgeGate = True`
- `VerifyAge` -> OutMsg `NavigateTo SettingsAgeVerification`
- `DismissAgeGate` -> `showAgeGate = False`

**ARIA audit (existing implementations)**:
- `Components.Spine`: `aria-label` = `"Book: {title} by {author}, {pages} pages{wearSuffix}"`
- `Page.Login`: `role="tablist"`, `role="tab"`, `aria-selected`, `aria-required="true"`, `aria-live="polite"`
- `Components.UserMenu`: `aria-label="User menu"`, `aria-expanded`, `aria-haspopup="true"`
- `Components.OnboardingOverlay`: `role="dialog"`, `aria-modal="true"`, `aria-label="Welcome to The Stacks"`
- `Main.elm` nav: `aria-label="Main navigation"`
- `Main.elm` skip link: `a.skip-link[href="#main-content"]`
- `Page.Bookshelf`: `aria-live="polite"` on content wrapper
- `Components.BookList`: `role="table"`, `scope="col"`, `aria-sort`, `role="row"`
- `Components.ViewModeToggle`: `role="group"`, `aria-label="View mode"`, `aria-pressed`, `aria-label="Spine view"/"List view"`

**Keyboard navigation**:
- Global `onKeyDown` subscription for Escape key
- `EscapePressed` with overlay: close overlay, `Browser.Dom.focus ("spine-" ++ bookId)`
- `EscapePressed` without overlay: close user menu
- `openOverlay`: sets `triggerSpineId`, calls `Browser.Dom.focus "book-overlay-close"`
- `FocusResult` msg: no-op handler for focus result
- Focus indicators: `*:focus-visible { outline: 2px solid #d4a029 }`

**List view**:
- `ShelfViewMode = SpineView | ListView`
- `ViewModeToggle.view` renders two buttons with `aria-pressed`
- `BookList` sort: `SortState = { column : SortColumn, direction : SortDirection }`
- `SortColumn = Title | Author | PageCount | DateAdded | Formats`
- `sortPlacements` sorts by active column, reverses for Desc
- Default sort: Title ascending
- Click header: cycles sort direction
- Click row: fires `onBookClicked` handler
- Fallback: "Unknown Title" / "Unknown Author" for missing book data

### 12. Metrics & Telemetry Tests
- LFH page load rate, API success rate, age gate trigger rate
- Empty shelf rate, placement count distribution
- ARIA attribute coverage: automated axe-core/Lighthouse audit
- Missing ARIA label count target: zero
- Focus management success rate for overlay open/close
- Skip link usage rate
- Escape key event rate by context
- View mode distribution (Spine vs List)
- Toggle switch rate, sort usage rate
- Sort column distribution, sort direction preference
- List view book click rate
- Keyboard-only session rate (proxy metric)

## Reviewer Context
- LFH marketplace exception: placements with `listing_status: "active"` on `looking_for_home` shelf bypass visibility checks (they must be discoverable for marketplace).
- Spine ARIA labels only cover `Pristine` and `Softened` wear states — other wear states are missing.
- Focus trapping in overlays is NOT yet implemented — focus can Tab outside the overlay.
- Arrow key navigation within bookshelves is NOT implemented (spec gap).
- List view preference does NOT persist across navigation — resets to spine view.

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #127)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #127 covers four user stories — US-18.1.1 (Browse the
Looking for a Home Shelf), US-19.1.1 (ARIA Labels for Visual Elements),
US-19.1.2 (Keyboard Navigation), and US-19.2.1 (List View Toggle). The
matrix is therefore 13 layers × 4 US with happy/sad columns per cell.
US-18.1.1 is a full-stack shelf-browse story; US-19.x are frontend-only
accessibility stories whose only load-bearing layers are Layer 10 (Elm
state machine / component attributes) and Layer 12 (usability — where an
automated a11y audit and keyboard-flow E2E genuinely belong, per the
issue's DoD).

**Feature status:** every feature under audit IS implemented — this is not a
greenfield audit, it is a coverage baseline. Verified surface:
- `Page.Bookshelf.LookingForHome` (a **separate** Elm module from the
  unified `Page.Bookshelf`, alongside `Page.Bookshelf.ReadingPile`) with
  `init`/`BooksLoaded`/`VerifyAge`/`DismissAgeGate` and a `pile-view`.
- `StacksWeb.BookshelfController.show/2` serves `looking_for_home`; the
  marketplace visibility exception (`listing_status: "active"` punches
  through an `owner` profile ceiling) lives in `Stacks.Visibility`.
- ARIA: `Components.Spine` (`aria-label`), `Page.Login` (tablist/tab/
  aria-required/aria-live), `Components.UserMenu`, `Components.OnboardingOverlay`
  (`role="dialog"`), `Main.elm` nav (`aria-label="Main navigation"`) + skip
  link (`a.skip-link[href="#main-content"]`), `Page.Bookshelf` (`aria-live`),
  `Components.BookList` (`role="table"`/`aria-sort`/`role="row"`),
  `Components.ViewModeToggle` (`role="group"`/`aria-pressed`).
- Keyboard: `Main.elm` global `onKeyDown` → `EscapePressed`, overlay focus
  management (`Browser.Dom.focus "book-overlay-close"` on open, return to
  `"spine-" ++ bookId` on close), `FocusResult` no-op.
- List view: `Page.Bookshelf` wires `viewMode`/`sortState`, `ViewModeChanged`
  and `SortColumnClicked` (direction cycling), `BookList.view` with
  `sortPlacements` + "Unknown Title"/"Unknown Author" fallbacks.

The audit therefore records real (largely missing) test coverage against
implemented features, not "feature not built".

---

### Framework-layer summary

| Layer       | US-18.1.1 | US-19.1.1 (ARIA) | US-19.1.2 (Keyboard) | US-19.2.1 (List view) |
|-------------|-----------|------------------|----------------------|-----------------------|
| Elixir      | ⚠️ (generic bookshelf controller + strong LFH-specific `visibility_test` marketplace-exception tests; no LFH read/preload/`removed_at` test) | n/a — ARIA is pure frontend | n/a — keyboard is pure frontend | n/a — reuses loaded data, no server work |
| Elm unit    | ⚠️ (`RouteTest` + `SwipeTest` touch LFH routing/swipe only; page update cycle untested) | ⚠️ (`LoginRedesignTest` aria strong; Spine/UserMenu/Onboarding/Nav/BookList/ViewModeToggle aria untested) | ❌ (no `EscapePressed`/focus/skip-link test) | ❌ (no toggle/sort test; `ViewModeToggle`/`BookList` components untested) |
| Elm program | ❌ (no `LookingForHome` program/state-machine test) | ⚠️ (`LoginRedesignTest`, `BookDetailProgramTest` cover some aria) | ❌ | ❌ |
| Python      | n/a — vision service not involved | n/a | n/a | n/a |
| E2E         | ⚠️ (`looking-for-home.spec.ts`: 3 shallow tests — loads/title/content; no empty/age-gate/swipe) | ⚠️ (`bookshelf.spec` role=list/listitem/aria-label, `login.spec` aria, `book-interaction` role=dialog, `editions` aria-pressed; no Spine/UserMenu/Nav/skip aria) | ❌ (no skip/Escape/focus-return E2E) | ❌ (no view-mode toggle/sort E2E; `editions` aria-pressed is a *format* toggle, not view mode) |
| dbt         | ⚠️ (`stg_bookshelves`/`stg_bookshelf_placements` proto-generated generic tests; no `accepted_values` on name/`listing_status`, no `relationships`) | n/a | n/a | n/a |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/bookshelf_controller_test.exs` — generic bookshelf CRUD (200/401/404, view_as-halt 403, visibility gates, `looking_for_home` enumerated in "returns all valid bookshelf names")
- `apps/core/test/stacks/visibility_test.exs` — 3 LFH-specific marketplace-exception tests (active LFH → visible for platform / hidden for unauthenticated / library nil-status → hidden)
- `apps/core/test/stacks/shelving_test.exs` — "moves placement to looking_for_home bookshelf" (move, not read)
- `frontend/tests/RouteTest.elm` — `Route.LookingForHome` ↔ `/looking-for-home`
- `frontend/tests/SwipeTest.elm` — LFH in swipe sequence (5th shelf, wrap-around)
- `frontend/tests/UpdateTest.elm` — model carries `viewMode = SpineView` + `sortState`, but only Library age-gate Msgs are exercised
- `frontend/tests/Page/LoginRedesignTest.elm` — `ariaTests` (tablist/tab/aria-selected/aria-required/aria-live)
- `frontend/tests/Page/BookDetailProgramTest.elm` — `role="region"` sections
- `e2e/tests/looking-for-home.spec.ts` — 3 tests
- `e2e/tests/bookshelf.spec.ts` — role=list/listitem, shelf aria-label, decorative aria-hidden
- `e2e/tests/login.spec.ts` — aria-required, role=tablist/tab
- `e2e/tests/book-interaction.spec.ts` — clicking book opens `[role="dialog"]` overlay
- `e2e/tests/navigation.spec.ts` — "Looking for a Home" nav link present + navigates
- `e2e/tests/editions.spec.ts` — format toggle `aria-pressed`
- `e2e/tests/upload-pipeline.spec.ts` — `aria-live="polite"` status region (upload flow)
- `dbt/models/staging/schema.yml` — `stg_bookshelves` + `stg_bookshelf_placements` generic column tests

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **1** |
| ⚠️ shallow | **7** |
| ❌ missing | **10** |
| n/a (covered higher up / not applicable / by-design) | **86** |

104 cells total (13 layers × 4 US × happy/sad). This is the
pre-implementation baseline; Issue #127's DoD requires regenerating this
audit to 0 ❌ / 0 ⚠️ after the punch list lands.

---

### Full audit tables

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | ⚠️ `bookshelf_controller_test.exs` — "returns 200 with shelves when bookshelf has books" / "returns 200 with empty shelves when bookshelf has no books" exercise `GET /api/bookshelves/:bookshelf_name` generically; "returns all valid bookshelf names" enumerates `looking_for_home`; `visibility_test.exs` — "active looking_for_home placement with profile_visibility owner → :visible for platform user" is LFH-specific. BUT no controller test hits `looking_for_home` directly with placements+preloads, and the `?view_as=<perspective>` query param is only exercised against `library`, not LFH. | ⚠️ | ⚠️ `bookshelf_controller_test.exs` — "returns 401 when not authenticated", "returns 404 for invalid bookshelf name", "returns 403 when non-owner requests view_as perspective on another user's bookshelf" all cover the shared controller. BUT none target `looking_for_home`, and the LFH-specific 403 age-gate path (US §2 "Age Gate") has no controller test. | ⚠️ |
| 19.1.1 | n/a — ARIA labels are pure frontend presentation (US-19.1.1 §3). | | n/a — same. | |
| 19.1.2 | n/a — keyboard navigation is pure frontend behaviour (US-19.1.2 §3). | | n/a — same. | |
| 19.2.1 | n/a — list view reuses already-loaded placement data; no API call (US-19.2.1 §3). | | n/a — same. | |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | ⚠️ Auth pipeline (`:api` → `:authenticated` → `ViewAsPlug`) is exercised by every authenticated `bookshelf_controller_test.exs` happy path, and `visibility_test.exs` LFH marketplace-exception tests drive the `ViewAsPlug`/visibility resolution for `looking_for_home`. BUT the guard chain is never asserted with the `looking_for_home` name + a `?view_as=` perspective specifically. | ⚠️ | ⚠️ `bookshelf_controller_test.exs` — "returns 401 when not authenticated" (generic) + `visibility_test.exs` — "active looking_for_home placement … → :hidden for unauthenticated" gives real LFH unauth coverage. BUT the `view_as`-halt 403 is only tested for `library`, not LFH. | ⚠️ |
| 19.1.1 | n/a — no auth surface. | | n/a. | |
| 19.1.2 | n/a — no auth surface. | | n/a. | |
| 19.2.1 | n/a — same guards as the underlying bookshelf page (US-19.2.1 §4). | | n/a. | |

#### Layer 3: Database Interactions

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | ⚠️ `visibility_test.exs` LFH marketplace-exception tests assert the `resolve_visibility/2` DB path for `looking_for_home` placements (active-listing punch-through). `shelving_test.exs` — "moves placement to looking_for_home bookshelf" asserts the move write. BUT `Shelving.get_bookshelf_books/2` LFH **read** — the join across `op.bookshelf_placements`/`op.bookshelves`/`op.books`, the `removed_at IS NULL` filter, and the book/edition/subject preloads (US §5) — has no LFH-targeted test. | ⚠️ | ⚠️ `visibility_test.exs` — "library placement with nil listing_status … → :hidden" covers the hidden branch. BUT no test asserts that the LFH read excludes `removed_at IS NOT NULL` placements or another user's placements. | ⚠️ |
| 19.1.1 | n/a — no DB reads (US-19.1.1 §5). | | n/a. | |
| 19.1.2 | n/a — no DB reads. | | n/a. | |
| 19.2.1 | n/a — uses already-loaded data (US-19.2.1 §5). | | n/a. | |

#### Layer 4: Event Flow & Lifecycle

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — browsing the shelf emits no events (US §6); events fire on place/move, covered in the Shelving context. | n/a — same. |
| 19.1.1 | n/a — no events. | n/a. |
| 19.1.2 | n/a — no events. | n/a. |
| 19.2.1 | n/a — no events. | n/a. |

#### Layer 5: Background Jobs (Oban)

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — no Oban job in the browse path (US §7). | n/a. |
| 19.1.1 | n/a. | n/a. |
| 19.1.2 | n/a. | n/a. |
| 19.2.1 | n/a. | n/a. |

#### Layer 6: External Service Calls

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — no external calls (US §8). | n/a. |
| 19.1.1 | n/a. | n/a. |
| 19.1.2 | n/a. | n/a. |
| 19.2.1 | n/a. | n/a. |

#### Layer 7: Storage (R2 / Local)

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — no storage in the browse path (US §9). | n/a. |
| 19.1.1 | n/a. | n/a. |
| 19.1.2 | n/a. | n/a. |
| 19.2.1 | n/a — view preference is deliberately **not** persisted yet (US-19.2.1 §9 marks persistence future work); resets to spine view on navigation. | n/a. |

#### Layer 8: Cache Interactions

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — no cache in the LFH read path (US §10). | n/a. |
| 19.1.1 | n/a. | n/a. |
| 19.1.2 | n/a. | n/a. |
| 19.2.1 | n/a. | n/a. |

#### Layer 9: dbt Model Dependencies

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | ✅ `dbt/models/staging/stg_bookshelves.sql` and `stg_bookshelf_placements.sql` exist (proto-generated) and are the consumers named in US §11. `schema.yml` carries `not_null` + `unique` on `id`, `not_null` on `created_at`/`updated_at`, and `accepted_values` on `reading_status`. `op.bookshelves`/`op.bookshelf_placements` registered in `sources.yml`. | ✅ | ❌ No `accepted_values` on `stg_bookshelves.name` (would pin `looking_for_home` + the other four), no `accepted_values` on `stg_bookshelf_placements.listing_status` (draft/active/removed/expired/sold — the marketplace-exception discriminator), and no `relationships` tests (`bookshelf_placements.bookshelf_id → stg_bookshelves.id`, `book_id → stg_books.id`). Caveat: `schema.yml` is proto-generated by `mix proto.sync` — new tests must go through the proto manifest/generator or live as singular tests under `dbt/tests/`. | ❌ |
| 19.1.1 | n/a — ARIA has no data model (US-19.1.1 §11). | | n/a. | |
| 19.1.2 | n/a — keyboard nav has no data model. | | n/a. | |
| 19.2.1 | n/a — list view has no data model (US-19.2.1 §11). | | n/a. | |

#### Layer 10: Elm Frontend State Machine

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | ❌ `Page.Bookshelf.LookingForHome` is fully implemented but its update cycle is untested. `RouteTest.elm` asserts `Route.LookingForHome ↔ "/looking-for-home"` and `SwipeTest.elm` asserts LFH's place in the swipe sequence — real, but neither exercises `init` (→ `{ books = Loading, showAgeGate = False }` + fires `Api.getBookshelf "looking_for_home"`), `BooksLoaded (Ok placements) → Success`, or the empty-state render. No `frontend/tests/Page/LookingForHome*.elm` exists. | ❌ | ❌ No test for `BooksLoaded (Err (Http.BadStatus 403)) → showAgeGate = True`, `BooksLoaded (Err _) → Failure`, `VerifyAge → NavigateTo SettingsAgeVerification`, or `DismissAgeGate → showAgeGate = False`. `UpdateTest.elm` covers exactly these Msgs but for the **Library** page module, not `LookingForHome`. | ❌ |
| 19.1.1 | ⚠️ Real aria coverage exists for some components: `LoginRedesignTest.elm` (`role="tablist"`/`role="tab"`/`aria-selected`/`aria-required`/`aria-live`), `BookDetailProgramTest.elm` (`role="region"`). BUT the components the issue enumerates are mostly untested: `Components.Spine` `aria-label` (SpineTest/SpineBookTest assert dimensions/3D structure, never `aria-label`), `Components.UserMenu` (`aria-label`/`aria-expanded`/`aria-haspopup`), `Components.OnboardingOverlay` `role="dialog"`/`aria-modal` (`OnboardingOverlayTest` is state-machine only), `Main.elm` nav `aria-label="Main navigation"`, `Page.Bookshelf` content `aria-live="polite"`, `Components.BookList` `role="table"`/`aria-sort`/`role="row"`, `Components.ViewModeToggle` `role="group"`/`aria-pressed`/`aria-label`. | ⚠️ | n/a — ARIA attributes are static presentation with no runtime failure branch; the "missing" wear-state labels (only `Pristine`/`Softened`, US §2) are a documented feature gap, not a testable sad path. | |
| 19.1.2 | ❌ All keyboard behaviour in `Main.elm` is implemented but untested: the `onKeyDown → EscapePressed` subscription, `EscapePressed` with an open overlay (close + `Browser.Dom.focus ("spine-" ++ bookId)`), `openOverlay` focusing `"book-overlay-close"`, and the `FocusResult` no-op. No Elm test references `EscapePressed`, focus, or the skip link. | ❌ | ❌ No test for `EscapePressed` with **no** overlay (→ close user menu via `UserMenu.Close`) or for `FocusResult` handling a focus failure. | ❌ |
| 19.2.1 | ❌ `Page.Bookshelf` wires `ViewModeChanged` (sets `viewMode`), `SortColumnClicked` (cycles `Asc↔Desc`, default `Title Asc`), and `BookClicked`; `Components.BookList.sortPlacements` + `Components.ViewModeToggle` render `aria-pressed`/`--active`/`role="table"`/`aria-sort`/`role="row"`. None are tested — `UpdateTest.elm` only puts `viewMode = SpineView`/`sortState` in the model and never dispatches a toggle or sort Msg. No `ViewModeToggleTest`/`BookListTest` file exists. | ❌ | ❌ No test for the "Unknown Title"/"Unknown Author" fallback when a placement's `book` is `Nothing`, nor for sorting an empty/edge list. | ❌ |

#### Layer 11: Operational Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — LFH page-load rate / API success rate (US §13) are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics`) plus automatic Phoenix endpoint telemetry; no LFH-specific SLI is defined. | n/a — same. |
| 19.1.1 | n/a — ARIA coverage metric (US §13) is an automated-audit concern (axe-core/Lighthouse), captured at Layer 12, not a per-US firing test. | n/a. |
| 19.1.2 | n/a — keyboard-only session / skip-link usage (US §13) are client-side proxy metrics with no server telemetry to unit-test. | n/a. |
| 19.2.1 | n/a — view-mode distribution / sort usage (US §13) are dashboard analytics, not unit-testable per-US. | n/a. |

#### Layer 12: Performance & Usability Metrics

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 18.1.1 | n/a — LFH page-load p50/p95 (US §14) is an SLO-gate concern; in-test SLA bounds are an anti-pattern under variable CI timing. | | n/a — same. | |
| 19.1.1 | ❌ US-19.1.1 §14 and the Issue #127 DoD both require an **automated accessibility audit (axe-core) passing with zero critical violations** — there is no axe-core/Lighthouse integration in the E2E suite (no `axe` reference anywhere in `e2e/`). This is the one usability cell that is genuinely applicable rather than n/a. | ❌ | n/a — the audit *is* the pass/fail check; there is no separate sad path. | |
| 19.1.2 | ❌ The implemented keyboard flows (skip link becomes visible on focus then `Enter → #main-content`; `Escape` closes overlay/menu and returns focus to the trigger spine; `*:focus-visible` amber outline) have **no** Playwright coverage — `e2e/` contains no skip/Escape/focus-return test. Genuinely-applicable usability cell (Issue §1 "Skip link", "Escape key", "Focus indicators", "Book detail overlay focus"). | ❌ | n/a — arrow-key grid navigation and overlay focus-trapping are explicit **unimplemented** spec gaps (US-19.1.2 §2 "What Is Missing"); they belong to a new issue, not this baseline. | |
| 19.2.1 | ❌ Issue §1 requires E2E for the list-view toggle: click "List view" → table with Title/Author/Pages/Date Added/Formats columns, column-header sort asc/desc with `^`/`v` indicators, row-click → detail overlay, and Tab+Enter/Space activating the toggle. No such Playwright test exists (`editions.spec` `aria-pressed` is a **format** toggle, not the view-mode toggle). | ❌ | n/a — no sad usability path defined for the toggle. | |

#### Layer 13: Cost Tracking

| US | Happy Path | Sad Path |
|----|------------|----------|
| 18.1.1 | n/a — one DB read, no external services (US §15); ~$0.00, covered by the cost dashboard at deploy time. | n/a — same. |
| 19.1.1 | n/a — ARIA attributes are static HTML; $0.00 runtime (US §15). | n/a. |
| 19.1.2 | n/a — keyboard behaviour is client-side; $0.00 (US §15). | n/a. |
| 19.2.1 | n/a — list view/sort run in the browser on already-loaded data; $0.00 (US §15). | n/a. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-18.1.1 happy | `GET /api/bookshelves/looking_for_home` → 200 with placements + book preloads, and the `?view_as=<perspective>` param exercised against `looking_for_home` (not just `library`) | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 2 | L1 US-18.1.1 sad | LFH-targeted 401 (unauth), 403 (age-gated content), and 404 for `looking_for_home` specifically | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 3 | L2 US-18.1.1 happy | Assert the `:authenticated` + `ViewAsPlug` chain fires for the `looking_for_home` name with a `?view_as=` perspective | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 4 | L2 US-18.1.1 sad | Controller-level `view_as`-halt 403 for `looking_for_home` (complementing the existing `visibility_test` unauth-hidden coverage) | `apps/core/test/stacks_web/bookshelf_controller_test.exs` |
| 5 | L3 US-18.1.1 happy | `Shelving.get_bookshelf_books/2` LFH read: join + `removed_at IS NULL` filter + book/edition/subject preloads | `apps/core/test/stacks/shelving_test.exs` |
| 6 | L3 US-18.1.1 sad | LFH read excludes soft-removed placements and another user's placements | `apps/core/test/stacks/shelving_test.exs` |
| 7 | L9 US-18.1.1 sad | `accepted_values` on `stg_bookshelves.name` (five shelves incl. `looking_for_home`) + `stg_bookshelf_placements.listing_status`; `relationships` `bookshelf_id → stg_bookshelves.id`, `book_id → stg_books.id`. Must go via proto manifest/`mix proto.sync` or a singular test (schema.yml is proto-generated) | `dbt/tests/singular/` or proto-sync generator |
| 8 | L10 US-18.1.1 happy | `LookingForHome` state machine: `init` (→ `{ books = Loading, showAgeGate = False }`, fires `Api.getBookshelf "looking_for_home"`), `BooksLoaded (Ok _) → Success`, empty-state render | new `frontend/tests/Page/LookingForHomeTest.elm` (unit) and/or a program test |
| 9 | L10 US-18.1.1 sad | `BooksLoaded (Err 403) → showAgeGate`, `BooksLoaded (Err _) → Failure`, `VerifyAge → NavigateTo SettingsAgeVerification`, `DismissAgeGate → showAgeGate = False` | same new file(s) as #8 |
| 10 | E2E US-18.1.1 (L12-adjacent) | Playwright: LFH empty-state message ("Nothing here yet — these are books looking for a new home."), age-gate overlay ("Verify Age"/"Dismiss"), loading message, and LFH as the 5th shelf in swipe navigation | `e2e/tests/looking-for-home.spec.ts` |
| 11 | L10 US-19.1.1 happy | Component aria assertions: `Spine` `aria-label` ("Book: {title} by {author}, {pages} pages{wearSuffix}"), `UserMenu` (`aria-label`/`aria-expanded`/`aria-haspopup`), `OnboardingOverlay` `role="dialog"`/`aria-modal`, `Main.elm` nav `aria-label`, `Page.Bookshelf` `aria-live="polite"`, `BookList` `role="table"`/`aria-sort`/`role="row"`, `ViewModeToggle` `role="group"`/`aria-pressed`/`aria-label` | respective `frontend/tests/` files (`SpineBookTest.elm`, new `UserMenuTest.elm`, `OnboardingOverlayTest.elm`, `NavigationProgramTest.elm`, new `BookListTest.elm`/`ViewModeToggleTest.elm`) |
| 12 | L12 US-19.1.1 happy | Integrate an automated accessibility audit (axe-core via `@axe-core/playwright`) across key pages asserting **zero critical violations** (DoD requirement) | new `e2e/tests/accessibility.spec.ts` |
| 13 | L10 US-19.1.2 happy | Keyboard state machine: `onKeyDown → EscapePressed` subscription decode, `EscapePressed` with overlay (close + focus `"spine-" ++ bookId`), `openOverlay` focusing `"book-overlay-close"`, `FocusResult` no-op | new `frontend/tests/` keyboard/Main test (program test alongside `NavigationProgramTest.elm`) |
| 14 | L10 US-19.1.2 sad | `EscapePressed` with no overlay closes the user menu (`UserMenu.Close`); `FocusResult` tolerates a focus failure | same file as #13 |
| 15 | E2E US-19.1.2 (L12) | Playwright: skip link becomes visible on focus then `Enter` moves focus to `#main-content`; `Escape` closes the detail overlay/menu and returns focus to the trigger spine; `*:focus-visible` amber outline present on focusable elements | new `e2e/tests/accessibility.spec.ts` (or `keyboard-nav.spec.ts`) |
| 16 | L10 US-19.2.1 happy+sad | Component/state-machine tests: `ViewModeChanged` sets `viewMode`; `SortColumnClicked` cycles `Asc↔Desc` (default `Title Asc`); `sortPlacements` orders by active column; `BookClicked → onBookClicked`; `ViewModeToggle` `aria-pressed`/`--active` class; `BookList` `role`/`aria-sort` attributes; "Unknown Title"/"Unknown Author" fallback for `book = Nothing` | new `frontend/tests/Components/ViewModeToggleTest.elm` + `BookListTest.elm` (and/or a `Page.Bookshelf` program test) |
| 17 | E2E US-19.2.1 (L12) | Playwright list-view flow: click "List view" → `table` with Title/Author/Pages/Date Added/Formats columns; click column header → asc then desc with `^`/`v` indicators + `aria-sort`; click a row → detail overlay; Tab+Enter/Space activates the toggle; active button gets `view-mode-toggle__btn--active` | new `e2e/tests/list-view.spec.ts` (or extend `bookshelf.spec.ts`) |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 4-US matrix (104 cells):

- **1 ✅ STRONG** — the dbt happy path for US-18.1.1 (`stg_bookshelves` +
  `stg_bookshelf_placements` exist with generic column tests).
- **7 ⚠️ shallow** — US-18.1.1's server + generic-frontend coverage: API
  happy/sad, auth happy/sad, and DB happy/sad are all real but never
  exercise `looking_for_home` end-to-end (they lean on generic bookshelf
  tests plus the LFH-specific `visibility_test` marketplace exception);
  the dbt sad cell aside, plus US-19.1.1's Layer-10 aria coverage which is
  strong for Login/overlay but absent for Spine/UserMenu/Onboarding/Nav/
  BookList/ViewModeToggle.
- **10 ❌ missing** — the LFH page state machine (happy+sad), the LFH dbt
  constraint tests, the entire keyboard-nav layer (Elm happy+sad, E2E),
  the entire list-view layer (Elm happy+sad, E2E), and the two
  genuinely-applicable usability cells (axe-core a11y audit; keyboard-flow
  E2E).
- **86 n/a** — every backend layer for the three frontend-only
  accessibility stories, plus events/jobs/external/storage/cache/cost for
  US-18.1.1, each with an inline rationale.

**Headline findings:**
1. **`Page.Bookshelf.LookingForHome` — a separate module from unified
   `Page.Bookshelf` — has zero state-machine tests.** Its init, success,
   empty, age-gate (403), and navigation Msgs are all implemented and all
   untested; the only LFH Elm coverage is routing (`RouteTest`) and swipe
   order (`SwipeTest`). The LFH marketplace visibility exception, by
   contrast, is well covered server-side in `visibility_test.exs`.
2. **Accessibility is implemented but almost entirely unverified.** Spine
   `aria-label`, UserMenu, Onboarding dialog, nav label, skip link, Escape
   handling, and overlay focus-return all exist in code with **no** Elm or
   Playwright assertion, and there is **no axe-core audit** despite the DoD
   requiring "zero critical violations".
3. **The list-view toggle (US-19.2.1) is wired end-to-end yet untested at
   every layer** — no Elm test dispatches `ViewModeChanged`/`SortColumnClicked`
   and no Playwright test opens list view or sorts a column.

**Test runner totals at baseline (feature-relevant):** Elixir — 3
LFH-specific `visibility_test` tests + generic bookshelf-controller
coverage; Elm — `RouteTest`/`SwipeTest` (LFH routing/swipe) +
`LoginRedesignTest` aria + `BookDetailProgramTest` region roles, zero LFH
page / keyboard / list-view tests; Playwright — `looking-for-home.spec.ts`
(3), scattered aria assertions in `bookshelf`/`login`/`book-interaction`/
`editions`, zero skip/Escape/focus/view-mode tests; dbt — generic column
tests on the two bookshelf staging models. Punch list: **17 items**
(none blocked on feature work — every feature exists; these are pure
test gaps, except #12/#15 which introduce new tooling, axe-core).
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Automated accessibility audit (axe-core) passes with zero critical violations
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires LookingForHome page, BookshelfController, ARIA implementations across all components, SwipeNavigation module, BookList/ViewModeToggle components.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
