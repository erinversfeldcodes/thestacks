# Issue #060a: Elm — Marketplace Pages (Classifieds)

## Summary
Build the marketplace Elm pages: create listing, listing detail, browse, and my listings — classifieds model per ADR 013.

## User Stories
US-7.1 (listing creation — classifieds)

## Goal
Users can list books for sale with contact info, browse active listings, and manage their own listings.

## Technical Requirements
**`Page.Marketplace.CreateListing`:**
- Book selector (from user's placements via `GET /api/placements/mine`)
- Condition grader: 5 values (new, like_new, good, fair, poor) with icons
- Pricing: mode (fixed/offer), price input (ZAR)
- Contact info field (free text: email/phone/WhatsApp)
- Description textarea
- Submit via `POST /api/listings`

**`Page.Marketplace.ListingDetail`:**
- Book metadata, condition badge, price, description
- Seller contact info (visible on active listings)
- Listing status badge (draft/active/sold/expired/removed)

**`Page.Marketplace.Browse`:**
- Grid of active listings from `GET /api/listings`
- Each: book cover, title, condition, price
- Paginated (max 50 per page)

**`Page.Marketplace.MyListings`:**
- All seller's listings from `GET /api/listings/mine`
- Actions per listing: Activate (draft), Deactivate (active), Mark Sold (active)

## Scope Check
- Create 4 page modules
- ~350 LOC

## Dependencies
#057a (overlay for listing detail), #087 (sold endpoint — done)

## Definition of Done
- [ ] Create listing form works with all fields
- [ ] Listing detail shows all data + contact info
- [ ] Browse shows paginated active listings
- [ ] My Listings shows state actions
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
