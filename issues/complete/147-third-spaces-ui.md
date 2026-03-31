# Issue #147: Third Spaces — Browse Page & Book Detail Integration

## Summary
Build the user-facing Third Spaces cork board (US-3.1) and wire partner inventory into the book detail overlay. Users can browse local bookshops, cafés, and reading groups on a cork-board-style page. The book detail page gains an "Available at" section showing which partners stock the book.

## User Stories
US-3.1 Browse Third Spaces, US-9.7 Partner Reader Experience, US-9.8 (partial: book detail availability)

## Goal
A user visiting `/third-spaces` sees a cork-board grid of local venues and reading groups. Clicking a space opens a detail panel with upcoming events and stock. A book detail overlay includes an "Available at" section showing price and condition at nearby partners.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `ThirdSpaceController` (read-only), additions to `BookController`.
- Does this issue add more than 2 new endpoints? → No — `GET /api/third-spaces`, `GET /api/books/:id/availability`.
- Does this issue exceed ~300 lines of production code? → Elm-heavy; likely 300–400 LOC Elm. Split Elm from Elixir if needed.
- Does this issue combine unrelated concerns? → Third spaces browse + book availability are coupled (both surface partner inventory).

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**API endpoints:**
```
GET /api/third-spaces?lat=<f>&lng=<f>&radius_km=<n>
  # Returns partner third spaces sorted by distance
  # Falls back to listing all if no geo params

GET /api/books/:id/availability
  # Returns partner_inventory rows for this book's editions
  # Grouped by partner: [{partner_name, location, price_cents, condition, quantity}]
```

**`Stacks.Enrichment` additions:**
```elixir
list_third_spaces(opts \\ [])
  # opts: [lat: f, lng: f, radius_km: n, limit: 20]
  # → [ThirdSpace with upcoming_events: [ThirdSpaceEvent]]

book_availability(book_id)
  # → [{partner: Partner, edition: BookEdition, price_cents: int, condition: string, quantity: int}]
  # Only returns entries where quantity > 0
```

**`Page.ThirdSpaces` (new Elm page at `/third-spaces`):**
- Cork-board grid layout (card per space)
- Each card: name, type badge (bookshop/café/reading_group), address, upcoming events count
- Clicking a card opens `Components.ThirdSpaceDetail` overlay showing:
  - Full description
  - Upcoming events list
  - "View on map" link (Google Maps URL)
- Empty state if no third spaces yet: "No spaces in your area yet — we're growing!"
- Location-aware: if user has location set in settings, default `lat`/`lng` from profile

**`Page.BookDetail` additions:**
- New "Available at" tab/section below book description
- If `availability` API returns empty: hide section entirely
- Each row: partner name, condition badge, price (in ZAR), "View" link to partner's listing (if applicable)

**Route:** Add `/third-spaces` to `Main.elm` routing.

## Reviewer Context
- `ThirdSpace` and `ThirdSpaceEvent` schemas already exist in `lib/stacks/gen/enrichment/`.
- User location is stored on `users.latitude`, `users.longitude` (nullable floats). Pass these from the session when calling the API.
- Use the existing `Components.Overlay` pattern for the detail panel — do not build a new overlay primitive.
- Geo query: use PostGIS `ST_DWithin` if available, otherwise Haversine formula in Elixir (acceptable for MVP).

## Definition of Done
- [ ] `/third-spaces` renders with at least the empty state when no data
- [ ] Third space cards show type, name, address, and upcoming event count
- [ ] Detail overlay opens on card click with events list
- [ ] `GET /api/books/:id/availability` returns grouped partner stock
- [ ] Book detail overlay shows "Available at" section when stock exists
- [ ] Section hidden when `availability` returns empty array
- [ ] Elm unit tests for all Msg handlers
- [ ] API integration tests for both endpoints
- [ ] `just verify` passes

## Dependencies
#145 (Partner entity), #146 (Inventory sync — data source)

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
