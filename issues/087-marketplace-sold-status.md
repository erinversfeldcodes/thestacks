# Issue #087: Marketplace Sold Status Flow

## Summary
Add `PUT /api/listings/:id/sold` endpoint so sellers can manually mark listings as sold (classifieds model per ADR 013).

## Goal
In the classifieds model, sales happen off-platform. The seller needs a way to mark a listing as sold, which transitions it from active to sold and clears the placement denormalisation.

## Scope Check
- 1 new controller action
- 1 new route
- Context already supports active → sold transition
- ~50 LOC

## Technical Requirements
- Add `sold_listing/2` to `Stacks.Marketplace` (active → sold, sets `sold_at`)
- Add `PUT /api/listings/:id/sold` to `ListingController`
- Ownership check (only seller can mark sold)
- Emit `listing.sold` event
- Clear `listing_status` on placement (same as deactivate/expire)

## Definition of Done
- [ ] Endpoint works and enforces ownership
- [ ] State transition guarded (only active → sold)
- [ ] Placement denormalisation cleared
- [ ] Event emitted
- [ ] Tests cover happy path, ownership, invalid transition
- [ ] `just verify` passes

## Agent Assignment
elixir-agent
