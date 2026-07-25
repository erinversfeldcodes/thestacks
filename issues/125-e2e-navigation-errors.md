# Issue #125: E2E Test Suite — Navigation & Error Handling

## Summary
Comprehensive E2E test coverage for home page (US-15.1.1), top navigation (US-15.2.1), swipe navigation (US-15.2.2), footer (US-15.3.1), 404 page (US-16.1.1), RemoteData error handling (US-16.2.1), and unauthenticated redirect (US-16.3.1).

## User Stories
US-15.1.1 (View the Home Page), US-15.2.1 (Navigate Between Sections via the Top Navigation Bar), US-15.2.2 (Swipe Navigation Between Bookshelves), US-15.3.1 (View the Platform Footer), US-16.1.1 (View the 404 Not Found Page), US-16.2.1 (Handle Network Failures Gracefully), US-16.3.1 (Handle Unauthenticated Access to Protected Pages)

## Goal
Validate the full navigation and error handling surface: home page render, authenticated vs unauthenticated nav, mobile swipe between shelves, footer, 404 for unknown routes, RemoteData pattern across all pages, and unauthenticated redirect to login.

## Scope Check
- Does this issue touch more than 3 controllers? No (tests only, mostly client-side).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all navigation/error UX).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

_Static trace re-verified 2026-07-25 (researcher-125). Line numbers per current `frontend/src/Main.elm` (3042 lines). Live-drive column is filled by Plan Phase 1._

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-15.1.1 — View the Home Page | `Route Home` → `initPage` (Main.elm:505) → `viewHome` (Main.elm:2979) — shipped CTAs are About `/about` + Marketplace `/marketplace` (#235) | ✅ `/` (unauth): `h1`="The Stacks", subtitle="Your personal collection, beautifully organised.", CTAs `a.btn--primary.home__link--about` "About The Stacks"→`/about` + `a.btn--secondary.home__link--marketplace` "Browse the Marketplace"→`/marketplace` (2026-07-25) | ✅ (doc reconciled) | Feature built + observed live; story doc `US-15.1.1` now reconciled to shipped CTAs (Phase 1). |
| US-15.2.1 — Navigate Between Sections via the Top Navigation Bar | `viewNav`/`navItem`/`navDropdown` (Main.elm:2702/2770) — exposed + unit-tested (`MainNavTest.elm`) | ✅ unauth nav = [Catalogue, Marketplace, Sign In] (About under brand dropdown); authed nav = 5 shelves (Library/Antilibrary/Wish List/Reading Pile/Looking for a Home) + Catalogue(Search, Add Book) + Marketplace(Create Listing→`/marketplace/create`, My Listings→`/marketplace/mine`) + user menu; `app-nav__item--active` on Library@`/library` (2026-07-25) | ✅ | — |
| US-15.2.2 — Swipe Navigation Between Bookshelves | `onSwipe` port (Main.elm:78) → `decodeSwipe` (:2519) → `SwipeReceived` (:2388) → `SwipeNavigation.swipeLeft/right` (modular wrap) | ✅ real `touchstart`/`touchend` (dx=-240) on `/library` → navigated to `/antilibrary`; same gesture on `/search` → no navigation (2026-07-25) | ✅ | wiring untested — punch item |
| US-15.3.1 — View the Platform Footer | `viewFooter` (Main.elm:3037) on every page | ✅ `footer.app-footer` "The Stacks — open source book management" present on `/`, `/library` (authed), and `/404` (2026-07-25) | ✅ | zero test coverage — punch item |
| US-16.1.1 — View the 404 Not Found Page | `Route.fromUrl` → `withDefault NotFound` → `viewNotFound` (Main.elm:3028); `pageTitle NotFound` (:2572) | ✅ `/nonexistent-page-xyz` → `document.title`="Not Found — The Stacks", `h1`="Page Not Found", explanation "The page you're looking for doesn't exist.", "Go Home"→`/`, nav + footer visible (2026-07-25) | ✅ | render untested — punch item |
| US-16.2.1 — Handle Network Failures Gracefully | RemoteData pattern + per-status Login messages (`LoginProgramTest.elm` asserts 422/403/423/503/401) | ✅ login wrong-pw → "The door remains shut. Invalid credentials." + email/password RETAINED; settings password wrong-current → 422 "Current password is incorrect." + all 3 fields RETAINED — **form preservation WORKS** (no gap) (2026-07-25) | ✅ | form-input preservation VERIFIED live (login + settings/password); no clearing-on-failure gap found |
| US-16.3.1 — Handle Unauthenticated Access to Protected Pages | `requiresAuth` (Main.elm:441) + `initPage` guard (:505) render Login at protected URL; PLUS global session-expiry interceptor (#173/#178, Main.elm:857-920) | ✅ `/library` unauth → login form renders, URL stays `/library` (not `/login`); post-login → `/antilibrary`. Interceptor: bookshelf-load 401 (revoked token) → redirect `/login` + `session-expired-notice`; settings-save 401 → inline error, NOT interceptor (2026-07-25) | ✅ (exceeds story) | story doc "no global 401 handler" note updated (Phase 1). Nuance: interceptor covers page-load 401s, not settings-save 401s |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### 1. Playwright UI Tests
- **Home page unauthenticated**: Navigate to `/` -> see "The Stacks" title, subtitle, action buttons
- **Home page buttons**: "About The Stacks" (`/about`) and "Browse the Marketplace" (`/marketplace`) links present with correct hrefs _(corrected 2026-07-25 — #235 replaced the old "View Antilibrary"/"Add a Book" CTAs)_
- **Top nav authenticated**: Full nav items: Library, Antilibrary, Wish List, Reading Pile, Looking for a Home, Catalogue dropdown, Marketplace dropdown, user display name
- **Top nav unauthenticated**: Only Catalogue, Marketplace, Sign In
- **Brand dropdown**: "The Stacks" logo links to `/`; single About sub-item → `/about` _(corrected 2026-07-25 — Costs removed as a nav item by #235)_
- **Catalogue dropdown**: Sub-items Catalogue, Search, Add Book
- **Marketplace dropdown**: Sub-items Marketplace, Create Listing, My Listings
- **Admin dropdown (owner only)**: Sources, Scrapers, Book Moderation _(corrected 2026-07-25 — in-app Metrics removed by #267; `Metrics` is now a public route)_
- **Active nav item**: `app-nav__item--active` class on current page
- **Footer on every page**: `<footer class="app-footer">` with tagline renders on all pages
- **404 page**: Navigate to `/nonexistent-page` -> "Page Not Found" heading, explanation, "Go Home" button
- **404 nav and footer**: Navigation bar and footer still visible on 404
- **Browser tab title**: "Not Found — The Stacks" on 404 page
- **Network error messages**: Specific error messages per status code (401, 409, 422, NetworkError, Timeout)
- **Form input preservation**: After submission failure, form fields retain values
- **Protected page redirect**: Unauthenticated user at `/library` sees login form
- **Post-login redirect**: After auth, user goes to `/antilibrary`

### 2. Playwright Navigation & Visual Tests
- **Swipe navigation**: Simulate swipe left/right on bookshelf pages -> navigates to next/previous shelf
- **Swipe sequence**: Library -> AntiLibrary -> WishList -> ReadingPile -> LookingForHome (wraps)
- **Swipe on non-bookshelf**: Swipe ignored on Search, Upload, Settings pages
- **Dropdown interactions**: Click dropdown trigger -> sub-items appear; click outside -> closes
- **Mobile settings dropdown**: `<select>` navigation on mobile screen widths

### 3. API Endpoint Tests
- N/A for home page, nav, footer, 404, swipe (all client-side)
- Server-side 401 from `AuthErrorHandler`: `{ error: "unauthenticated" }` on expired/missing token
- Server-side 403 from `RequireConfirmedEmail`: `{ error: "unauthorized" }` for unconfirmed email
- `GET /api/auth/me` with expired token -> 401

### 4. Database Assertion Tests
- N/A (all client-side rendering)

### 5. Event Flow Tests
- N/A

### 6. Background Job Tests
- N/A

### 7. External Service Tests
- N/A

### 8. Storage Tests
- N/A

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- N/A

### 11. Elm State Machine Tests
- **Home page**: `initPage Home` -> `( PageHome, Cmd.none )`, no messages, no model
- **viewHome**: Renders `div.page.page--home` with title, subtitle, action links
- **pageTitle Home**: Returns "The Stacks"
- **requiresAuth**: Returns `False` for the public set — Home, Login, CostTransparency, Catalogue, BookDetail, MarketplaceBrowse, MarketplaceDetail, BlogArchive, BlogPost, ConfirmEmail, NotFound, plus (added since baseline) Metrics, About, Profile, ProfileShelf, Search, ForgotPassword, ResetPassword (~18 routes, `Main.elm:441-502`); `True` for all others _(corrected 2026-07-25 — guard-matrix test must use the current set)_
- **initPage guard**: If `requiresAuth route && maybeAuth == Nothing` -> `( PageLogin Login.init, Cmd.none )`
- **Nav rendering**: `viewNav` pattern-matches `model.auth`:
  - `Nothing` -> Catalogue, Marketplace, About, Sign In _(corrected 2026-07-25 per `MainNavTest.elm`)_
  - `Just auth` -> full shelf nav + dropdowns + UserMenu
- **Active state**: `navItem` compares `currentRoute == targetRoute` -> `app-nav__item--active`
- **isSettingsRoute**: Returns True for all Settings* routes
- **Swipe**: `onSwipe` port subscription -> `decodeSwipe` -> `SwipeReceived direction`
- `SwipeNavigation.swipeLeft/swipeRight`: Returns `Maybe Route` using modular arithmetic
- `bookshelfRoutes`: `[Library, AntiLibrary, WishList, ReadingPile, LookingForHome]`
- Non-bookshelf route: `findIndex` returns Nothing, swipe ignored
- **404**: `Route.fromUrl` -> `Maybe.withDefault NotFound`, `initPage NotFound` -> `PageNotFound`
- **viewNotFound**: "Page Not Found" heading, explanation, "Go Home" link
- **RemoteData**: `NotAsked | Loading | Success a | Failure e` pattern across all API-backed pages
- Error messages: Login uses `aria-live="polite"`, settings uses `p.error`, bookshelves use `p.error`
- Form inputs never cleared on failure

### 12. Metrics & Telemetry Tests
- Home page load rate (authenticated vs unauthenticated)
- Navigation click distribution per item
- Dropdown open rates
- Swipe event rate by direction
- Swipe-to-navigation success rate
- Swipe decode failure rate
- Footer render rate (equals page views)
- 404 hit rate and source URLs
- API failure rate by type (NetworkError, Timeout, BadStatus)
- Client-side redirect rate (requiresAuth guard triggers)
- Server-side 401 rate

## Reviewer Context
- **2026-07-25:** a global session-expiry interceptor now exists (#173/#178, `Main.elm:857-920` — `handleSessionExpiry`/`forceSessionExpiry`, fed by per-page `SessionExpired` OutMsg): expired-session 401s clear storage and redirect to `/login` with a `session-expired-notice`. This is distinct from the `requiresAuth` guard, which still renders Login **in place** at the protected URL. The audit's old "no global 401 handler" premise is obsolete.
- The home page currently renders for authenticated users too (no auto-redirect to `/antilibrary`).
- Swipe wraps around via `modBy` (spec says "does nothing at boundaries" but implementation wraps).
- The login form URL bar does NOT change to `/login` when the requiresAuth guard fires — login renders at the protected URL.
- `EscapePressed` handler closes overlays first, then user menu if no overlay open.

## Test Audit

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). Regenerated 2026-07-25 to the shipped state after Phases 1–3 landed: every `❌`/`⚠️` cell from the 2026-07-08 baseline has been closed by a real, verified test (see the resolved punch list). The issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-25 (GREEN — Issue #125 Phases 1–3 landed; verdicts verified against fresh suite runs)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #125 covers seven user stories — US-15.1.1 (Home
Page), US-15.2.1 (Top Navigation), US-15.2.2 (Swipe Navigation), US-15.3.1
(Footer), US-16.1.1 (404 Not Found), US-16.2.1 (Network Failures /
RemoteData), and US-16.3.1 (Unauthenticated Redirect). The matrix is
therefore 13 layers × 7 US, with happy/sad columns per cell. The assertion
inventory for each cell is taken from each story's `docs/user_stories/US-*.md`
acceptance criteria and §12 Elm state-machine detail, cross-referenced
against Issue #125's Technical Requirements (§1–§12).

**Domain shape:** This is an overwhelmingly **front-end** issue —
client-side routing (Elm `Main.elm` router + `Navigation.Route` +
`Navigation.SwipeNavigation`) and HTTP error surfacing (server-side
`CoreWeb.ErrorJSON`, `StacksWeb.Plugs.AuthErrorHandler`, and client-side
`Types.RemoteData`). Consequently **Layer 10 (Elm state machine)** is the
core layer for every US, and **Layers 1–2** are relevant only to the two
error stories (US-16.1.1 404 templates, US-16.3.1 401/403). Layers 3–9 and
11–13 are `n/a` for every US (no DB, events, jobs, external services,
storage, cache, dbt, or cost surface in navigation/error rendering).

**Feature status:** every feature under audit **is implemented AND now tested**.
Verified live in Phase 1 and covered by the tests below. The six inline
`Main.elm` views/functions that were the "testability wall" at baseline are
now **exposed** (Phase 2, exposing-only, no behaviour change) and unit-tested:
`viewHome`, `viewFooter`, `viewNotFound` (`MainViewTest.elm`), `requiresAuth`
+ `initPage` (`MainRequiresAuthTest.elm`), `decodeSwipe`
(`MainSwipeDecodeTest.elm`); `viewNav` was already exposed and is covered by
`MainNavTest.elm`. The shipped surface (per the Phase-1 re-verification and
the Pre-Check above): home CTAs are the #235 About `/about` + Marketplace
`/marketplace` pair; footer tagline "The Stacks — open source book
management"; 404 heading "Page Not Found" + "Go Home" + tab title "Not Found —
The Stacks"; `requiresAuth` public set = 18 routes / 23 protected (full 41-route
union, `MainRequiresAuthTest.elm`); global session-expiry interceptor (#173/#178).
Server side: `CoreWeb.ErrorJSON` (404/500 templates), `StacksWeb.Plugs.AuthErrorHandler`
(401/403), `StacksWeb.Plugs.RequireConfirmedEmail` (403, now HTTP-integration-tested),
SPA catch-all `PageController.index`. This audit reflects the shipped, tested
state.

---

### Framework-layer summary

| Layer       | US-15.1.1 (Home) | US-15.2.1 (Top Nav) | US-15.2.2 (Swipe) | US-15.3.1 (Footer) | US-16.1.1 (404) | US-16.2.1 (Network) | US-16.3.1 (Unauth) |
|-------------|:----------------:|:-------------------:|:-----------------:|:------------------:|:---------------:|:-------------------:|:------------------:|
| Elixir      | ✅ | n/a | n/a | n/a | ✅ | ✅ | ✅ |
| Elm unit    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Elm program | n/a | n/a | n/a | n/a | n/a | ✅ | n/a |
| Python      | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| E2E         | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| dbt         | n/a | n/a | n/a | n/a | n/a | n/a | n/a |

Notes on the summary:
- **Elixir** is only meaningful for the error stories: `page_controller_test.exs`
  (SPA catch-all) touches Home/404; `error_json_test.exs` covers 404 + 500
  templates; `auth_error_handler_test.exs` + `unauthenticated_redirect_test.exs`
  cover 401; `require_confirmed_email_test.exs` covers the 403 HTTP path.
- **Elm unit** is now GREEN across all seven stories. The six previously-inline
  `Main.elm` functions were exposed (Phase 2) and unit-tested: `viewHome`/
  `viewFooter`/`viewNotFound` (`MainViewTest.elm`), `requiresAuth`/`initPage`
  (`MainRequiresAuthTest.elm`), `decodeSwipe` (`MainSwipeDecodeTest.elm`);
  `viewNav` via `MainNavTest.elm`; Swipe pure functions (`SwipeTest.elm`);
  RemoteData (`RemoteDataTest.elm`, `UpdateTest.elm`, `LoginTest.elm`);
  routing (`RouteTest.elm`, `NavigationProgramTest.elm`).
- **Elm program** (`ProgramTest`) is `n/a` for the six Main.elm-hosted
  view/wiring stories: `Main.elm` is a `Browser.application` with the `onSwipe`
  port and a `Nav.Key`, so the full update loop cannot be constructed in a
  `ProgramTest` (`NavigationProgramTest.elm:6`). That coverage is delivered at
  the **Elm-unit** layer (pure views + pure functions) and at **E2E** instead —
  the two layers that CAN drive Main.elm — so per-view program tests would add
  no guarantee. `Page.Login` is a standalone module and IS program-tested
  (`LoginProgramTest.elm` — the 401/403/423/503 + register-422 message matrix),
  hence ✅ for US-16.2.1.
- **E2E** is now GREEN across all seven stories via `navigation.spec.ts`
  (home render, footer on 3 routes incl. 404, 404 render + tab title, swipe
  gesture + no-op, Marketplace dropdown) and `auth.spec.ts` (form preservation,
  URL-bar-unchanged redirect, redirect breadth, session-expiry interceptor).
- **Python / dbt** are `n/a` across the board — no vision service or
  warehouse model participates in navigation or error rendering.

**Existing test inventory (verified by read; fresh-run tallies below):**

_New/extended for Issue #125 (Phases 2–3):_
- `frontend/tests/MainViewTest.elm` — 10 tests: `viewHome` renders the shipped
  #235 CTAs (About→`/about`, Marketplace→`/marketplace`) + title/subtitle and
  asserts the pre-#235 CTAs are gone; `viewFooter` `footer.app-footer` +
  tagline; `viewNotFound` heading/copy/Go-Home.
- `frontend/tests/MainRequiresAuthTest.elm` — full 41-route `requiresAuth`
  matrix vs an **exhaustive** `expectedAuth` case (a new `Route` constructor
  forces a compile error), the 18-public/23-protected count, and the `initPage`
  login-at-URL guard (protected+no-auth → `PageLogin`, public → not forced).
- `frontend/tests/MainSwipeDecodeTest.elm` — 5 tests: `decodeSwipe` string
  "left"/"right" → `SwipeReceived`; int/object/null → `SwipeIgnored` (fail-closed).
- `frontend/tests/MainNavTest.elm` — `viewNav` unauth (Sign In, Catalogue,
  Marketplace, single About→`/about`, no shelves), authed (display name, full
  shelf set, no Sign In, `app-nav__item--active` on current route, owner Admin
  dropdown / non-owner hidden) + `decodeFlags`/`decodeConfig`/onboarding.
- `frontend/tests/Page/LoginProgramTest.elm` — per-status rendered messages:
  401 "The door remains shut. Invalid credentials." (`:238`), 403 confirm-email
  (`:164`), 423 account-locked (`:179`), 503 service-busy (`:194`), register 422
  duplicate-email (`:107`).
- `e2e/tests/navigation.spec.ts` — home render with #235 CTAs (`:131`); footer
  on `/`, 404, and an authed shelf (`:157`/`:175`); 404 heading/copy/Go-Home +
  `toHaveTitle("Not Found — The Stacks")` + nav & footer visible (`:192`); real
  touch-gesture swipe `/library`→`/antilibrary` + no-op on `/search` (`:224`);
  Marketplace dropdown Create Listing/My Listings (`:289`); plus the prior
  authenticated nav-click set and unauthenticated nav.
- `e2e/tests/auth.spec.ts` — failed login preserves typed email+password
  (`:41`); unauth `/library` renders login at the SAME url, URL bar unchanged
  (`:197`); redirect breadth over `/settings/privacy` + `/marketplace/create`
  (`:216`); owner Admin dropdown Sources/Scrapers (`:106`); logout revokes token
  server-side (`:157`); session-expiry interceptor on page-load/boot/action 401
  (`:234`).
- `apps/core/test/stacks_web/plugs/require_confirmed_email_test.exs` — 4 tests:
  plug unit 403/pass + **HTTP integration** (`:42-54`) — an authenticated but
  unconfirmed user hitting `GET /api/auth/me` gets 403 `{"error": "email not
  confirmed"}`.

_Pre-existing (still standing):_
- `frontend/tests/SwipeTest.elm` — 17 tests (swipeLeft/swipeRight full
  sequences + wrap + non-bookshelf ignore + 5-swipe cycles)
- `frontend/tests/RemoteDataTest.elm` — 10 tests (map / withDefault / fromResult)
- `frontend/tests/UpdateTest.elm` — Bookshelf + BookDetail `*Loaded`
  Ok/Err(403)/Err(NetworkError) → Success/Failure/showAgeGate
- `frontend/tests/LoginTest.elm` — GotAuthResponse Err 401/NetworkError →
  Failure; validation wiring
- `frontend/tests/RouteTest.elm` — fromUrl/toPath round-trips incl.
  Home `/`, unknown → NotFound
- `frontend/tests/NavigationProgramTest.elm` — 4 tests: /upload, /library,
  /search route→view; `/this/does/not/exist` → NotFound
- `e2e/tests/login.spec.ts` — "successful login … redirects" to `/antilibrary`
- `apps/core/test/core_web/error_json_test.exs` — 404.json + 500.json render
- `apps/core/test/core_web/page_controller_test.exs` — GET `/`, `/login`,
  `/upload` serve SPA index HTML (200)
- `apps/core/test/stacks_web/plugs/auth_error_handler_test.exs` — 401
  (:unauthenticated), 403 (:unauthorized), default 401
- `apps/core/test/stacks_web/controllers/unauthenticated_redirect_test.exs`
  — 5 protected routes (`GET /api/bookshelves/library`, `GET /api/placements/mine`,
  `POST …/placements`, `DELETE /api/gdpr/account`, `GET /api/auth/me`) return
  401 without auth

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **17** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **165** |

182 cells total (13 layers × 7 US × happy/sad). **GREEN: 0 ❌ / 0 ⚠️.**
All nine baseline punch items are closed (see the resolved punch list). The
17 ✅ cells are: Layer 1 (4 — 404/500 templates + 401 unauth × happy/sad),
Layer 2 (2 — 401 unauth happy + 403 confirm-email sad), and Layer 10 (11 —
every navigation/error front-end cell that has a render or wiring assertion).
The 165 n/a cells carry a one-line rationale each (Layers 3–9, 11–13 for all
seven stories; Layers 1–2 for the pure client-side stories; Elm-program for
the six Main.elm-hosted views/wiring that structurally cannot be program-tested).

---

### Full audit tables

#### Layer 1: API Calls

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 15.1.1 | n/a — home page is fully static client content; no API call (US §3). `page_controller_test.exs` — "GET / serves index.html" confirms the SPA is served, but that is the catch-all, not a home API. | n/a | n/a — no API, no failure mode. | n/a |
| 15.2.1 | n/a — navigation is pure client-side routing via `Nav.pushUrl`; no API call (US §3). | n/a | n/a | n/a |
| 15.2.2 | n/a — swipe triggers client-side `Nav.pushUrl`; the target page makes its own API calls, audited in its own story (US §3). | n/a | n/a | n/a |
| 15.3.1 | n/a — footer is a static element, no API. | n/a | n/a | n/a |
| 16.1.1 | ✅ error_json_test.exs — "returns error detail for a 404 template" (`ErrorJSON.render("404.json", %{})` → `%{errors: %{detail: "Not Found"}}`). For page navigation the SPA catch-all serves HTML (`page_controller_test.exs`), so the browser never receives a real HTTP 404 — the API 404 template is the only server 404 surface. | ✅ | n/a — the SPA catch-all deliberately serves index HTML for unknown *page* paths (US §4, §15); there is no "sad" HTTP-404 for page navigation. API-404 template is deterministic. | n/a |
| 16.2.1 | ✅ error_json_test.exs — "returns error detail for a 500 template" (`ErrorJSON.render("500.json", %{})` → `%{errors: %{detail: "Internal Server Error"}}`) is the server-side error surface a `Http.BadStatus 500` maps from. | ✅ | n/a — the story is a cross-cutting **client** RemoteData pattern, not an endpoint; per-status client handling audited at Layer 10. | n/a |
| 16.3.1 | ✅ unauthenticated_redirect_test.exs — 5 protected routes return 401 without a token, incl. "GET /api/auth/me without auth returns 401" (US §3, Issue §3). auth_error_handler_test.exs — "returns 401 for :unauthenticated". | ✅ | ✅ unauthenticated_redirect_test.exs exercises the negative directly across GET/POST/DELETE (`GET /api/bookshelves/library`, `GET /api/placements/mine`, `POST …/placements`, `DELETE /api/gdpr/account`, `GET /api/auth/me`) — all assert `json_response(conn, 401)`. _(Route set corrected 2026-07-25 — the old `PUT /api/settings/age_verification` case was removed by ADR-020 §2.)_ | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 15.1.1 | n/a — `requiresAuth Home` = `False` (`Main.elm:246`); the root URL is a public route served by the SPA catch-all. No guard to exercise. | n/a | n/a | n/a |
| 15.2.1 | n/a — the nav's auth-conditional rendering is client-side (`viewNav` pattern-matches `model.auth`); there is no server middleware for navigation. Covered at Layer 10 / E2E. | n/a | n/a | n/a |
| 15.2.2 | n/a — swipe is client-side; the destination page's auth check happens in `initPage` when the new route loads (US §4). | n/a | n/a | n/a |
| 15.3.1 | n/a — footer is global static content, no guard. | n/a | n/a | n/a |
| 16.1.1 | n/a — `requiresAuth NotFound` = `False` (`Main.elm:276`); 404 renders regardless of auth. No guard. | n/a | n/a | n/a |
| 16.2.1 | n/a — cross-cutting client pattern, no specific endpoint or guard (US §4). | n/a | n/a | n/a |
| 16.3.1 | ✅ auth_error_handler_test.exs — "returns 401 for :unauthenticated error" (`halted`, status 401); unauthenticated_redirect_test.exs proves the whole `:authenticated` Guardian pipeline rejects tokenless requests. This is the server-side defence-in-depth path (US §4). | ✅ | ✅ **`RequireConfirmedEmail` → 403 now HTTP-integration-tested.** `require_confirmed_email_test.exs:42-54` drives an authenticated-but-**unconfirmed** user (`insert(:user, email_confirmed: false)` + a real Guardian token) through the protected route `GET /api/auth/me` and asserts `json_response(conn, 403)` with body `%{"error" => "email not confirmed"}` — the plug is exercised in the live pipeline, not just as a unit on `auth_error/3`. The confirmed-user pass case (`:56-66`) and the plug unit (`:18-39`) round it out. _(Closed 2026-07-25 by #124 Punch #3. Note the actual body is `"email not confirmed"`, not the old Issue §3 wording `"unauthorized"`.)_ | ✅ |

#### Layer 3: Database Interactions

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — navigation and error rendering touch no database. Every story's §5 is "N/A". | n/a |

#### Layer 4: Event Flow & Lifecycle

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — no `Stacks.Events.emit/1` in any navigation/error path (every story §6 = N/A). | n/a |

#### Layer 5: Background Jobs (Oban)

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — no Oban job participates (every story §7 = N/A). | n/a |

#### Layer 6: External Service Calls

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — no vision, ISBN, scraper, or other external call (every story §8 = N/A). | n/a |

#### Layer 7: Storage (R2 / Local)

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — no object/blob storage in navigation or error rendering (every story §9 = N/A). | n/a |

#### Layer 8: Cache Interactions

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — no cache in the read/write path (every story §10 = N/A). | n/a |

#### Layer 9: dbt Model Dependencies

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — navigation/error rendering produce no warehouse rows; no staging or mart model depends on them (every story §11 = N/A). | n/a |

#### Layer 10: Elm Frontend State Machine

The core layer for this issue. `Main.elm` uses `Browser.application` + the
`onSwipe` port, so its inline functions **cannot be constructed in a full
`ProgramTest`** (`NavigationProgramTest.elm:6`). Phase 2 resolved this the way
the note prescribes — **by exposing the functions** so their pure outputs can
be asserted directly (`viewHome`/`viewFooter`/`viewNotFound`/`requiresAuth`/
`initPage`/`decodeSwipe`), mirroring the established `viewNav`/`MainNavTest`
pattern — with the residual render/wiring cases (an actual swipe gesture, the
`SwipeReceived → pushUrl` glue, tab title, redirect URL-bar behaviour) closed
at the E2E layer. Every cell below is now ✅ (render/wiring asserted) or n/a.

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 15.1.1 | ✅ **Render asserted at unit + E2E.** `MainViewTest.elm` (`viewHome`, `:27-70`): `h1` "The Stacks", subtitle "Your personal collection, beautifully organised.", primary CTA `.home__link--about`/`.btn--primary` → `/about` "About The Stacks", secondary `.home__link--marketplace`/`.btn--secondary` → `/marketplace` "Browse the Marketplace", and a negative for the removed pre-#235 CTAs. E2E `navigation.spec.ts:131` (`goto("/")`) asserts the same shipped markup + hrefs against a running page. `RouteTest.elm` still covers `/`↔`Home` routing. | ✅ | n/a — home is a static, model-less page (US §12 "no state machine"); no failure state exists. | n/a |
| 15.2.1 | ✅ **All the baseline gaps closed.** Elm-unit `MainNavTest.elm`: `viewNav Nothing` → Sign In + Catalogue + Marketplace + single About→`/about`, no shelves (`:61-92`); `viewNav (Just auth)` → display name + full shelf set + no Sign In (`:93-113`); **active-state** `app-nav__item--active` on the current route (`:114-118`); owner sees Admin dropdown / non-owner hidden (`:119-128`). E2E: Marketplace dropdown reveals Create Listing `/marketplace/create` + My Listings `/marketplace/mine` (`navigation.spec.ts:289`); owner Admin dropdown Sources/Scrapers (`auth.spec.ts:106`); user-menu "Sign Out" ends the session (`auth.spec.ts:157`); plus the prior top-level + Catalogue-dropdown click set. | ✅ | ✅ navigation.spec.ts — unauthenticated "only Catalogue and Sign In are visible … About under brand dropdown" asserts the negative set (`not.toContain` Costs/Library/Add Book/Search, `:112-123`); the authenticated test asserts "Sign In link should NOT be visible when authenticated" (`:97`); `MainNavTest.elm` asserts `viewNav Nothing` hides the authed-only bookshelves (`:84-91`). | ✅ |
| 15.2.2 | ✅ SwipeTest.elm — swipeLeft full forward sequence (Library→AntiLibrary→WishList→ReadingPile→LookingForHome→**wrap** Library) and swipeRight full reverse sequence, plus "5 left swipes from Library returns to Library" and the right-cycle equivalent. Directly covers `SwipeNavigation.swipeLeft`/`swipeRight` + modular wrap (US §12). Now also `navigation.spec.ts:256` drives a real touch-gesture swipe on `/library` navigating to `/antilibrary` — the positive `SwipeReceived → pushUrl` glue end-to-end. | ✅ | ✅ **Port decode + wiring now tested.** `MainSwipeDecodeTest.elm` (`:15-38`): `decodeSwipe` "left"/"right" string → `SwipeReceived`; int/object/null → `SwipeIgnored` (fail-closed, so a malformed gesture never navigates). E2E `navigation.spec.ts:270` swipes on `/search` (a non-bookshelf route) and asserts the URL is **unchanged** — the no-op branch, preceded by the positive-navigation test that proves the gesture path is live (not a vacuous guard). SwipeTest.elm still covers the pure "ignored on non-bookshelf" cases. | ✅ |
| 15.3.1 | ✅ **The single ❌ is closed.** `MainViewTest.elm` (`viewFooter`, `:71-90`) asserts `footer.app-footer` with `p.app-footer__text` "The Stacks — open source book management". E2E `navigation.spec.ts:157-189` asserts `footer.app-footer` + tagline on **three** routes: `/` (unauth), the 404 page, and an authenticated bookshelf — covering Issue §1 "Footer on every page" AND "404 nav and footer". (Perturbation on the footer tagline was captured in Phase 3.) | ✅ | n/a — footer is static and always rendered; no failure mode. | n/a |
| 16.1.1 | ✅ **Route mapping AND render asserted.** `MainViewTest.elm` (`viewNotFound`, `:91-113`): `h1` "Page Not Found", explanation "The page you're looking for doesn't exist.", `a href="/"` "Go Home". E2E `navigation.spec.ts:192` (`goto("/nonexistent-page")`): `toHaveTitle("Not Found — The Stacks")` (the browser tab title / `pageTitle NotFound`), the heading/copy/Go-Home, plus `header.app-header` and `footer.app-footer` still visible (Issue §1 "404 nav and footer"). `RouteTest.elm`/`NavigationProgramTest.elm` still cover the unknown-path → `NotFound` routing. | ✅ | n/a — 404 **is** the sad path for navigation; there is no further failure mode below it. | n/a |
| 16.2.1 | ✅ RemoteDataTest.elm — map/withDefault/fromResult across NotAsked/Loading/Success/Failure (the type mechanics, US §12); UpdateTest.elm — "ShelvesLoaded Ok sets … shelves = Success", "BookLoaded Ok sets … book = Success" (Success path). The universal RemoteData pattern is verified. | ✅ | ✅ **Per-status messages + form preservation now asserted.** `LoginProgramTest.elm` asserts the *rendered* text for each status, not just `submitState = Failure`: 401 "The door remains shut. Invalid credentials." (`:238`), 403 confirm-email (`:164`), 423 account-locked (`:179`), 503 service-busy (`:194`), register-422 duplicate-email (`:107`). Failure-state pieces still stand (UpdateTest.elm NetworkError/403; LoginTest.elm 401/NetworkError). **Form-input preservation VERIFIED** — Phase 1 live-drove it (login + settings/password retain inputs on failure; no clearing-on-failure gap) and `auth.spec.ts:41` asserts a failed login RETAINS the typed email + password. | ✅ |
| 16.3.1 | ✅ **`requiresAuth` matrix + `initPage` guard + broader redirect all tested.** `MainRequiresAuthTest.elm`: the **full 41-route** `requiresAuth` matrix vs an exhaustive `expectedAuth` case (`:206-244`, so a new `Route` forces a compile error), the 18-public/23-protected count, and the `initPage` guard — protected route + no auth → `PageLogin` (`:246-258`), public route → not forced (`:259-264`). E2E redirect now spans **three** protected routes: `/upload` (`auth.spec.ts:76`), `/settings/privacy` and `/marketplace/create` (`auth.spec.ts:216`), plus `/library` (`:197`). Post-login target `/antilibrary` still covered (auth.spec/login.spec). | ✅ | ✅ **Sad-path client behaviours asserted.** (a) URL bar stays at the protected URL: `auth.spec.ts:197` asserts `page.url()` matches `/library$` and NOT `/login$` after the login form renders in place; (b) public routes render without redirect: `MainRequiresAuthTest.elm:259` (`initPage Home Nothing` does not force Login); (c) the "no global 401 handler" premise is **obsolete** — the shipped global session-expiry interceptor (#173/#178) IS now exercised E2E (`auth.spec.ts:234` — a page-load/boot/action 401 with a revoked token redirects to `/login` with a distinct `session-expired-notice`, distinct from the in-place `requiresAuth` guard). | ✅ |

#### Layer 11: Operational Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — every §13 metric (home load rate, nav click distribution, dropdown open rate, swipe event/decode-failure rate, footer render rate, 404 hit rate, API-failure-rate-by-type, client-side redirect rate, server-side 401/403 rate) is an **analytics/SLO-gate concern**, not a per-US unit assertion. Automatic Phoenix endpoint + Oban telemetry and `scripts/check-slo-gate.sh` (scrapes `/internal/metrics` post-deploy) cover firing; per-US repetition adds no guarantee. Issue §12 lists these as monitoring targets, not test requirements. | n/a |

#### Layer 12: Performance & Usability Metrics

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — covered by the SLO gate, not unit tests. Every §14 target (home <50ms, nav render <5ms, redirect latency <50ms, swipe detection latency) is an in-test SLA bound, which is an anti-pattern under variable CI timing. | n/a |

#### Layer 13: Cost Tracking

| US | Happy Path | Sad Path |
|----|------------|----------|
| all 7 | n/a — every story's §15 is **$0.00**: navigation and error rendering are client-side (or a single static SPA HTML serve) with no external API spend to record in `BudgetTracker`. Fly/Neon compute is covered by the cost dashboard at deploy time. | n/a |

---

### Punch list (all 9 items RESOLVED — 2026-07-25)

Every baseline ❌/⚠️ cell is closed by a real, verified test. The recurring
blocker (target functions inline in `Main.elm`) was resolved by **exposing**
them (Phase 2, no behaviour change), with the residual render/wiring cases
closed by Playwright E2E (Phase 3). Items 2, 6 (part), and 7 were closed by
intervening work (`MainNavTest.elm`, `LoginProgramTest.elm` per-status, #124
Punch #3) as noted.

| # | Cell | Status | Closing evidence (file:line) |
|--:|------|--------|------------------------------|
| 1 | L10 US-15.1.1 happy | ✅ resolved | `MainViewTest.elm:27-70` (`viewHome` — shipped #235 About/Marketplace CTAs, title, subtitle, negative for the removed CTAs) + `navigation.spec.ts:131` (`goto("/")` asserts the same markup + hrefs live). |
| 2 | L10 US-15.2.1 happy | ✅ resolved (mostly by intervening `MainNavTest.elm`) | `MainNavTest.elm:114-118` (active class), `:119-128` (owner/non-owner Admin), `:61-92` (unauth `viewNav` set); `navigation.spec.ts:289` (Marketplace dropdown Create Listing/My Listings); `auth.spec.ts:106` (Admin Sources/Scrapers), `:157` (user-menu Sign Out). |
| 3 | L10 US-15.2.2 sad | ✅ resolved | `MainSwipeDecodeTest.elm:15-38` (`decodeSwipe` valid → `SwipeReceived`, malformed → `SwipeIgnored`); `navigation.spec.ts:256` (positive gesture `/library`→`/antilibrary`) + `:270` (no-op on `/search`). |
| 4 | L10 US-15.3.1 happy | ✅ resolved (the single baseline ❌) | `MainViewTest.elm:71-90` (`viewFooter` tagline); `navigation.spec.ts:157-189` (`footer.app-footer` + tagline on `/`, 404, and an authed shelf). |
| 5 | L10 US-16.1.1 happy | ✅ resolved | `MainViewTest.elm:91-113` (`viewNotFound` heading/copy/Go-Home); `navigation.spec.ts:192` (`toHaveTitle("Not Found — The Stacks")` + heading/copy/Go-Home + nav & footer visible). |
| 6 | L10 US-16.2.1 sad | ✅ resolved (per-status by `LoginProgramTest.elm`; preservation by Phase 1 + `auth.spec.ts`) | `LoginProgramTest.elm:238`(401)/`:164`(403)/`:179`(423)/`:194`(503)/`:107`(register-422) rendered-text assertions; `auth.spec.ts:41` (failed login retains email + password); Phase-1 live-drive of login + settings/password preservation (no gap). |
| 7 | L2 US-16.3.1 sad | ✅ resolved (intervening #124 Punch #3) | `require_confirmed_email_test.exs:42-54` — HTTP integration: unconfirmed user → `GET /api/auth/me` → 403 `%{"error" => "email not confirmed"}`. |
| 8 | L10 US-16.3.1 happy | ✅ resolved | `MainRequiresAuthTest.elm:206-244` (full 41-route matrix + 18/23 count), `:246-258` (`initPage` protected+no-auth → Login); `auth.spec.ts:76`/`:197`/`:216` (redirect across `/upload`, `/library`, `/settings/privacy`, `/marketplace/create`). |
| 9 | L10 US-16.3.1 sad | ✅ resolved | `auth.spec.ts:197` (URL bar stays `/library`, not `/login`); `MainRequiresAuthTest.elm:259` (public route not forced to Login); `auth.spec.ts:234` (the "no global 401 handler" premise is obsolete — the #173/#178 session-expiry interceptor is now E2E-driven). |

---

### Verdict

**GREEN — audit resolved.** State across the 13-layer × 7-US matrix (182 cells):

- **17 ✅ STRONG** — Layer 1 (4: 404/500 templates + 401 unauth happy/sad),
  Layer 2 (2: 401 unauth happy + 403 confirm-email sad, now HTTP-integration
  tested), and Layer 10 (11: every navigation/error front-end cell now carries
  a render or wiring assertion — home render, top-nav active-state/dropdowns/
  admin, swipe decode + gesture + no-op, footer on 3 routes, 404 render + tab
  title, per-status error messages + form preservation, the full `requiresAuth`
  matrix + `initPage` guard, and the client-redirect edge behaviours incl. the
  session-expiry interceptor).
- **0 ⚠️ / 0 ❌** — all nine baseline punch items closed (see the resolved
  punch list).
- **165 n/a** — Layers 3–9 and 11–13 for all seven stories (no DB, events,
  jobs, external services, storage, cache, dbt, metrics, or cost surface),
  Layers 1–2 for the pure client-side navigation stories, and the Elm-program
  layer for the six Main.elm-hosted views/wiring that structurally cannot be
  program-tested (covered at Elm-unit + E2E instead).

**Headline findings:**
1. **The Main.elm testability wall is gone.** `viewHome`, `viewFooter`,
   `viewNotFound`, `requiresAuth`, `initPage`, and `decodeSwipe` were exposed
   (Phase 2, exposing-only, no behaviour change) and unit-tested directly
   (`MainViewTest`, `MainRequiresAuthTest`, `MainSwipeDecodeTest`), mirroring
   the pre-existing `viewNav`/`MainNavTest` pattern. The residual render/wiring
   cases only a browser can prove (a real swipe gesture, `SwipeReceived →
   pushUrl`, the tab title, URL-bar redirect behaviour, the session-expiry
   interceptor) are covered by Playwright (`navigation.spec.ts`, `auth.spec.ts`).
2. **The footer — the single baseline ❌ — is covered** at unit (`MainViewTest`)
   and on three E2E routes including the 404 page.
3. **Error surfacing is now symmetric.** Server-side 401/403/404/500 remain
   solid (403 now HTTP-integration tested, not just a unit); the client-side
   RemoteData contract is proven; and the user-visible payoff — per-status
   error **messages** (401/403/423/503/422), form-input **preservation**
   (live-driven + E2E), and the client `requiresAuth` **redirect** across four
   protected routes — is now asserted across the matrix the stories enumerate.

**Nuances handled honestly (not fudged):**
- The **Elm-program** layer for the six Main.elm views/wiring is `n/a`, not ✅ —
  `Browser.application` + the `onSwipe` port makes a full `ProgramTest`
  structurally impossible (`NavigationProgramTest.elm:6`); that coverage is
  delivered at Elm-unit + E2E. `Page.Login` (a standalone module) IS
  program-tested (`LoginProgramTest.elm`).
- The swipe **`SwipeReceived → pushUrl` glue** is proven at the E2E level (the
  real gesture navigating `/library`→`/antilibrary`, `navigation.spec.ts:256`),
  with `decodeSwipe` unit-tested; the Main.elm update-branch itself is not
  unit-constructible (same port constraint).
- The **session-expiry interceptor** (#173/#178) covers page-load/boot/action
  401s and redirects to `/login` with a distinct notice; it is separate from
  the `requiresAuth` guard (which renders Login in place at the protected URL).
  A settings-**save** 401 surfaces an inline page error, not the interceptor —
  documented in the Pre-Check and Reviewer Context.

**Fresh-run tallies (2026-07-25, this regeneration):**
- Elm — `cd frontend && npx elm-test`: **1173 passed, 0 failed** (incl. the new
  `MainViewTest` 10, `MainRequiresAuthTest` 45, `MainSwipeDecodeTest` 5,
  `MainNavTest`, `LoginProgramTest` per-status).
- Elixir — `just run mix test` on the 5 relevant files (`error_json`,
  `page_controller`, `auth_error_handler`, `unauthenticated_redirect`,
  `require_confirmed_email`): **17 tests, 0 failures**.
- E2E — orchestrator-verified 2026-07-25 (serial): targeted nav+auth+login set
  **36/36**; full `--project=chromium --workers=1` **223 passed / 58 Modal-skips
  / 1 pre-existing `age-gate.spec.ts:43` failure** (untouched file, not a
  regression from this issue). Not re-run here (local Phoenix :4000 in use).

Punch list: **0 open** (9/9 resolved).
## Definition of Done
- [x] All 11 test categories implemented with specific test cases listed above — evidence: Layers 1–2 (Elixir `error_json`/`page_controller`/`auth_error_handler`/`unauthenticated_redirect`/`require_confirmed_email`), Layer 10/11 Elm state machine (`MainViewTest.elm`, `MainRequiresAuthTest.elm`, `MainSwipeDecodeTest.elm`, `MainNavTest.elm`, `LoginProgramTest.elm`, `SwipeTest.elm`, `RemoteDataTest.elm`), §1–§2 Playwright (`navigation.spec.ts`, `auth.spec.ts`); Layers 3–9/12–13 are `n/a`-with-rationale (see the GREEN audit above). Metrics/§12 covered by the SLO gate, not per-US unit tests.
- [x] Tests pass with `TEST_TARGET=local` — evidence: `cd frontend && npx elm-test` → 1173 passed / 0 failed (2026-07-25); `just run mix test` on the 5 relevant files → 17 tests, 0 failures (2026-07-25); Playwright targeted 36/36 + full chromium 223 pass (orchestrator-verified 2026-07-25, serial).
- [ ] No flaky tests — _left for the orchestrator: I did not run Playwright this phase (local :4000 in use). Phase 3 documented a 4-worker `:auth` rate-limit 429 (60/60s shared bucket; serial run clean), a pre-existing parallelism artifact, not test nondeterminism. Orchestrator owns the full-run flakiness verdict._
- [ ] `just verify` passes _(orchestrator-owned — not this phase)_
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`. — evidence: Pre-Check table (7/7 ✅ with live-drive artifacts) + Phase 1 Progress Note (2026-07-25).
- [x] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state. — evidence: this regeneration (2026-07-25) — tally 17 ✅ / 0 ⚠️ / 0 ❌ / 165 n/a; resolved punch list 9/9 with closing test file:line each.
- [x] **Audit re-baselined to current code before test-writing** (corrections A–H from the 2026-07-25 re-verification: global interceptor, #235 CTAs/nav, #267 admin, ~18 public routes, ADR-020 route removal) — evidence: regenerated tables dated 2026-07-25; ADR-020 route correction applied to Layer 1 US-16.3.1; #235/#267/interceptor reflected in the Pre-Check + framework summary.
- [x] **Story docs reconciled**: `US-15.1.1` CTAs updated to shipped About/Marketplace; `US-16.3.1` "no global 401 handler" note updated to shipped interceptor behaviour — evidence: commit `e23388c6` — `docs/user_stories/US-15.1.1-home-page.md` (+20/-6) and `docs/user_stories/US-16.3.1-unauth-redirect.md` (+19/-1) on this branch.
- [x] **Form-input preservation (US-16.2.1) verified live** — retained-input assertion in Elm program test + E2E; if live-drive finds a page clearing inputs on failure, the fix ships in-scope — evidence: Phase 1 live-drive (login + settings/password both retain inputs on failure, no gap) + `e2e/tests/auth.spec.ts:41` (failed login retains typed email + password).

## Dependencies
Requires Main.elm routing, SwipeNavigation module, ViewNav rendering, RemoteData pattern.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]

- **2026-07-25 (Phase 1 — testing-coordinator):** Re-baselined docs + live-drove all 7 stories against a fresh local stack (rebuilt esbuild `app.js`, `STACKS_E2E_TEST_HELPERS=1`, `AGE_GATING_ENABLED=true`, seeded dev DB, `POST /api/test/session` mint helper). **All 7 Pre-Check rows ✅ with live evidence** (see table). Highlights: home CTAs are the shipped #235 About/Marketplace pair; real touch-gesture swipe navigates `/library`→`/antilibrary` and is a no-op on `/search`; footer present on `/`, authed shelf, and 404; 404 tab title "Not Found — The Stacks". **Form-input preservation VERIFIED (no gap):** login retains email/password after a wrong-password failure, and the settings password form retains all 3 fields after a wrong-current-password 422 → Plan Phase 2b contingency (form-preservation fix) is NOT needed. Global session-expiry interceptor (#173/#178) confirmed on a page-load 401 (bookshelf-load with a revoked token → redirect `/login` + `session-expired-notice`); noted it does NOT fire on a settings-save 401 (Profile surfaces inline "Could not save profile."). Docs reconciled: `docs/user_stories/US-15.1.1-home-page.md` (CTAs → About/Marketplace) and `docs/user_stories/US-16.3.1-unauth-redirect.md` ("no global 401 handler" note → shipped interceptor + page-load-vs-save nuance).
- **2026-07-25 (Phase 3 — testing-coordinator):** Added the durable Playwright specs closing the render/wiring/behaviour punch items only E2E can prove. `e2e/tests/navigation.spec.ts` (+8 describes): home render with the shipped #235 About/Marketplace CTAs; footer `footer.app-footer` tagline on `/` (unauth), an authed bookshelf, and the 404 page; 404 page heading/explanation/Go-Home + `toHaveTitle("Not Found — The Stacks")` + nav & footer visible; real touch-gesture swipe (dispatched `TouchEvent`s, dx=-240) navigating `/library`→`/antilibrary` and a no-op on `/search`; Marketplace dropdown revealing Create Listing (`/marketplace/create`) and My Listings (`/marketplace/mine`). `e2e/tests/auth.spec.ts` (+2 describes): failed-login preserves the typed email+password (US-16.2.1); unauth `/library` renders the login form at the SAME url (URL bar unchanged) + redirect breadth across `/settings/privacy` and `/marketplace/create`. Verified against a fresh local stack (rebuilt esbuild assets, `STACKS_E2E_TEST_HELPERS=true AGE_GATING_ENABLED=true`, setup project green): the targeted nav+auth+login set is **36/36 green when run serially** (`--workers=1`). Note: at the default 4 workers the whole `auth.spec.ts` file 429s on the shared `:auth` rate-limit bucket (60/60s per IP — setup + login.spec + auth.spec logging in concurrently), a pre-existing parallelism flake unrelated to these specs; serial run is clean. Full `--project=chromium --workers=1` run: **223 passed, 58 skipped, 1 failed** — the lone failure is `age-gate.spec.ts:43` (untouched file, age-gated-seed precondition), not a regression from this phase. Non-vacuity proven by perturbation on the footer test (expected wrong tagline → received "The Stacks — open source book management") and the URL-bar test (expected `/login$` → received `http://localhost:4000/library`); both reverted via Edit. No vacuous `if (count > 0)` guards; the swipe no-op assertion is preceded by a positive-navigation test that proves the gesture path is live.
- **2026-07-25 (Phase 2 — elm-agent):** Widened `frontend/src/Main.elm`'s exposing list (exposing-only, +8 lines, no behaviour change) to export `viewHome`, `viewFooter`, `viewNotFound`, `requiresAuth`, `initPage`, `decodeSwipe`, plus `Msg(..)`/`Page(..)` needed to assert their results. Added 20 unit tests across three new files: `frontend/tests/MainViewTest.elm` (home #235 CTAs, footer tagline, 404 heading/copy/Go-Home), `frontend/tests/MainRequiresAuthTest.elm` (full 41-route `requiresAuth` matrix + 18-public/23-protected count + `initPage` login-at-URL guard, guarded by an exhaustive `expectedAuth` case so a new `Route` constructor forces a compile error), `frontend/tests/MainSwipeDecodeTest.elm` (valid→`SwipeReceived`, malformed→`SwipeIgnored`). Perturbation evidence captured (one per file, reverted via Edit). Full suite green (1116 elm-test), `elm-format --validate` clean, `elm make` clean, `elm-review --config elm-review` clean (no exposing narrowed).
- **2026-07-25 (Phase 4 — testing-coordinator):** Regenerated the embedded Test Audit to GREEN against fresh suite runs (not report-read). Verified every flipped cell at file:line by reading the test: `MainViewTest.elm` (viewHome/viewFooter/viewNotFound), `MainRequiresAuthTest.elm` (41-route matrix + initPage guard), `MainSwipeDecodeTest.elm` (decodeSwipe), `MainNavTest.elm` (viewNav active/admin/unauth), `LoginProgramTest.elm` (401/403/423/503/422 rendered text), `require_confirmed_email_test.exs:42-54` (403 HTTP integration, body `"email not confirmed"`), and the Phase-3 `navigation.spec.ts`/`auth.spec.ts` additions. **Fresh tallies:** `npx elm-test` → 1173 passed/0 failed; `just run mix test` on the 5 relevant files → 17 tests/0 failures. E2E left as orchestrator-verified (local :4000 in use; not re-run). Tally **7 ✅/8 ⚠️/1 ❌ → 17 ✅/0 ⚠️/0 ❌/165 n/a**; all 9 baseline punch items marked resolved with closing evidence. Corrected two stale cells: Layer 1 US-16.3.1 (ADR-020 removed `PUT /api/settings/age_verification` → the current 5-route set) and Layer 2 US-16.3.1 (403 body is `"email not confirmed"`, not the old `"unauthorized"`). Honestly held the Elm-program layer at `n/a` (Browser.application + port → not `ProgramTest`-constructible; covered at unit + E2E) rather than fudging to ✅. DoD: ticked 6 of 9 with evidence tokens; left "just verify passes" (orchestrator) and "No flaky tests" (orchestrator owns the full-run verdict; I did not run Playwright this phase).
