# Runbook: Stitch Money Payment Failure

**Severity:** P1 (marketplace sales blocked — financial impact)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

---

> **Status: Deferred — not yet integrated.**
>
> Per [ADR-013: Marketplace as Classifieds Board, Not E-Commerce](../decisions/013-marketplace-classifieds-first.md), Stitch Money payment integration ([Issue #054b](../../issues/054b-marketplace-payment-integration.md)) is deferred indefinitely. Phase 1 marketplace is a classifieds board — buyers and sellers transact off-platform via contact info on the listing.
>
> No `Stacks.Payments.StitchClient`, `CheckoutController`, or `Stacks.Marketplace.Payment` module currently exists. The `op.transactions` table exists in the schema but no application code reads from or writes to it. There is no `STITCH_API_KEY` or `STITCH_WEBHOOK_SECRET` configured on Fly.io.
>
> This runbook is retained as a reference for when #054b is picked up. The diagnosis/response/recovery steps below assume an integration that has not been built yet — do not attempt to run them against current production. Until then, marketplace failures are listing-related, not payment-related (`Stacks.Marketplace` listings work; transactions don't).

---

## Symptoms

**User sees:**
- Checkout returns an error after submitting payment
- "Payment could not be processed — please try again" message
- Payment confirmation email never arrives (buyer)
- Sale notification never arrives (seller)

**Operator sees:**
- `transactions.payment_status = 'failed'` rows accumulating
- Oban `notifications` queue: `PaymentFailedJob` events
- Phoenix logs: Stitch Money API errors (HTTP 4xx/5xx on payment initiation endpoint)
- In Stitch Money dashboard: failed payment attempts or webhook delivery failures

---

## Impact

**Broken:**
- Marketplace checkout (fixed-price purchases)
- Payment initiation and confirmation
- Seller payouts (if applicable)

**Still working:**
- All non-marketplace features (shelves, search, upload, enrichment)
- Marketplace browsing and listing creation
- Existing listings remain active
- No money has moved for failed transactions — buyers are not charged

---

## Diagnosis

### Step 1: Check Stitch Money status

Visit [https://status.stitch.money](https://status.stitch.money) (or Stitch Money's status page if this URL is incorrect — confirm in the Stitch Money dashboard).

Also check the Stitch Money dashboard at [https://dashboard.stitch.money](https://dashboard.stitch.money):
- Recent failed payments
- API error rates
- Webhook delivery logs

### Step 2: Check Phoenix logs for the specific error

```bash
fly logs -a thestacks-core | grep -i "stitch\|payment\|checkout" | tail -50
```

Common error patterns:
- `HTTP 401 Unauthorized` — API key expired or invalid
- `HTTP 400 Bad Request` — malformed payment request (check request body)
- `HTTP 503 Service Unavailable` — Stitch Money is down
- `Connection timeout` — network issue between Fly.io and Stitch Money

### Step 3: Check recent transaction failures

```sql
-- Failed transactions in the last 24 hours
SELECT id, buyer_id, seller_id, amount_cents, payment_status, payment_provider_ref, created_at
FROM transactions
WHERE payment_status = 'failed'
  AND created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC;
```

If `payment_provider_ref` is NULL: the payment was never initiated (request failed before reaching Stitch).
If `payment_provider_ref` is set: Stitch received the request — check the Stitch dashboard for that reference.

### Step 4: Verify Stitch Money API key

```bash
fly secrets list -a thestacks-core | grep STITCH
```

The `STITCH_API_KEY` must be present and current. Stitch Money may rotate API keys with expiry dates.

Test the API key directly:
```bash
fly ssh console -a thestacks-core
```
```elixir
iex> Stacks.Marketplace.Payment.ping()
# Should return :ok
# If {:error, :unauthorized}: the API key is invalid
```

### Step 5: Check webhook configuration

Stitch Money sends webhooks for payment confirmations. If webhooks are failing:

```bash
# Check Oban for failed webhook handling jobs
SELECT worker, errors, attempted_at FROM oban_jobs
WHERE worker LIKE '%Webhook%' AND state IN ('retrying', 'discarded')
ORDER BY attempted_at DESC LIMIT 10;
```

Also verify in the Stitch Money dashboard that the webhook URL is set correctly:
- Expected URL: `https://thestacks.app/api/webhooks/stitch`
- Stitch should be sending `payment.completed` events to this URL

---

## Response

### If Stitch Money is reporting an incident

1. Do not retry payments manually — no money has moved for failed transactions.
2. Listings remain active — buyers can complete the purchase when Stitch Money recovers.
3. Communicate the payment outage to affected buyers if they have contacted support.
4. Monitor Stitch Money's status page for recovery.

### If the API key has expired or been rotated

```bash
# Get the new API key from the Stitch Money dashboard
# Then update the Fly.io secret
fly secrets set STITCH_API_KEY="sk_live_newkey..." -a thestacks-core
```

After updating, the app restarts automatically. Test a payment in a staging environment before confirming production recovery.

### If the webhook URL is misconfigured

In the Stitch Money dashboard, update the webhook endpoint:
- Development: `https://thestacks-preview-<branch>.fly.dev/api/webhooks/stitch`
- Production: `https://thestacks.app/api/webhooks/stitch`

Also verify the webhook secret matches:
```bash
fly secrets list -a thestacks-core | grep STITCH_WEBHOOK_SECRET
```

The webhook secret must match the value configured in the Stitch Money dashboard.

### If the request format has changed (Stitch API update)

HTTP 400 responses may indicate Stitch Money updated their API. Check:
1. Stitch Money's changelog/release notes in the developer portal
2. The request body being sent in Phoenix logs
3. Compare against the Stitch Money API documentation

This requires a code fix. In the interim, disable checkout to avoid confusing users:
```bash
# Feature flag approach (if implemented)
fly secrets set MARKETPLACE_ENABLED=false -a thestacks-core
```

---

## Recovery

**Self-healing (most common — Stitch outage resolves):**
- Stitch Money recovers.
- Buyers retry their purchases.
- No operator action needed for previously failed transactions — they are already `payment_status = 'failed'` and buyers can attempt new transactions.

**Verify recovery:**
```bash
# Test checkout in staging environment first
# Then monitor production transaction table
```

```sql
SELECT payment_status, count(*) FROM transactions
WHERE created_at > NOW() - INTERVAL '1 hour'
GROUP BY payment_status;
```

Expected: `pending` and `paid` status counts increasing, `failed` count not growing.

**For failed transactions where buyers were charged but the platform doesn't know:**

In rare cases, Stitch may have processed a charge but the webhook was not delivered (network issue). Check the Stitch dashboard for `payment.completed` events that do not have corresponding `payment_status = 'paid'` rows in the transactions table.

```sql
-- Transactions that Stitch may have completed but platform doesn't know about
SELECT id, payment_provider_ref FROM transactions
WHERE payment_status = 'failed'
  AND payment_provider_ref IS NOT NULL
  AND created_at > NOW() - INTERVAL '24 hours';
```

For each `payment_provider_ref`, verify in the Stitch dashboard. If Stitch shows the payment as `completed`, manually update the transaction:

```sql
-- Manual recovery (requires operator access)
UPDATE transactions
SET payment_status = 'paid', completed_at = NOW()
WHERE id = '<transaction_id>';
```

Then emit the appropriate `transaction.completed` event to trigger the seller notification Oban job.

---

## Post-Incident

- Document the failure cause and the recovery steps taken.
- If API key expiry caused the issue: set a calendar reminder 30 days before the API key's expiry date.
- If webhook delivery was the issue: consider implementing a polling fallback that checks Stitch for the payment status of pending transactions that are > 30 minutes old without a webhook.
- Review Stitch Money's SLA and compare it to the platform's uptime expectations.
