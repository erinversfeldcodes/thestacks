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

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #125)

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

**Feature status:** every feature under audit **is implemented**. Verified
in source: `viewHome` (`frontend/src/Main.elm:1920`), `viewNav`/`navItem`
(auth-conditional, `Main.elm`), `viewFooter` (`Main.elm:1962`, tagline "The
Stacks — open source book management"), `viewNotFound` (`Main.elm:1953`,
heading "Page Not Found" + "Go Home" link), `pageTitle NotFound = "Not
Found — The Stacks"` (`Main.elm:1665`), `requiresAuth` (`Main.elm:243`,
11 public routes), `initPage` client guard (`Main.elm:283`),
`SwipeReceived`/`decodeSwipe` (`Main.elm:1417`/`1515`),
`Navigation.SwipeNavigation.swipeLeft`/`swipeRight` (modular wrap). Server
side: `CoreWeb.ErrorJSON` (404/500 templates), `StacksWeb.Plugs.AuthErrorHandler`
(401/403), SPA catch-all `PageController.index`. This audit therefore
baselines real coverage rather than marking "not implemented".

---

### Framework-layer summary

| Layer       | US-15.1.1 (Home) | US-15.2.1 (Top Nav) | US-15.2.2 (Swipe) | US-15.3.1 (Footer) | US-16.1.1 (404) | US-16.2.1 (Network) | US-16.3.1 (Unauth) |
|-------------|:----------------:|:-------------------:|:-----------------:|:------------------:|:---------------:|:-------------------:|:------------------:|
| Elixir      | ✅ | n/a | n/a | n/a | ✅ | ✅ | ✅ |
| Elm unit    | ⚠️ | ❌ | ✅ | ❌ | ⚠️ | ✅ | ❌ |
| Elm program | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ | ❌ |
| Python      | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| E2E         | ❌ | ⚠️ | ❌ | ❌ | ❌ | ⚠️ | ⚠️ |
| dbt         | n/a | n/a | n/a | n/a | n/a | n/a | n/a |

Notes on the summary:
- **Elixir** is only meaningful for the error stories: `page_controller_test.exs`
  (SPA catch-all) touches Home/404; `error_json_test.exs` covers 404 + 500
  templates; `auth_error_handler_test.exs` + `unauthenticated_redirect_test.exs`
  cover 401/403.
- **Elm unit** is strong for Swipe (`SwipeTest.elm`) and RemoteData
  (`RemoteDataTest.elm`, `UpdateTest.elm`, `LoginTest.elm`), route-only for
  Home/404 (`RouteTest.elm`, `NavigationProgramTest.elm`), and absent for
  Top Nav/Footer/requiresAuth (those live inline in `Main.elm`, which uses
  `Browser.application` + the `onSwipe` port and cannot be constructed in
  pure Elm tests).
- **Elm program** (`ProgramTest`) coverage exists only for Login
  (`LoginProgramTest.elm`). None of the Main.elm-hosted views (nav, footer,
  home, 404) or the swipe/redirect wiring have program tests.
- **Python / dbt** are `n/a` across the board — no vision service or
  warehouse model participates in navigation or error rendering.

**Existing test inventory (verified by grep/read):**
- `frontend/tests/SwipeTest.elm` — 17 tests (swipeLeft/swipeRight full
  sequences + wrap + non-bookshelf ignore + 5-swipe cycles)
- `frontend/tests/RemoteDataTest.elm` — 10 tests (map / withDefault / fromResult)
- `frontend/tests/UpdateTest.elm` — Bookshelf + BookDetail `*Loaded`
  Ok/Err(403)/Err(NetworkError) → Success/Failure/showAgeGate
- `frontend/tests/LoginTest.elm` — GotAuthResponse Err 401/NetworkError →
  Failure; validation wiring
- `frontend/tests/Page/LoginProgramTest.elm` — `login_failure_shows_error`
  asserts rendered "The door remains shut. Invalid credentials." for 401
- `frontend/tests/RouteTest.elm` — fromUrl/toPath round-trips incl.
  Home `/`, unknown → NotFound
- `frontend/tests/NavigationProgramTest.elm` — 4 tests: /upload, /library,
  /search route→view; `/this/does/not/exist` → NotFound
- `e2e/tests/navigation.spec.ts` — authenticated top-level nav clicks
  (6 items), Catalogue dropdown (Search, Add Book), Settings via user menu,
  "preserves auth state", unauthenticated "only Catalogue and Sign In"
- `e2e/tests/login.spec.ts` — "navbar shows only Costs and Sign In when not
  authenticated"; "successful login … redirects" to `/antilibrary`
- `e2e/tests/auth.spec.ts` — "upload page redirects to login when not
  authenticated"; wrong-password shows "The door remains shut."; login →
  `/antilibrary`
- `apps/core/test/core_web/error_json_test.exs` — 404.json + 500.json render
- `apps/core/test/core_web/page_controller_test.exs` — GET `/`, `/login`,
  `/upload` serve SPA index HTML (200)
- `apps/core/test/stacks_web/plugs/auth_error_handler_test.exs` — 401
  (:unauthenticated), 403 (:unauthorized), default 401
- `apps/core/test/stacks_web/controllers/unauthenticated_redirect_test.exs`
  — 6 protected routes (incl. `GET /api/auth/me`) return 401 without auth

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **7** |
| ⚠️ shallow | **8** |
| ❌ missing | **1** |
| n/a (covered higher up / not applicable / by-design) | **166** |

182 cells total (13 layers × 7 US × happy/sad). This is the
pre-implementation baseline; Issue #125's DoD requires regenerating this
audit to 0 ❌ / 0 ⚠️ after the punch list lands.

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
| 16.3.1 | ✅ unauthenticated_redirect_test.exs — 6 protected routes return 401 without a token, incl. "GET /api/auth/me without auth returns 401" (US §3, Issue §3). auth_error_handler_test.exs — "returns 401 for :unauthenticated". | ✅ | ✅ unauthenticated_redirect_test.exs exercises the negative directly across GET/POST/PUT/DELETE ("GET /api/bookshelves/library", "POST …/placements", "PUT /api/settings/age_verification", "DELETE /api/gdpr/account") — all assert `json_response(conn, 401)`. | ✅ |

#### Layer 2: Auth & Middleware Guards

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 15.1.1 | n/a — `requiresAuth Home` = `False` (`Main.elm:246`); the root URL is a public route served by the SPA catch-all. No guard to exercise. | n/a | n/a | n/a |
| 15.2.1 | n/a — the nav's auth-conditional rendering is client-side (`viewNav` pattern-matches `model.auth`); there is no server middleware for navigation. Covered at Layer 10 / E2E. | n/a | n/a | n/a |
| 15.2.2 | n/a — swipe is client-side; the destination page's auth check happens in `initPage` when the new route loads (US §4). | n/a | n/a | n/a |
| 15.3.1 | n/a — footer is global static content, no guard. | n/a | n/a | n/a |
| 16.1.1 | n/a — `requiresAuth NotFound` = `False` (`Main.elm:276`); 404 renders regardless of auth. No guard. | n/a | n/a | n/a |
| 16.2.1 | n/a — cross-cutting client pattern, no specific endpoint or guard (US §4). | n/a | n/a | n/a |
| 16.3.1 | ✅ auth_error_handler_test.exs — "returns 401 for :unauthenticated error" (`halted`, status 401); unauthenticated_redirect_test.exs proves the whole `:authenticated` Guardian pipeline rejects tokenless requests. This is the server-side defence-in-depth path (US §4). | ✅ | ⚠️ The **`RequireConfirmedEmail` → 403** branch (US §4, Issue §3: "403 from `RequireConfirmedEmail`: `{ error: \"unauthorized\" }` for unconfirmed email") is only covered as a *unit* on `auth_error/3` (auth_error_handler_test.exs — "returns 403 for :unauthorized error"). No integration test drives an authenticated-but-**unconfirmed** user through a protected route to assert the plug actually returns 403 (no `RequireConfirmedEmail`/`email_confirmed`-403 match in any controller test). | ⚠️ |

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

The core layer for this issue. Note (per `NavigationProgramTest.elm:6`):
`Main.elm` uses `Browser.application` + the `onSwipe` port, so the inline
`viewNav` / `viewHome` / `viewFooter` / `viewNotFound` / `requiresAuth` /
`initPage` functions **cannot be constructed in a pure Elm test**. Coverage
of those must come from E2E (Playwright) or by extracting the function into
a testable module. This constraint is why so many happy-path cells below are
⚠️ ("route mapping tested, render untested") rather than ✅.

| US | Happy Path | Verdict | Sad Path | Verdict |
|----|------------|---------|----------|---------|
| 15.1.1 | ⚠️ RouteTest.elm — "Home" (`fromPath "/"` → `Home`) + "Home path" (`toPath Home` → `"/"`) verify **routing** to Home. BUT the AC render assertions — `h1.home__title` "The Stacks", `p.home__subtitle` "Your personal collection…", `a.btn--primary` → `/antilibrary` "View Antilibrary", `a.btn--secondary` → `/upload` "Add a Book" (US §12) — are **unverified**: `viewHome` is inline in `Main.elm` (untestable in unit) and no E2E navigates to `/` to assert home content (`catalogue.spec.ts`/`private-session.spec.ts` visit `/` only to run fetches or check nav, not home markup). | ⚠️ | n/a — home is a static, model-less page (US §12 "no state machine"); no failure state exists. | n/a |
| 15.2.1 | ⚠️ E2E navigation.spec.ts covers authenticated top-level nav clicks (Library, Antilibrary, Wish List, Reading Pile, Looking for a Home, Catalogue), Catalogue dropdown sub-items ("Search", "Add Book"), and "Settings" via the user-menu dropdown; "navigating between all shelves preserves auth state". BUT gaps against US §2/§12: (a) **active-state class** `app-nav__item--active` is never asserted (no `--active` match in any spec/test); (b) **Marketplace dropdown** sub-items (Create Listing `/marketplace/create`, My Listings `/marketplace/mine`) untested; (c) **Admin dropdown** (owner-only: Metrics/Sources/Scrapers) untested; (d) **brand logo → `/`** and Costs → `/costs` link (Costs is checked in login.spec/navigation.spec, logo is not); (e) **user-menu "Sign Out"** untested (only "Settings"); (f) no Elm-unit `viewNav` pattern-match test (`Nothing` → [Catalogue, MarketplaceBrowse, Login]). | ⚠️ | ✅ navigation.spec.ts — unauthenticated "only Catalogue and Sign In are visible … Costs under brand dropdown" asserts the negative set (`not.toContain` Library/Add Book/Search); the authenticated test asserts "Sign In link should NOT be visible when authenticated"; login.spec.ts — "navbar shows only Costs and Sign In when not authenticated". | ✅ |
| 15.2.2 | ✅ SwipeTest.elm — swipeLeft full forward sequence (Library→AntiLibrary→WishList→ReadingPile→LookingForHome→**wrap** Library) and swipeRight full reverse sequence, plus "5 left swipes from Library returns to Library" and the right-cycle equivalent. Directly covers `SwipeNavigation.swipeLeft`/`swipeRight` + modular wrap (US §12). | ✅ | ⚠️ SwipeTest.elm covers the "swipe ignored on non-bookshelf" branch well ("swipeLeft from Search/Upload/BookDetail/Home → Nothing", "swipeRight from Upload/Search → Nothing"). BUT the **port decode + Main wiring** is untested: `decodeSwipe` (string → `SwipeReceived` vs decode-failure → `SwipeIgnored`, `Main.elm:1515`) and the `SwipeReceived direction` → `Nav.pushUrl` handler (`Main.elm:1417`) have no test, and there is **no E2E** simulating an actual swipe gesture (no `touchstart`/`swipe` match in `e2e/tests/*`). Issue §2 "Swipe on non-bookshelf … ignored" is covered at the pure-function level only. | ⚠️ |
| 15.3.1 | ❌ **Feature exists, test missing.** `viewFooter` (`Main.elm:1962`) renders `footer.app-footer` with `p.app-footer__text` "The Stacks — open source book management" on every page (US §12). No unit test renders it (inline in `Main.elm`) and **no E2E asserts `app-footer`** on any page (zero `app-footer`/`footer` matches in `e2e/tests/*`). Issue §1 "Footer on every page … renders on all pages" and §1 "404 nav and footer" are both unverified. | ❌ | n/a — footer is static and always rendered; no failure mode. | n/a |
| 16.1.1 | ⚠️ **Route mapping ✅, render ❌.** RouteTest.elm — "unknown path returns NotFound" (`fromPath "/does-not-exist"`); NavigationProgramTest.elm — `navigate_not_found` (`/this/does/not/exist` → `NotFound`) verify `Route.fromUrl` → `Maybe.withDefault NotFound`. BUT the AC render assertions are **unverified**: `viewNotFound` (`Main.elm:1953`, `h1` "Page Not Found", explanation `p`, `a href="/"` "Go Home"), `pageTitle NotFound` = "Not Found — The Stacks" (`Main.elm:1665`, browser tab title), and "nav + footer remain visible on 404" (Issue §1) — none are exercised (inline in `Main.elm`, no E2E navigates to `/nonexistent-page` to assert the page). | ⚠️ | n/a — 404 **is** the sad path for navigation; there is no further failure mode below it. | n/a |
| 16.2.1 | ✅ RemoteDataTest.elm — map/withDefault/fromResult across NotAsked/Loading/Success/Failure (the type mechanics, US §12); UpdateTest.elm — "ShelvesLoaded Ok sets … shelves = Success", "BookLoaded Ok sets … book = Success" (Success path). The universal RemoteData pattern is verified. | ✅ | ⚠️ Partial. Strong pieces: UpdateTest.elm — "ShelvesLoaded NetworkError … shelves = Failure", "ShelvesLoaded 403 … showAgeGate = True", "BookLoaded NetworkError … book = Failure"; LoginTest.elm — "GotAuthResponse Err BadStatus 401 produces credential error" + Err NetworkError → Failure; LoginProgramTest.elm — `login_failure_shows_error` asserts rendered text "The door remains shut. Invalid credentials." for **401**. BUT the remaining contextual error strings in `Login.elm` (409 "already frequents these halls", 422 "properly filled", NetworkError "library is unreachable", Timeout "took too long", `Main.elm`/pages) have their **rendered text unasserted** (only 401's message is verified; other cases assert only `submitState = Failure`). Also unverified: **form-input preservation on failure** (US §2, Issue §1 — email/password/displayName retained), bookshelf/settings failure *message* text ("Could not load your books."), and **error isolation** across independent RemoteData fields. No E2E for per-status network messages. | ⚠️ |
| 16.3.1 | ⚠️ E2E auth.spec.ts — "upload page redirects to login when not authenticated" (client `requiresAuth` guard, one route) and "sign in … navigates to `/antilibrary`" / login.spec.ts — login "redirects" to `/antilibrary` cover the post-login target (US §2). BUT the **`requiresAuth` guard matrix** (US §12: `True` for all protected routes, `False` for the 11 public routes — Home, Login, CostTransparency, Catalogue, BookDetail, MarketplaceBrowse, MarketplaceDetail, BlogArchive, BlogPost, ConfirmEmail, NotFound) has **no unit test** (`requiresAuth`/`initPage` are inline in `Main.elm`, `requiresAuth`:243), and the client redirect is E2E-exercised for only **one** protected route (`/upload`). | ⚠️ | ⚠️ Sad-path client behaviours from US §12 are untested: (a) "the URL bar does NOT change to `/login` — login renders at the protected URL" (Issue Reviewer Context) has no assertion; (b) public routes rendering **without** redirect (guard returns `False`) is untested; (c) "there is currently no global 401 handler that redirects to login — each page handles the error independently" (US §2 note) is unverified. | ⚠️ |

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

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). All nine items are
**test gaps against implemented features** — no feature code is missing; the
recurring blocker is that the target functions live inline in `Main.elm`
(untestable in pure Elm), so most items resolve either via new Playwright
E2E tests in `e2e/tests/navigation.spec.ts` or by extracting the function
into a testable module.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L10 US-15.1.1 happy | Assert the **home page render**: `/` shows `h1.home__title` "The Stacks", `p.home__subtitle` "Your personal collection, beautifully organised.", `a.btn--primary[href="/antilibrary"]` "View Antilibrary", `a.btn--secondary[href="/upload"]` "Add a Book" | `e2e/tests/navigation.spec.ts` (Playwright, `goto("/")`); optionally extract `viewHome` for a `frontend/tests/` unit test |
| 2 | L10 US-15.2.1 happy | **Top-nav gaps**: assert `app-nav__item--active` on the current page; Marketplace dropdown sub-items (Create Listing `/marketplace/create`, My Listings `/marketplace/mine`); Admin dropdown (owner-only Metrics/Sources/Scrapers); brand logo → `/`; user-menu "Sign Out"; plus an Elm-unit `viewNav` auth pattern-match (`Nothing` → [Catalogue, MarketplaceBrowse, Login]) | `e2e/tests/navigation.spec.ts` + (extracted) `frontend/tests/` unit |
| 3 | L10 US-15.2.2 sad | **Swipe port + wiring**: `decodeSwipe` (valid string → `SwipeReceived`, bad payload → `SwipeIgnored`, `Main.elm:1515`) and `SwipeReceived direction` → `Nav.pushUrl` (`Main.elm:1417`); plus an E2E swipe-gesture test on a bookshelf page and a no-op swipe on a non-bookshelf page (Search/Upload/Settings) | E2E swipe spec (new or in `navigation.spec.ts`); extract `decodeSwipe`/swipe handler for unit |
| 4 | L10 US-15.3.1 happy | **Footer render on every page**: assert `footer.app-footer` with `p.app-footer__text` "The Stacks — open source book management" is present on several routes **and on the 404 page** (Issue §1 "Footer on every page" + "404 nav and footer") | `e2e/tests/navigation.spec.ts`; optionally extract `viewFooter` for unit |
| 5 | L10 US-16.1.1 happy | **404 page render**: `goto("/nonexistent-page")` → `h1` "Page Not Found", explanation copy, `a[href="/"]` "Go Home"; nav bar + footer still visible; browser tab title "Not Found — The Stacks" (`pageTitle NotFound`) | `e2e/tests/navigation.spec.ts` (Playwright can assert `page.title()`) |
| 6 | L10 US-16.2.1 sad | **Per-status error strings + form preservation**: assert the rendered Login messages for 409/422/`NetworkError`/`Timeout` (not just 401); assert form inputs (email/password/displayName) are **retained** after a failed submit; assert bookshelf/settings `p.error` failure copy; one error-isolation case (independent RemoteData fields) | `frontend/tests/Page/LoginProgramTest.elm` + `LoginTest.elm`; settings/bookshelf program tests; one E2E in `auth.spec.ts` for form preservation |
| 7 | L2 US-16.3.1 sad | **`RequireConfirmedEmail` 403 integration test**: an authenticated but `email_confirmed == false` user hitting a protected route gets HTTP 403 `{ error: "unauthorized" }` (currently only `auth_error/3` is unit-tested for `:unauthorized`) | `apps/core/test/stacks_web/` controller/pipeline test |
| 8 | L10 US-16.3.1 happy | **`requiresAuth` guard matrix + broader redirect**: unit-test `requiresAuth` returns `False` for the 11 public routes and `True` for protected routes; `initPage` guard (`requiresAuth route && maybeAuth == Nothing` → `PageLogin Login.init`); extend the E2E redirect beyond `/upload` to ≥2 more protected routes (`/library`, `/settings/consent`) | extract `requiresAuth`/`initPage` for `frontend/tests/`; `e2e/tests/auth.spec.ts` |
| 9 | L10 US-16.3.1 sad | **Client redirect edge behaviours**: URL bar stays at the protected URL when the login form renders (does not become `/login`); public routes render without any redirect; document/verify there is no global 401→login handler (each page surfaces the error itself) | `e2e/tests/auth.spec.ts` (assert `page.url()` unchanged); extracted unit for the public-route no-redirect case |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 7-US matrix (182 cells):

- **7 ✅ STRONG** — all on the two error stories where server-side coverage
  is genuinely good (US-16.3.1 Layer 1 happy + sad and Layer 2 happy via
  `auth_error_handler_test` + `unauthenticated_redirect_test`; US-16.1.1 and
  US-16.2.1 Layer 1 via `error_json_test` 404/500 templates) plus the two
  strong front-end pure-function cells (US-15.2.2 swipe happy path via
  `SwipeTest.elm`, US-16.2.1 RemoteData happy path via `RemoteDataTest.elm` +
  `UpdateTest.elm`) and the US-15.2.1 unauthenticated-nav negative set.
- **8 ⚠️ shallow** — every cell where routing/pure-function logic is tested
  but the actual **render or wiring is not**: home render, top-nav
  active-state/dropdowns, swipe port+Main wiring, 404 render + tab title,
  per-status error messages + form preservation, `RequireConfirmedEmail` 403,
  the `requiresAuth` guard matrix, and the client-redirect edge behaviours.
- **1 ❌ missing** — the platform **footer** (US-15.3.1) has zero coverage in
  any suite despite rendering on every page.
- **166 n/a** — Layers 3–9 and 11–13 for all seven stories (no DB, events,
  jobs, external services, storage, cache, dbt, metrics, or cost surface),
  plus Layers 1–2 for the pure client-side navigation stories.

**Headline findings:**
1. **The Main.elm testability wall is the dominant gap.** `viewHome`,
   `viewNav`, `viewFooter`, `viewNotFound`, `requiresAuth`, `initPage`, and
   the `SwipeReceived`/`decodeSwipe` wiring all live inline in a
   `Browser.application` module with a port and are therefore untestable in
   pure Elm (see `NavigationProgramTest.elm:6`). Every ⚠️/❌ front-end cell
   traces back to this — routing/pure-function layers are well tested
   (`RouteTest`, `SwipeTest`, `RemoteDataTest`), but the actual rendered
   output is verified nowhere. Resolution requires **Playwright E2E**
   (`navigation.spec.ts` currently covers nav clicks only) and/or extracting
   these functions into testable modules.
2. **The footer has no test at all** — the single ❌. It renders on 100% of
   page views (including the 404 page, per Issue §1) yet no unit or E2E test
   asserts `app-footer` or its tagline.
3. **Error surfacing is asymmetrically covered.** Server-side 401/403/404/500
   are solid; the client-side RemoteData *contract* is proven; but the
   user-visible payoff — contextual per-status error **messages**, form-input
   **preservation**, and the client `requiresAuth` **redirect** — is verified
   for a single case each (401 message, `/upload` redirect) and not across
   the matrix the stories enumerate.

**Test runner totals at baseline (navigation/error-related only):** Elm —
17 swipe + 10 RemoteData + Login/Update failure-path tests + 12 Route
round-trips + 4 NavigationProgram tests; Playwright — `navigation.spec.ts`
(nav clicks + unauthenticated nav) plus `auth.spec.ts`/`login.spec.ts`
redirect/error tests; Elixir — `error_json_test.exs` (2), `page_controller_test.exs`
(3), `auth_error_handler_test.exs` (3), `unauthenticated_redirect_test.exs`
(6). Punch list: **9 items**, all pure test gaps (no missing feature code);
none blocked on implementation.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.
- [ ] **Audit re-baselined to current code before test-writing** (corrections A–H from the 2026-07-25 re-verification: global interceptor, #235 CTAs/nav, #267 admin, ~18 public routes, ADR-020 route removal) — evidence: regenerated tables dated ≥2026-07-25
- [ ] **Story docs reconciled**: `US-15.1.1` CTAs updated to shipped About/Marketplace; `US-16.3.1` "no global 401 handler" note updated to shipped interceptor behaviour — evidence: doc diffs
- [ ] **Form-input preservation (US-16.2.1) verified live** — retained-input assertion in Elm program test + E2E; if live-drive finds a page clearing inputs on failure, the fix ships in-scope — evidence: live-drive artifact + spec file:line

## Dependencies
Requires Main.elm routing, SwipeNavigation module, ViewNav rendering, RemoteData pattern.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]

- **2026-07-25 (Phase 1 — testing-coordinator):** Re-baselined docs + live-drove all 7 stories against a fresh local stack (rebuilt esbuild `app.js`, `STACKS_E2E_TEST_HELPERS=1`, `AGE_GATING_ENABLED=true`, seeded dev DB, `POST /api/test/session` mint helper). **All 7 Pre-Check rows ✅ with live evidence** (see table). Highlights: home CTAs are the shipped #235 About/Marketplace pair; real touch-gesture swipe navigates `/library`→`/antilibrary` and is a no-op on `/search`; footer present on `/`, authed shelf, and 404; 404 tab title "Not Found — The Stacks". **Form-input preservation VERIFIED (no gap):** login retains email/password after a wrong-password failure, and the settings password form retains all 3 fields after a wrong-current-password 422 → Plan Phase 2b contingency (form-preservation fix) is NOT needed. Global session-expiry interceptor (#173/#178) confirmed on a page-load 401 (bookshelf-load with a revoked token → redirect `/login` + `session-expired-notice`); noted it does NOT fire on a settings-save 401 (Profile surfaces inline "Could not save profile."). Docs reconciled: `docs/user_stories/US-15.1.1-home-page.md` (CTAs → About/Marketplace) and `docs/user_stories/US-16.3.1-unauth-redirect.md` ("no global 401 handler" note → shipped interceptor + page-load-vs-save nuance).
- **2026-07-25 (Phase 3 — testing-coordinator):** Added the durable Playwright specs closing the render/wiring/behaviour punch items only E2E can prove. `e2e/tests/navigation.spec.ts` (+8 describes): home render with the shipped #235 About/Marketplace CTAs; footer `footer.app-footer` tagline on `/` (unauth), an authed bookshelf, and the 404 page; 404 page heading/explanation/Go-Home + `toHaveTitle("Not Found — The Stacks")` + nav & footer visible; real touch-gesture swipe (dispatched `TouchEvent`s, dx=-240) navigating `/library`→`/antilibrary` and a no-op on `/search`; Marketplace dropdown revealing Create Listing (`/marketplace/create`) and My Listings (`/marketplace/mine`). `e2e/tests/auth.spec.ts` (+2 describes): failed-login preserves the typed email+password (US-16.2.1); unauth `/library` renders the login form at the SAME url (URL bar unchanged) + redirect breadth across `/settings/privacy` and `/marketplace/create`. Verified against a fresh local stack (rebuilt esbuild assets, `STACKS_E2E_TEST_HELPERS=true AGE_GATING_ENABLED=true`, setup project green): the targeted nav+auth+login set is **36/36 green when run serially** (`--workers=1`). Note: at the default 4 workers the whole `auth.spec.ts` file 429s on the shared `:auth` rate-limit bucket (60/60s per IP — setup + login.spec + auth.spec logging in concurrently), a pre-existing parallelism flake unrelated to these specs; serial run is clean. Full `--project=chromium --workers=1` run: **223 passed, 58 skipped, 1 failed** — the lone failure is `age-gate.spec.ts:43` (untouched file, age-gated-seed precondition), not a regression from this phase. Non-vacuity proven by perturbation on the footer test (expected wrong tagline → received "The Stacks — open source book management") and the URL-bar test (expected `/login$` → received `http://localhost:4000/library`); both reverted via Edit. No vacuous `if (count > 0)` guards; the swipe no-op assertion is preceded by a positive-navigation test that proves the gesture path is live.
- **2026-07-25 (Phase 2 — elm-agent):** Widened `frontend/src/Main.elm`'s exposing list (exposing-only, +8 lines, no behaviour change) to export `viewHome`, `viewFooter`, `viewNotFound`, `requiresAuth`, `initPage`, `decodeSwipe`, plus `Msg(..)`/`Page(..)` needed to assert their results. Added 20 unit tests across three new files: `frontend/tests/MainViewTest.elm` (home #235 CTAs, footer tagline, 404 heading/copy/Go-Home), `frontend/tests/MainRequiresAuthTest.elm` (full 41-route `requiresAuth` matrix + 18-public/23-protected count + `initPage` login-at-URL guard, guarded by an exhaustive `expectedAuth` case so a new `Route` constructor forces a compile error), `frontend/tests/MainSwipeDecodeTest.elm` (valid→`SwipeReceived`, malformed→`SwipeIgnored`). Perturbation evidence captured (one per file, reverted via Edit). Full suite green (1116 elm-test), `elm-format --validate` clean, `elm make` clean, `elm-review --config elm-review` clean (no exposing narrowed).
