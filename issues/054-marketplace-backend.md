# Issue #054: Marketplace Backend — Listings, Payments, Shipping

## Summary
Build the marketplace context: fixed-price listing CRUD, Stitch Money payment integration, Pargo shipping calculation, and post-sale lifecycle (buyer prompt with WishList detection).

## User Stories
US-7.1 (list for sale), US-7.2 (buy a book — with payment + shipping), US-7.3 (simplified: connect Stitch Money account)

## Goal
A user can list a book for a fixed price. Another user can buy it with Stitch Money payment and Pargo shipping. After sale, the seller's book leaves their shelf and the buyer is prompted to add it to theirs.

## Technical Requirements

**`Stacks.Marketplace` context:**
- `create_listing/2` — creates `listings` row. Listing state machine: `draft → active → sold → removed → expired`.
- `update_listing/2`, `cancel_listing/1`
- `get_listing/2` — routes through `resolve_visibility/2`. Active listings punch through profile ceiling (Issue #047).
- `buy_listing/2` — initiates Stitch Money payment, creates `transactions` row

**`Stacks.Marketplace.SellerVerification`:**
- "Connect Stitch Money Account" flow — seller provides Stitch Money account details before first listing
- Platform does age KYC at registration (Issue #047); Stitch handles FICA for payouts
- Config flag: `REQUIRE_STITCH_ACCOUNT` (false in dev)

**Stitch Money integration:**
- `Stacks.Payments.StitchClient` — `initiate_payment/1`, `verify_payment/1`
- Webhook handler: `StacksWeb.WebhookController.stitch/2` — receives payment status updates
- `PaymentCallbackJob` (Oban) — process async payment confirmations

**Pargo integration:**
- `Stacks.Shipping.PargoClient` — `calculate_shipping/2` (origin, destination → cost)
- Checkout flow: buyer enters address → Pargo calculates shipping → total = price + shipping

**Post-sale lifecycle (`MarketplaceSaleWorker`):**
- Triggered by `listing.sold` event
- Sets seller's `bookshelf_placement.removed_at` (soft-delete from Looking for a Home)
- Checks buyer's WishList for the sold book's work
- If found: prompts buyer to move from WishList to Library/AntiLibrary
- If not found: prompts buyer to add to one of their shelves
- Prompt delivered via email (if opted in) and in-platform flag on next visit

**`ListingExpiryJob` (Oban, daily):**
- Auto-expire listings older than configured TTL (default 90 days)

**Controllers:**
- `StacksWeb.ListingController` — CRUD for listings
- `StacksWeb.CheckoutController` — payment + shipping flow
- `StacksWeb.WebhookController` — Stitch Money + Pargo callbacks

**Events emitted:**
- `listing.created`, `listing.activated`, `listing.sold`, `listing.expired`, `listing.removed`

## Definition of Done
- [ ] Create listing for fixed price works via API
- [ ] Listing state machine transitions correctly (draft → active → sold)
- [ ] Stitch Money payment integration works (mocked in dev/test)
- [ ] Pargo shipping calculation works (mocked in dev/test)
- [ ] Post-sale: seller's placement soft-deleted; buyer prompted (WishList detection works)
- [ ] `ListingExpiryJob` expires stale listings
- [ ] Active listings visible to platform users regardless of profile visibility
- [ ] Webhook handlers process Stitch + Pargo callbacks
- [ ] All events emitted to event_log
- [ ] `mix test` passes with mocked Stitch/Pargo
- [ ] `mix sobelow` passes (payment flow security review)

## Dependencies
Issue #047 (visibility — marketplace listing exception), Issue #043 (marketplace tables)

## Agent Assignment
elixir-agent (Opus — payment integration, high stakes)

## Progress Notes
