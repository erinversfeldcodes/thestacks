# Issue #120: E2E Test Suite — Marketplace Listings

## Summary
Comprehensive E2E test coverage for the marketplace listing lifecycle (US-7.1): create, activate, deactivate, mark sold, and automatic expiry.

## User Stories
US-7.1 (List a Book for Sale)

## Goal
Validate listing CRUD, the state machine (draft -> active -> removed/expired/sold), SELECT FOR UPDATE locking, placement denormalization, expiry job, and owner-only action enforcement.

## Scope Check
- Does this issue touch more than 3 controllers? No (ListingController, BookshelfPlacementController).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (single domain — marketplace).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Create listing flow**: Navigate to `/marketplace/create` -> select book -> set condition/pricing/contact -> submit -> see "Listing Created" success view
- **Condition grades**: All 5 radio buttons render and function (New, Like New, Good, Fair, Poor)
- **Pricing modes**: Fixed (with ZAR price input) and Open to Offers radio buttons
- **Activate listing**: Click "Activate" button on draft listing -> listing transitions to active
- **No placements state**: "You have no books to list" message when user has no placements
- **Submit disabled**: Button disabled when no placement selected or no contact info entered
- **Status badges**: Correct CSS classes for draft/active/sold/expired/removed

### 2. Playwright Navigation & Visual Tests
- **Auth guard**: Unauthenticated user at `/marketplace/create` sees login page
- **My Listings navigation**: After activation, user navigated to `/marketplace/mine`
- **Error display**: Failure states shown on create and activate errors

### 3. API Endpoint Tests
- `GET /api/placements/mine` — 200 with user's placements, 401 without auth
- `POST /api/listings` — 201 with listing in "draft" status, correct fields
- `POST /api/listings` — 422 with `no_placement` when user has no placement for book
- `POST /api/listings` — 422 on changeset errors (missing required fields, invalid condition/pricing_mode)
- `POST /api/listings` — unique constraint: one active/draft listing per book per seller
- `PUT /api/listings/:id/activate` — 200, sets `listed_at` and `expires_at` (30 days)
- `PUT /api/listings/:id/activate` — 422 `invalid_transition` if not in draft status
- `PUT /api/listings/:id/activate` — 403 `unauthorized` if not the seller
- `PUT /api/listings/:id/activate` — 404 if listing not found
- `PUT /api/listings/:id/deactivate` — 200, transitions active -> removed
- `PUT /api/listings/:id/sold` — 200, transitions active -> sold with `sold_at` set
- `GET /api/listings` — 200 with active listings, newest first, limit 50 (optional auth)
- `GET /api/listings/:id` — 200 with listing details (optional auth)
- `GET /api/listings/mine` — 200 with user's own listings, 401 without auth

### 4. Database Assertion Tests
- `op.listings` record created with correct `status: "draft"`, `seller_id`, `book_id`, `pricing_mode`, `price_cents`, `condition`, `contact_info`, `currency` (default "ZAR")
- Activate: `listed_at` and `expires_at` set, `status` changed to "active"
- Deactivate: `status` changed to "removed"
- Sold: `status` changed to "sold", `sold_at` set
- **Ecto.Multi steps**: Verify `:placement` step verifies seller has active placement
- **Ecto.Multi steps**: Verify `:locked_listing` step uses `SELECT FOR UPDATE`
- **Denormalization**: `op.bookshelf_placements.listing_status` set to "active" on activate, cleared on deactivate/sold/expire
- **Unique constraint**: `listings_active_book_seller_idx` prevents duplicate active/draft listings

### 5. Event Flow Tests
- `listing.created` emitted on draft creation with `{ book_id, seller_id }`
- `listing.activated` emitted on activate with `{ book_id, seller_id }`
- `listing.removed` emitted on deactivate
- `listing.sold` emitted on mark sold
- `listing.expired` emitted by expiry job
- All events emitted via `Events.emit_safe/1` within Ecto.Multi transactions

### 6. Background Job Tests
- `ListingExpiryJob` finds active listings past `expires_at` and calls `Marketplace.expire_listing/1`
- Expiry: listing status set to "expired", placement denormalized, event emitted
- Job runs as scheduled cron

### 7. External Service Tests
- N/A — marketplace is entirely local

### 8. Storage Tests
- N/A (condition photos are future work)

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- `stg_listings` staging view materialised
- `mart_marketplace_activity` view: `SELECT status, COUNT(*) FROM stg_listings GROUP BY status`

### 11. Elm State Machine Tests
- `Page.Marketplace.CreateListing` init: `placements = Loading`, fires `Api.getMyPlacements`
- `PlacementsReceived (Ok placements)` -> `placements = Success placements`
- `PlacementSelected`, `ConditionSelected`, `PricingModeSelected`, `PriceChanged`, `ContactInfoChanged`, `DescriptionChanged` — update respective model fields
- `SubmitListing` validation: requires `selectedPlacementId` and `contactInfo`
- `ListingCreated (Ok listing)` -> `submitState = Success`, `createdListing = Just listing`
- `ActivateListing` -> `ListingActivated (Ok _)` -> OutMsg `NavigateTo Route.MarketplaceMyListings`
- Form disabled state: submit button disabled without placement or contact info

### 12. Metrics & Telemetry Tests
- `ListingExpiryJob` Oban counts: enqueued, completed, failed
- Listing CRUD endpoint success/failure counts
- State transition counts: draft->active, active->removed/expired/sold
- Ownership verification failure count
- Unique constraint violation count

## Reviewer Context
- The `mine` route for listings is mounted before the `:id` route to avoid catch-all conflicts.
- `SELECT FOR UPDATE` locking is used in all state transition Multis to prevent race conditions.
- `contact_info` max length is 500 characters.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires marketplace context, listing controller, listing expiry job.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
