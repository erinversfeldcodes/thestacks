# ADR 013: Marketplace as Classifieds Board, Not E-Commerce

**Status:** Accepted
**Date:** 2026-03-21
**Deciders:** Platform owner
**Technical area:** Marketplace scope, product direction

---

## Context

The marketplace feature was originally planned as a three-phase build:

- **#054a** — Listing CRUD + state machine (draft → active → sold/removed/expired)
- **#054b** — Stitch Money payment integration (checkout, payment tracking, webhooks)
- **#054c** — Pargo shipping integration (cost calculation, label generation, webhooks)

This would make The Stacks a full e-commerce platform with payments, shipping, and on-platform transaction flow. After implementing #054a, we reassessed whether this scope is appropriate for phase 1.

## Decision

**Phase 1 marketplace is a classifieds board, not an e-commerce platform.**

Sellers list books they want to sell. Interested buyers see the listing and contact the seller directly using contact information provided on the listing. The platform does not facilitate payments, shipping, or on-platform messaging.

### What this means

| Feature | Phase 1 | Future |
|---------|---------|--------|
| List books for sale | Yes (#054a) | — |
| Browse/search active listings | Yes (#054a) | — |
| Seller contact info on listings | Yes (new `contact_info` field) | — |
| Listing state machine (draft/active/expired/removed) | Yes (#054a) | — |
| Listing expiry (30-day TTL) | Yes (#054a) | — |
| On-platform payment (Stitch Money) | No | #054b when needed |
| On-platform shipping (Pargo) | No | #054c when needed |
| On-platform messaging / offer threads | No | Future issue when needed |
| Transaction records | No | Comes with #054b |

### What we keep from the original schema

The `transactions`, `offer_threads`, and `offer_messages` tables exist in the database (created in migration `20260319000005`). They stay — dropping them would require a new migration for no benefit, and they'll be used when payments are introduced. No application code references them.

## Rationale

1. **Complexity vs. value** — Payment and shipping integration require external provider accounts (Stitch Money, Pargo), API keys, webhook infrastructure, and compliance work (PCI, refund handling). This is significant effort for a platform that doesn't yet have users.

2. **Validation first** — A classifieds model lets us validate whether users want to sell books through the platform before investing in payment rails. If listing activity is low, payments would be wasted effort.

3. **Liability** — Facilitating payments creates financial liability (refunds, disputes, fraud). A classifieds model keeps transactions between buyer and seller, off-platform.

4. **Simplicity** — Contact info on the listing is one field. Payment integration is three issues, two external providers, webhook handlers, and financial record-keeping.

## Implementation

Add an optional `contact_info` text field to the `listings` table and schema. Sellers provide their preferred contact method (email, phone, WhatsApp, etc.) when creating or activating a listing. This field is visible on active listings to any viewer.

## Consequences

- Users handle payment and delivery themselves — the platform has no visibility into whether a sale completed
- The `sold` status in the state machine becomes seller-managed (they mark it sold manually) rather than system-managed (triggered by payment confirmation)
- #054b and #054c are deferred indefinitely, not cancelled — the schema supports them when needed
- OfferThread/OfferMessage schemas remain unused until on-platform messaging is built
