# Issue #054a: Marketplace Listing CRUD + State Machine

## Summary
Build the core marketplace listing infrastructure: create, read, update, and manage listing lifecycle through a state machine (draft → active → sold/removed/expired).

## User Stories
US-8.1 — "As a user, I want to list a book for sale so others can buy it."

## Goal
Users can create fixed-price listings for books on their shelves. Listings follow a state machine lifecycle. Active listings are visible regardless of profile visibility (marketplace ceiling exception from #047).

## Scope Check
- 1 context (`Stacks.Marketplace`)
- 1 controller (`ListingController` — create, show, index, update, deactivate)
- 1 worker (`ListingExpiryJob`)
- ~300 LOC

## Wiring
- [x] This issue includes router wiring for listing endpoints.

## Technical Requirements

1. **`Stacks.Marketplace` context**:
   - `create_listing/2` — accepts user_id + attrs, validates book ownership, sets status to "draft"
   - `activate_listing/2` — transitions draft → active, sets `listed_at`
   - `deactivate_listing/2` — transitions active → removed
   - `get_listing/1`, `list_user_listings/1`, `list_active_listings/0`
   - State machine: draft → active → (sold | removed | expired)
   - Events: `listing.created`, `listing.activated`, `listing.removed`

2. **`ListingController`**:
   - `POST /api/listings` — create draft listing
   - `GET /api/listings` — list active listings (public)
   - `GET /api/listings/:id` — show listing detail
   - `PUT /api/listings/:id/activate` — activate listing
   - `DELETE /api/listings/:id` — deactivate listing
   - Authenticated except `GET` endpoints

3. **`ListingExpiryJob`** (Oban cron, daily):
   - Find active listings past `expires_at`
   - Transition to "expired", emit `listing.expired` event

4. **Listing schema** already exists at `Stacks.Marketplace.Listing`

## Reviewer Context
- The marketplace ceiling exception in `Visibility.resolve_visibility/2` allows active listings to be visible even when the seller's profile is "owner" (private).
- `op.listings` table already exists with all columns (created in Wave A migration).

## Definition of Done
- [ ] Listing CRUD works via API
- [ ] State machine transitions correctly (draft → active → sold/removed/expired)
- [ ] `ListingExpiryJob` expires stale listings
- [ ] Events emitted for lifecycle changes
- [ ] Active listings visible regardless of profile visibility
- [ ] Tests cover CRUD, state transitions, expiry, visibility
- [ ] `just verify` passes

## Dependencies
- Issue #047 (visibility marketplace exception — complete)
- Issue #043 (marketplace tables — complete)

## Agent Assignment
elixir-agent

## Progress Notes
