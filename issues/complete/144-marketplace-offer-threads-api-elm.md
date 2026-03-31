# Issue #144: Marketplace — Seller Listing Management UI

## Summary
Build the seller-facing listing management page. Sellers can create draft listings, activate them, mark as sold, and deactivate. The backend is already complete from #054a. This issue is Elm-only.

## User Stories
US-13.1 Create and manage a listing, US-7.2 (seller workflow)

## Goal
An authenticated user can manage their own listings at `/marketplace/mine` — create a new draft listing, publish it, mark it as sold when negotiated offline, or remove it.

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
GET  /api/listings/mine              → {listings: [...], total: n}  (auth required)
POST /api/listings                   → create draft                  (auth required)
PUT  /api/listings/:id/activate      → draft → active               (auth required)
PUT  /api/listings/:id/sold          → active → sold                (auth required)
PUT  /api/listings/:id/deactivate    → active → removed             (auth required)
```

**Listing create fields:** `book_id` (UUID), `pricing_mode` (`fixed` | `offer`), `price_cents` (integer), `condition` (`new` | `like_new` | `good` | `fair` | `poor`), `description` (text), `contact_info` (text, required).

**Elm additions:**

`Page.Marketplace.Mine`:
- Requires auth — redirect to login if unauthenticated
- On mount: `GET /api/listings/mine`
- Shows user's listings grouped by status: Active, Draft, Sold/Removed
- Each listing row has status-appropriate action buttons: Draft → Activate / Delete; Active → Mark Sold / Deactivate
- "New Listing" button opens `Components.ListingForm`

`Components.ListingForm`:
- Fields: book search (by title — uses existing book search), pricing mode toggle, price input, condition select, description textarea, contact_info input
- Validates contact_info non-empty before submit
- On submit: `POST /api/listings` then optionally `PUT /api/listings/:id/activate`

**Route:** Add `/marketplace/mine` to `Main.elm`. Link from the main marketplace page for authenticated users.

## Reviewer Context
- `GET /api/listings/mine` requires auth — use `Guardian.Plug.current_resource(conn)`.
- `contact_info` is the seller's preferred contact method (phone, email, WhatsApp handle, etc.) — plain text.
- `price_cents` is in ZAR cents; display as `R xxx.xx`.
- No offer threads, Q&A, or in-app messaging — out of scope.

## Definition of Done
- [ ] `/marketplace/mine` renders seller's listings grouped by status
- [ ] Draft listing has Activate and Delete action buttons
- [ ] Active listing has Mark Sold and Deactivate buttons
- [ ] New Listing form validates `contact_info` non-empty before submitting
- [ ] Unauthenticated access redirects to login
- [ ] Elm unit tests cover form validation and listing state transitions
- [ ] `just verify` passes

## Dependencies
#143 (marketplace browse page), #054a (listing CRUD — complete)

## Agent Assignment
elm-agent

## Progress Notes
