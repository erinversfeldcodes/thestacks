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

## Technical Requirements

### 1. Playwright UI Tests
- **Home page unauthenticated**: Navigate to `/` -> see "The Stacks" title, subtitle, action buttons
- **Home page buttons**: "View Antilibrary" and "Add a Book" links present with correct hrefs
- **Top nav authenticated**: Full nav items: Library, Antilibrary, Wish List, Reading Pile, Looking for a Home, Catalogue dropdown, Marketplace dropdown, user display name
- **Top nav unauthenticated**: Only Catalogue, Marketplace, Sign In
- **Brand dropdown**: "The Stacks" logo links to `/`, Costs link to `/costs`
- **Catalogue dropdown**: Sub-items Catalogue, Search, Add Book
- **Marketplace dropdown**: Sub-items Marketplace, Create Listing, My Listings
- **Admin dropdown (owner only)**: Metrics, Sources, Scrapers
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
- **requiresAuth**: Returns `False` for Home, Login, CostTransparency, Catalogue, BookDetail, MarketplaceBrowse, MarketplaceDetail, BlogArchive, BlogPost, ConfirmEmail, NotFound; `True` for all others
- **initPage guard**: If `requiresAuth route && maybeAuth == Nothing` -> `( PageLogin Login.init, Cmd.none )`
- **Nav rendering**: `viewNav` pattern-matches `model.auth`:
  - `Nothing` -> `[Catalogue, MarketplaceBrowse, Login]`
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
- The home page currently renders for authenticated users too (no auto-redirect to `/antilibrary`).
- Swipe wraps around via `modBy` (spec says "does nothing at boundaries" but implementation wraps).
- The login form URL bar does NOT change to `/login` when the requiresAuth guard fires — login renders at the protected URL.
- `EscapePressed` handler closes overlays first, then user menu if no overlay open.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires Main.elm routing, SwipeNavigation module, ViewNav rendering, RemoteData pattern.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
