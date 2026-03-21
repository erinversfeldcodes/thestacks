# Issue #054b: Marketplace Payment Integration (Stitch Money)

## Summary
Integrate Stitch Money for payment processing on marketplace listings. Handle checkout flow, payment status tracking, and payment webhooks.

## User Stories
US-8.2 — "As a buyer, I want to pay for a book securely so the transaction is safe for both parties."

## Goal
Buyers can initiate payment for active listings via Stitch Money. Payment status is tracked through the transaction lifecycle. Webhook callbacks update payment status.

## Scope Check
- 1 context extension (`Stacks.Marketplace` — payment functions)
- 1 controller (`CheckoutController`)
- 1 client (`Stacks.Payments.StitchClient` — behaviour + mock)
- ~300 LOC

## Wiring
- [x] This issue includes router wiring for checkout endpoint.

## Technical Requirements

1. **`Stacks.Payments.StitchClient`** (behaviour + mock):
   - `create_payment/1` — initiates payment, returns payment URL
   - `get_payment_status/1` — checks payment status
   - Bearer token auth with Stitch API

2. **`CheckoutController`**:
   - `POST /api/listings/:id/checkout` — initiates payment, creates transaction record
   - Returns payment URL for redirect

3. **Marketplace context extensions**:
   - `create_transaction/2` — creates `op.transactions` record linked to listing
   - `update_payment_status/2` — updates transaction payment_status
   - `complete_sale/1` — transitions listing to "sold", soft-deletes seller's placement

4. **`MarketplaceSaleWorker`** (Oban):
   - Triggered after successful payment webhook
   - Completes the sale: listing → sold, placement → removed, buyer prompted to place

5. **Events**: `transaction.created`, `transaction.paid`, `listing.sold`

## Reviewer Context
- Transaction `buyer_id` and `seller_id` are nullable due to GDPR erasure (users can be deleted, transactions are retained for audit).
- Stitch Money API key configured via `STITCH_API_KEY` env var.

## Definition of Done
- [ ] Checkout creates transaction and returns payment URL
- [ ] Stitch client mocked in dev/test
- [ ] Payment status tracked on transaction record
- [ ] `MarketplaceSaleWorker` completes sale after payment
- [ ] Events emitted for transaction lifecycle
- [ ] Tests cover checkout flow, payment status updates
- [ ] `just verify` passes

## Dependencies
- Issue #054a (listing CRUD — must be complete)

## Agent Assignment
elixir-agent

## Progress Notes
