# Issue #152: Notification Trigger Wiring

## Summary
Email templates exist for group invitations, WishList availability, and offer notifications. The Oban infrastructure for email delivery (`EmailDeliveryJob`) exists. What's missing is the glue: the event subscribers that receive domain events and enqueue delivery jobs. Currently none of these templates are ever sent.

## User Stories
US-11.1.2 (group invitation email), US-7.2 (offer received email), US-6.x (WishList availability email)

## Goal
Three notification triggers are wired to the event bus:
1. `group.invitation_sent` → send invitation email to invitee
2. `offer.opened` → send "new offer" email to listing seller
3. `wishlist.book_available` → send "book is now available" email to users who wishlisted it

All triggers respect user notification preferences (`users.notify_*` flags).

## Scope Check
- Does this issue touch more than 3 controllers? → No — no controllers; Oban subscribers only.
- Does this issue add more than 2 new endpoints? → No — no endpoints.
- Does this issue exceed ~300 lines of production code? → No — 3 subscribers + tests ~150 LOC each.
- Does this issue combine unrelated concerns? → All are notification dispatch; acceptable together.

## Wiring
- [x] This issue is implementation only. Triggered by domain events.

## Technical Requirements

**`Stacks.Notifications.GroupInvitationSubscriber`** (Oban subscriber):
- Subscribes to `group.invitation_sent`
- Looks up invitee user by `invitee_id` in event payload
- If `user.notify_group_invitations == true` (add this flag if missing): enqueues `EmailDeliveryJob` with template `group_invitation`
- Template data: inviter name, group name, accept URL (`/groups/invitations/:id/accept`)

**`Stacks.Notifications.OfferNotificationSubscriber`**:
- Subscribes to `offer.opened`
- Looks up seller via `listing.seller_id`
- If `user.notify_offers == true` (add this flag if missing): enqueues `EmailDeliveryJob` with template `new_offer`
- Template data: buyer display name, listing title, offer amount (formatted ZAR), offer URL

**`Stacks.Notifications.WishlistAvailabilitySubscriber`**:
- Subscribes to `listing.activated` (partner pushes stock or seller activates a listing)
- For each active listing: check `book_editions.isbn` against WishList placements
- For each matching WishList entry: if `user.notify_wishlist_availability == true` → enqueue email
- Template data: book title, author, price, seller/partner name, buy URL
- Debounce: use an Oban unique job (by book_id + user_id, TTL 24h) to avoid repeated emails if stock fluctuates

**User flag migration:**
```sql
ALTER TABLE op.users
  ADD COLUMN IF NOT EXISTS notify_group_invitations boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS notify_offers            boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS notify_wishlist_availability boolean NOT NULL DEFAULT true;
```

**Register subscribers** in `Stacks.Application` alongside existing subscribers.

## Reviewer Context
- `EmailDeliveryJob` is already implemented — check its argument shape before calling.
- All three subscribers follow the same pattern as `Stacks.Subscribers.DbtRefreshSubscriber` — match its structure exactly.
- WishList detection: placements on the `wishlist` bookshelf (name = `"wishlist"`) for the relevant book. Use `Stacks.Shelving.book_on_shelf?/3` if it exists; otherwise query directly.
- Oban unique job for debounce: `unique: [fields: [:args], keys: [:book_id, :user_id], period: 86_400]`.

## Definition of Done
- [ ] `group.invitation_sent` event triggers invitation email (respects `notify_group_invitations` flag)
- [ ] `offer.opened` event triggers new-offer email to seller (respects `notify_offers` flag)
- [ ] `listing.activated` triggers wishlist availability email only to users with book on wishlist
- [ ] Wishlist availability emails are deduplicated within 24h per book+user pair
- [ ] Users with notification flag set to false receive no email
- [ ] Tests for each subscriber: happy path + opt-out path + deduplication
- [ ] `just verify` passes

## Dependencies
#138 (Groups — group invitation events must be emitted), #143 (Marketplace offers — offer.opened event), #054 (Marketplace listings — listing.activated event)

## Agent Assignment
elixir-agent

## Progress Notes
