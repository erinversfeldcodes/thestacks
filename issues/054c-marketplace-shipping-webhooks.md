# Issue #054c: Marketplace Shipping + Webhooks + Post-Sale

## Summary
Integrate Pargo for shipping calculation, build webhook handlers for Stitch and Pargo callbacks, and implement the post-sale buyer prompting flow.

## User Stories
US-8.3 — "As a buyer, I want to know shipping costs before I pay."
US-8.4 — "As a buyer, I want to track my delivery."

## Goal
Shipping costs are calculated before checkout. Webhook handlers process external callbacks for payment and shipping status updates. After sale, the buyer is prompted to place the book on their shelf.

## Scope Check
- 1 client (`Stacks.Shipping.PargoClient` — behaviour + mock)
- 1 controller (`WebhookController`)
- 1 context extension (`Stacks.Marketplace` — shipping + post-sale)
- ~300 LOC

## Wiring
- [x] This issue includes router wiring for webhook endpoint.

## Technical Requirements

1. **`Stacks.Shipping.PargoClient`** (behaviour + mock):
   - `calculate_shipping/2` — accepts origin + destination, returns cost in cents
   - `create_shipment/1` — creates shipment booking, returns tracking reference

2. **Checkout extension** (in `Stacks.Marketplace`):
   - `calculate_shipping_cost/2` — calls PargoClient, caches result on transaction
   - Add `shipping_cost_cents` to checkout flow

3. **`WebhookController`**:
   - `POST /api/webhooks/stitch` — handles payment status callbacks
   - `POST /api/webhooks/pargo` — handles shipping status callbacks
   - HMAC signature verification on incoming webhooks
   - Idempotent processing (same webhook ID processed once)

4. **Post-sale flow**:
   - After payment confirmed: create shipment via Pargo
   - Update `shipping_status` on transaction
   - Emit `transaction.shipped`, `transaction.delivered` events
   - Prompt buyer to place book on their shelf (via notification event)

5. **Events**: `transaction.shipping_created`, `transaction.shipped`, `transaction.delivered`

## Reviewer Context
- Webhook endpoints must be unauthenticated (external services call them) but HMAC-verified.
- Pargo API key configured via `PARGO_API_KEY` env var.
- `shipping_status` on transactions is nullable (not all transactions involve shipping).

## Definition of Done
- [ ] Shipping cost calculated before checkout
- [ ] Pargo client mocked in dev/test
- [ ] Webhook handlers process Stitch + Pargo callbacks
- [ ] HMAC verification on webhooks
- [ ] Post-sale: shipment created, status tracked, buyer prompted
- [ ] Events emitted for shipping lifecycle
- [ ] Tests cover shipping calculation, webhook processing, post-sale
- [ ] `mix sobelow` passes (webhook security review)
- [ ] `just verify` passes

## Dependencies
- Issue #054b (payment integration — must be complete)

## Agent Assignment
elixir-agent

## Progress Notes
