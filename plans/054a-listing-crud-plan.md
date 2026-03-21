# Plan: Issue #054a — Marketplace Listing CRUD + State Machine

## Context

All marketplace schemas (Listing, Transaction, OfferThread, OfferMessage) exist with full field sets. The marketplace context is an empty stub. Listing factory exists. The visibility module already has the marketplace ceiling exception (`placement.listing_status == "active"` in `looking_for_home`). Placement schema has denormalised listing fields (`listing_mode`, `listing_status`, `listing_price_cents`).

## Key Decisions

1. **Listings reference books, not placements** — a listing is for selling a book, not a specific shelf placement. The seller must own a placement of the book.
2. **Denormalize to placement on activate** — when a listing is activated, update the placement's `listing_status` to "active" so the visibility exception works.
3. **State machine in context, not a library** — simple case/guard transitions, no FSM dep.
4. **ListingExpiryJob** — daily cron, transitions active listings past `expires_at` to "expired".

## Implementation Steps

### Step 1: Implement Marketplace context
- `create_listing/2` — validates seller owns a placement of the book, inserts with status "draft"
- `activate_listing/2` — draft → active, sets `listed_at`, updates placement `listing_status`
- `deactivate_listing/2` — active → removed, clears placement `listing_status`
- `get_listing/1` — preloads book, seller
- `list_active_listings/0` — where status "active", ordered by listed_at desc
- `list_user_listings/1` — all listings for a seller
- State transitions: only valid transitions allowed, return `{:error, :invalid_transition}` otherwise
- Events: `listing.created`, `listing.activated`, `listing.removed`, `listing.expired`

### Step 2: Create ListingController
- `POST /api/listings` — create draft (authenticated)
- `GET /api/listings` — list active listings (public)
- `GET /api/listings/:id` — show listing detail (public)
- `PUT /api/listings/:id/activate` — activate listing (authenticated, ownership)
- `DELETE /api/listings/:id` — deactivate listing (authenticated, ownership)

### Step 3: Create ListingExpiryJob
- Oban cron daily
- Query active listings where `expires_at < now()`
- Transition each to "expired", emit `listing.expired` event

### Step 4: Wire routes
- Public: `GET /api/listings`, `GET /api/listings/:id`
- Authenticated: `POST /api/listings`, `PUT /api/listings/:id/activate`, `DELETE /api/listings/:id`

## File Inventory

### New files
- `apps/core/lib/stacks_web/controllers/listing_controller.ex`
- `apps/core/lib/stacks/workers/listing_expiry_job.ex`
- `apps/core/test/stacks/marketplace_test.exs`
- `apps/core/test/stacks_web/controllers/listing_controller_test.exs`
- `apps/core/test/stacks/workers/listing_expiry_job_test.exs`

### Modified files
- `apps/core/lib/stacks/marketplace/marketplace.ex` — implement CRUD + state machine
- `apps/core/lib/core_web/router.ex` — add listing routes
- `apps/core/config/config.exs` — add ListingExpiryJob cron
