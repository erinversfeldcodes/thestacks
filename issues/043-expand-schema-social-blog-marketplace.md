# Issue #043: Expand Schema — Social, Blog, Marketplace Tables

## Summary
Create all remaining tables needed for Phase 1: social graph (user_blocks, groups, group_members, group_invitations, visibility_grants), blog (blog_posts, post_book_associations), and marketplace (offer_threads, offer_messages, listings, transactions). Add new columns to `users` and `discovered_sources`.

## User Stories
US-10.1.2, US-11.1.1, US-12.1.1, US-7.1, US-7.2, US-14.1.2, US-17.3.1, US-2.5.3

## Goal
All tables for the expanded Phase 1 scope exist in one migration wave. No schema revisits after this.

## Technical Requirements

**New tables:**
- `op.user_blocks` — `blocker_id FK`, `blocked_id FK`, unique `(blocker_id, blocked_id)`. See tech-arch section 7.
- `op.groups` — `owner_id FK`, `name`, `type ENUM(close_friends, broadcast, subscription)`, `visibility ENUM(invite_only, platform)`.
- `op.group_members` — `group_id FK`, `user_id FK`, `role ENUM(member, moderator)`, unique `(group_id, user_id)`.
- `op.group_invitations` — `group_id FK`, `invited_by FK`, `invited_user_id FK`, `status ENUM(pending, accepted, declined)`.
- `op.visibility_grants` — `resource_type TEXT`, `resource_id UUID`, `granted_to FK`, `granted_by FK`, unique `(resource_type, resource_id, granted_to)`.
- `op.blog_posts` — `user_id FK`, `title`, `body` (markdown), `visibility ENUM(owner, group, platform)`, `visibility_group_id FK NULL`, `published_at TIMESTAMPTZ NULL`.
- `op.post_book_associations` — `post_id FK`, `book_id FK`, `confidence FLOAT`, `reasoning TEXT`, `source ENUM(llm, manual)`, `visible BOOLEAN DEFAULT true`.
- `op.offer_threads` — `placement_id FK`, `buyer_id FK`, `status ENUM(open, accepted, declined, expired)`, unique `(placement_id, buyer_id)`.
- `op.offer_messages` — `thread_id FK`, `sender_id FK`, `type ENUM(message, offer, counter, accept, decline)`, `body TEXT NULL`, `amount_cents INTEGER NULL`.
- `op.listings` — `book_id FK`, `seller_id FK`, `status ENUM(draft, active, sold, removed, expired)`, `pricing_mode ENUM(fixed, offer)`, `price_cents`, `currency`, `condition ENUM`, `description`, `photo_urls TEXT[]`, `listed_at`, `expires_at`, `sold_at`.
- `op.transactions` — `listing_id FK`, `offer_id FK NULL`, `buyer_id FK`, `seller_id FK`, `amount_cents`, `currency`, `payment_provider_ref`, `payment_status ENUM`, `shipping_provider_ref`, `shipping_status ENUM`, `shipping_cost_cents`.

**Column additions:**
- `users`: `onboarding_completed BOOLEAN DEFAULT false`, `notify_wishlist_availability BOOLEAN DEFAULT false`, `notify_marketplace BOOLEAN DEFAULT true`, `notify_group_invitations BOOLEAN DEFAULT true`, `notify_event_matches BOOLEAN DEFAULT false`.
- `discovered_sources`: add `'excluded'` to status enum, `excluded_at TIMESTAMPTZ NULL`, `exclusion_email TEXT NULL`.
- `third_spaces`: `opted_out BOOLEAN DEFAULT false`, `opted_out_at TIMESTAMPTZ NULL`.

**Ecto schemas:** Create schema modules for all new tables (no context logic yet — just schemas).

## Definition of Done
- [ ] All migrations run without error (forward and rollback)
- [ ] All new Ecto schemas compile
- [ ] No existing tests broken (these are additive tables)
- [ ] `mix ecto.rollback --all && mix ecto.migrate` succeeds in CI

## Dependencies
Issue #042 (works/editions must land first — migration ordering)

## Agent Assignment
database-agent

## Progress Notes
