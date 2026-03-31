# Issue #143: Marketplace — Browse UI (contact-info only)

## Summary
Build the Elm marketplace browse page. The backend is already complete from #054a. Listings include a `contact_info` field for offline negotiation — no in-app messaging, offer threads, or Q&A. This issue is Elm-only.

## User Stories
US-13.1 Browse active listings, US-7.2 (listing visibility)

## Goal
A user (authenticated or not) can browse active listings at `/marketplace`, click a listing card to see its detail overlay, and find the seller's contact information for offline negotiation.

## Scope Check
- Does this issue touch more than 3 controllers? → No — no backend changes.
- Does this issue add more than 2 new endpoints? → No — all endpoints already exist.
- Does this issue exceed ~300 lines of production code? → ~250 LOC Elm.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes Elm route wiring and is user-facing when complete.

## Technical Requirements

**Existing API (no changes needed):**
```
GET /api/listings          → {listings: [...], total: n}   (no auth required)
GET /api/listings/:id      → {listing: {...}}               (no auth required)
```

**Listing fields available:** `id`, `status`, `pricing_mode` (`fixed` | `offer`), `price_cents`, `currency` (`ZAR`), `condition`, `description`, `contact_info`, `photo_urls`, `listed_at`, `book` (title, author), `seller` (display_name).

**Elm additions:**

`Page.Marketplace`:
- On mount: `GET /api/listings` → show card grid
- `Components.ListingCard`: book title, author, condition badge, price formatted as ZAR, pricing mode badge (`Fixed Price` | `Open to Offers`)
- Clicking a card opens a detail overlay (`Components.ListingDetail`)
- `Components.ListingDetail`: all listing fields, `contact_info` prominently displayed, photo gallery if `photo_urls` non-empty
- Empty state: "No listings yet" with dark-academic styling
- Loading and error states

**Route:** Add `/marketplace` to `Main.elm`. Add nav link in the main navigation.

**No auth required** — listing browse is public.

## Reviewer Context
- `GET /api/listings` is already wired and returns active listings only.
- `contact_info` is a plain text field — render as-is (phone, email, or free-text).
- Price formatting: `price_cents / 100` formatted as `R xxx.xx` (ZAR).
- No offer thread, Q&A, or messaging UI — those are deferred indefinitely.

## Definition of Done
- [ ] `/marketplace` renders active listing cards; shows empty state when none
- [ ] Listing card shows: book title, author, condition, price as ZAR, pricing mode badge
- [ ] Clicking a card opens detail overlay with `contact_info` visible
- [ ] Unauthenticated users can browse without being redirected to login
- [ ] Elm unit tests cover `Loading → Loaded` and `Loading → Failed` transitions
- [ ] `just verify` passes

## Dependencies
#054a (listing CRUD + state machine — complete, backend done)

## Agent Assignment
elm-agent

## Progress Notes
