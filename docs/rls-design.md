# Row-Level Security Design

This document captures the PostgreSQL Row-Level Security (RLS) policies for The Stacks `op` schema. It is the companion reference for [ADR-006](decisions/006-rls-plus-application-visibility.md), which establishes RLS as the defence-in-depth backstop to the application-layer gate in [`Stacks.Visibility`](../apps/core/lib/stacks/visibility.ex) (`resolve_visibility/2` → `:visible | :hidden`).

A first slice of policies — bookshelves, bookshelf_placements, user_blocks, and visibility_grants — was activated by migration [`20260319000008_enable_rls_policies.exs`](../apps/core/priv/repo/migrations/20260319000008_enable_rls_policies.exs) alongside Issue #047 (`issues/complete/047-visibility-infrastructure.md`). Policies for the remaining tables documented below are designed but **not yet activated** — they remain future work.

---

## Overview

### Execution model

All API requests arrive through the Phoenix application. Before executing any query the connection pool sets a session variable carrying the authenticated user's UUID:

```sql
SET LOCAL app.current_user_id = '<uuid>';
```

Policies read this variable via `current_setting('app.current_user_id', true)` with a NULL guard so that sessions without the variable set (migrations, test sandbox) are not blocked. The cast to `uuid` happens only after the NULL check. The expression is inlined in every policy (no wrapper function) so each policy is self-contained and auditable.

### Database roles

Per [`20260305000020_create_db_roles.exs`](../apps/core/priv/repo/migrations/20260305000020_create_db_roles.exs) (and the login fix in `20260310000001_fix_db_role_login.exs`), three least-privilege roles exist:

- `stacks_app` — CRUD on `op`, SELECT on `wh`, INSERT-only on `audit`. The Phoenix app connects as this role in production. RLS policies are evaluated against it.
- `stacks_dbt` — SELECT on `op` + `audit`, CRUD on `wh`. Used by dbt transforms.
- `stacks_readonly` — SELECT on `op` + `wh`. Used for analytics/debugging.

There is intentionally no `stacks_owner` role — schema migrations run as the hosting provider's owner account (`neondb_owner` on Neon, `postgres` locally).

### Superuser bypass

`FORCE ROW LEVEL SECURITY` is applied to every table so that even the application database role (which may have `BYPASSRLS` disabled at the role level) cannot bypass policies. The Elixir pool user must NOT be a superuser in production.

---

## Tables with RLS active

The following tables have RLS policies enabled today (migration `20260319000008`). The exact policies in code use the NULL-guarded form `current_setting('app.current_user_id', true) IS NULL OR …` so the test sandbox and migration runner can operate without setting the session variable. The policy sketches below show the production-mode predicate; consult the migration for the full text.

| Table | Policies |
|-------|----------|
| `op.bookshelves` | `bookshelves_owner` (USING + WITH CHECK on `user_id`), `bookshelves_platform_select` (SELECT where `visibility = 'platform'`) |
| `op.bookshelf_placements` | `bookshelf_placements_owner` (USING + WITH CHECK via parent bookshelf ownership), `bookshelf_placements_platform_select` (SELECT where both placement and parent bookshelf are `'platform'`) |
| `op.user_blocks` | `user_blocks_owner` (USING + WITH CHECK on `blocker_id`) |
| `op.visibility_grants` | `visibility_grants_granter` (USING + WITH CHECK on `granted_by_id`), `visibility_grants_grantee_select` (SELECT where `granted_to_id` matches) |

All four tables also have `FORCE ROW LEVEL SECURITY` applied so even the application database role cannot bypass policies.

---

## Tables that do NOT require RLS

These tables contain public catalogue data or operational monitoring data with no user-specific sensitivity:

| Table | Reason |
|-------|--------|
| `op.books` | Public catalogue — visible to all authenticated users |
| `op.book_editions` | Public catalogue — attached to `op.books` |
| `op.authors` | Public catalogue reference data |
| `op.bookstores` | Public partner data |
| `op.price_snapshots` | Public price data |
| `op.review_snapshots` | Aggregated, anonymised review data |
| `op.discovered_sources` | Internal scraper metadata, no user PII |
| `op.bookstore_events` | Public events from partner bookstores |
| `op.third_spaces` | Public venue data |
| `op.third_space_events` | Public events |
| `op.source_health_checks` | Operational monitoring — no user data |
| `op.event_log` | Append-only domain events (application controls visibility) |

---

## Tables requiring RLS

The first four subsections — `op.bookshelves`, `op.bookshelf_placements`, `op.user_blocks`, and `op.visibility_grants` — are **active in production** (see migration `20260319000008`). The remaining subsections (`op.blog_posts` onwards) document the **designed-but-not-yet-activated** policies for marketplace, blog, and groups tables; they are reference material for a follow-up migration.

The policy SQL shown here is the production-mode predicate. The activated migration wraps each predicate with the `current_setting('app.current_user_id', true) IS NULL OR …` NULL guard described above.

---

### `op.bookshelves`

**Access rules:**
- Owner (`user_id`) can SELECT, INSERT, UPDATE, DELETE their own bookshelves.
- Other authenticated users can SELECT bookshelves where `visibility = 'platform'`.
- Group-visibility bookshelves are handled at the application layer via `op.visibility_grants` — RLS only enforces the coarse `platform` vs `owner` boundary.

```sql
-- Enable RLS
ALTER TABLE op.bookshelves ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.bookshelves FORCE ROW LEVEL SECURITY;

-- Owner: full access to own bookshelves
CREATE POLICY bookshelves_owner ON op.bookshelves
  USING (user_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (user_id = current_setting('app.current_user_id')::uuid);

-- Others: can SELECT platform-visibility bookshelves
CREATE POLICY bookshelves_platform_select ON op.bookshelves
  FOR SELECT
  USING (visibility = 'platform');
```

---

### `op.bookshelf_placements`

**Access rules:**
- Owner of the parent bookshelf can CRUD placements on their own shelves.
- Others can SELECT placements where both the placement's `visibility` and the parent bookshelf's `visibility` are `'platform'`.

```sql
-- Enable RLS
ALTER TABLE op.bookshelf_placements ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.bookshelf_placements FORCE ROW LEVEL SECURITY;

-- Owner: full access via bookshelf ownership
CREATE POLICY bookshelf_placements_owner ON op.bookshelf_placements
  USING (
    bookshelf_id IN (
      SELECT id FROM op.bookshelves
      WHERE user_id = current_setting('app.current_user_id')::uuid
    )
  )
  WITH CHECK (
    bookshelf_id IN (
      SELECT id FROM op.bookshelves
      WHERE user_id = current_setting('app.current_user_id')::uuid
    )
  );

-- Others: can SELECT platform-visible placements on platform-visible bookshelves
CREATE POLICY bookshelf_placements_platform_select ON op.bookshelf_placements
  FOR SELECT
  USING (
    visibility = 'platform'
    AND bookshelf_id IN (
      SELECT id FROM op.bookshelves WHERE visibility = 'platform'
    )
  );
```

---

### `op.blog_posts` (not yet activated)

**Access rules:**
- Author (`user_id`) can CRUD their own posts.
- Others can SELECT posts where `visibility = 'platform'`.
- Group-scoped posts (`visibility = 'group'`) are enforced at the application layer via `visibility_group_id` + `op.group_members`.

```sql
-- Enable RLS
ALTER TABLE op.blog_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.blog_posts FORCE ROW LEVEL SECURITY;

-- Author: full access to own posts
CREATE POLICY blog_posts_owner ON op.blog_posts
  USING (user_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (user_id = current_setting('app.current_user_id')::uuid);

-- Others: can SELECT platform-visibility posts
CREATE POLICY blog_posts_platform_select ON op.blog_posts
  FOR SELECT
  USING (visibility = 'platform');
```

---

### `op.offer_threads` (not yet activated)

**Access rules:**
- The buyer (`buyer_id`) can INSERT threads and SELECT/UPDATE their own threads.
- The seller (owner of the parent bookshelf placement) can SELECT and UPDATE threads on their placements.
- No other users may see offer threads.

```sql
-- Enable RLS
ALTER TABLE op.offer_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.offer_threads FORCE ROW LEVEL SECURITY;

-- Buyer: full access to own threads
CREATE POLICY offer_threads_buyer ON op.offer_threads
  USING (buyer_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (buyer_id = current_setting('app.current_user_id')::uuid);

-- Seller: can SELECT and UPDATE threads on their own placements
CREATE POLICY offer_threads_seller_select ON op.offer_threads
  FOR SELECT
  USING (
    placement_id IN (
      SELECT bp.id FROM op.bookshelf_placements bp
      JOIN op.bookshelves bs ON bs.id = bp.bookshelf_id
      WHERE bs.user_id = current_setting('app.current_user_id')::uuid
    )
  );

CREATE POLICY offer_threads_seller_update ON op.offer_threads
  FOR UPDATE
  USING (
    placement_id IN (
      SELECT bp.id FROM op.bookshelf_placements bp
      JOIN op.bookshelves bs ON bs.id = bp.bookshelf_id
      WHERE bs.user_id = current_setting('app.current_user_id')::uuid
    )
  );
```

---

### `op.offer_messages` (not yet activated)

**Access rules:**
- Participants in the parent thread (buyer and seller) can INSERT and SELECT messages.
- The sender (`sender_id`) identifies themselves; thread participation is verified via the thread.

```sql
-- Enable RLS
ALTER TABLE op.offer_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.offer_messages FORCE ROW LEVEL SECURITY;

-- Participant (buyer): access to messages in own threads
CREATE POLICY offer_messages_buyer ON op.offer_messages
  USING (
    thread_id IN (
      SELECT id FROM op.offer_threads
      WHERE buyer_id = current_setting('app.current_user_id')::uuid
    )
  )
  WITH CHECK (
    thread_id IN (
      SELECT id FROM op.offer_threads
      WHERE buyer_id = current_setting('app.current_user_id')::uuid
    )
  );

-- Participant (seller): access to messages in threads on their placements
CREATE POLICY offer_messages_seller ON op.offer_messages
  USING (
    thread_id IN (
      SELECT ot.id FROM op.offer_threads ot
      JOIN op.bookshelf_placements bp ON bp.id = ot.placement_id
      JOIN op.bookshelves bs ON bs.id = bp.bookshelf_id
      WHERE bs.user_id = current_setting('app.current_user_id')::uuid
    )
  )
  WITH CHECK (
    thread_id IN (
      SELECT ot.id FROM op.offer_threads ot
      JOIN op.bookshelf_placements bp ON bp.id = ot.placement_id
      JOIN op.bookshelves bs ON bs.id = bp.bookshelf_id
      WHERE bs.user_id = current_setting('app.current_user_id')::uuid
    )
  );
```

---

### `op.listings` (not yet activated)

**Access rules:**
- Seller (`seller_id`) can CRUD their own listings.
- All authenticated users can SELECT listings where `status = 'active'`.
- `looking_for_home` placement listings are visible to all platform users regardless of profile visibility (enforced at application layer; RLS permits the SELECT on `active` listings).

```sql
-- Enable RLS
ALTER TABLE op.listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.listings FORCE ROW LEVEL SECURITY;

-- Seller: full access to own listings
CREATE POLICY listings_seller ON op.listings
  USING (seller_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (seller_id = current_setting('app.current_user_id')::uuid);

-- All authenticated users: can SELECT active listings
CREATE POLICY listings_platform_select ON op.listings
  FOR SELECT
  USING (status = 'active');
```

---

### `op.groups` (not yet activated)

**Access rules:**
- Owner (`owner_id`) can CRUD their own groups.
- Members of the group can SELECT the group record.

```sql
-- Enable RLS
ALTER TABLE op.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.groups FORCE ROW LEVEL SECURITY;

-- Owner: full access to own groups
CREATE POLICY groups_owner ON op.groups
  USING (owner_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (owner_id = current_setting('app.current_user_id')::uuid);

-- Members: can SELECT groups they belong to
CREATE POLICY groups_member_select ON op.groups
  FOR SELECT
  USING (
    id IN (
      SELECT group_id FROM op.group_members
      WHERE user_id = current_setting('app.current_user_id')::uuid
    )
  );

-- Platform-visible groups: discoverable by all authenticated users
CREATE POLICY groups_platform_select ON op.groups
  FOR SELECT
  USING (visibility = 'platform');
```

---

### `op.group_members` (not yet activated)

**Access rules:**
- Group owner and moderators can INSERT, UPDATE, DELETE membership records for their group.
- Each member can SELECT their own membership record.
- Group owner can SELECT all membership records for their group.

```sql
-- Enable RLS
ALTER TABLE op.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.group_members FORCE ROW LEVEL SECURITY;

-- Member: can SELECT own membership
CREATE POLICY group_members_self_select ON op.group_members
  FOR SELECT
  USING (user_id = current_setting('app.current_user_id')::uuid);

-- Group owner: full access to memberships in their groups
CREATE POLICY group_members_owner ON op.group_members
  USING (
    group_id IN (
      SELECT id FROM op.groups
      WHERE owner_id = current_setting('app.current_user_id')::uuid
    )
  )
  WITH CHECK (
    group_id IN (
      SELECT id FROM op.groups
      WHERE owner_id = current_setting('app.current_user_id')::uuid
    )
  );

-- Moderator: can SELECT and manage memberships in groups they moderate
CREATE POLICY group_members_moderator ON op.group_members
  USING (
    group_id IN (
      SELECT group_id FROM op.group_members
      WHERE user_id = current_setting('app.current_user_id')::uuid
        AND role = 'moderator'
    )
  )
  WITH CHECK (
    group_id IN (
      SELECT group_id FROM op.group_members
      WHERE user_id = current_setting('app.current_user_id')::uuid
        AND role = 'moderator'
    )
  );
```

---

### `op.user_blocks`

**Access rules:**
- A user can INSERT, SELECT, UPDATE, and DELETE their own blocks (where `blocker_id` matches).
- No other user may SELECT or modify another user's block records.
- The blocked user is deliberately denied visibility of the block record (prevents gaming the system).

```sql
-- Enable RLS
ALTER TABLE op.user_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.user_blocks FORCE ROW LEVEL SECURITY;

-- Blocker: full access to own block records
CREATE POLICY user_blocks_owner ON op.user_blocks
  USING (blocker_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (blocker_id = current_setting('app.current_user_id')::uuid);
```

---

### `op.visibility_grants`

**Access rules:**
- Resource owner (`granted_by_id`) can CRUD grants they have issued.
- Grantee (`granted_to_id`) can SELECT grants that apply to them (so they know they have access, and the application can act on it).
- No other users may see grant records.

```sql
-- Enable RLS
ALTER TABLE op.visibility_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.visibility_grants FORCE ROW LEVEL SECURITY;

-- Granter (resource owner): full access to grants they issued
CREATE POLICY visibility_grants_granter ON op.visibility_grants
  USING (granted_by_id = current_setting('app.current_user_id')::uuid)
  WITH CHECK (granted_by_id = current_setting('app.current_user_id')::uuid);

-- Grantee: can SELECT grants issued to them
CREATE POLICY visibility_grants_grantee_select ON op.visibility_grants
  FOR SELECT
  USING (granted_to_id = current_setting('app.current_user_id')::uuid);
```

---

## Migration template (for the remaining tables)

The first wave (`bookshelves`, `bookshelf_placements`, `user_blocks`, `visibility_grants`) is already enabled by [`20260319000008_enable_rls_policies.exs`](../apps/core/priv/repo/migrations/20260319000008_enable_rls_policies.exs). A future migration that activates the remaining policies should follow the same NULL-guard pattern. Paste the following into a new migration file:

```sql
-- Run inside a migration. Order matters: referenced tables before referencing tables.

-- Blog
ALTER TABLE op.blog_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.blog_posts FORCE ROW LEVEL SECURITY;

-- Marketplace
ALTER TABLE op.offer_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.offer_threads FORCE ROW LEVEL SECURITY;

ALTER TABLE op.offer_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.offer_messages FORCE ROW LEVEL SECURITY;

ALTER TABLE op.listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.listings FORCE ROW LEVEL SECURITY;

-- Social
ALTER TABLE op.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.groups FORCE ROW LEVEL SECURITY;

ALTER TABLE op.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE op.group_members FORCE ROW LEVEL SECURITY;

-- Then: CREATE POLICY statements from each section above, wrapping each
-- predicate with `current_setting('app.current_user_id', true) IS NULL OR …`
-- to keep migrations and the Ecto sandbox unblocked.
```

---

## Known limitations and future work

| Limitation | Tracking |
|------------|----------|
| RLS is currently active only for `bookshelves`, `bookshelf_placements`, `user_blocks`, and `visibility_grants`. Blog, marketplace, and groups tables rely on application-layer enforcement via `Stacks.Visibility` (`resolve_visibility/2`) until a follow-up migration ships | Future |
| Group-visibility content (visibility = 'group') is enforced at the application layer only; RLS does not currently join through group_members for these cases | See Issue #150 (`issues/complete/150-visibility-grants-crud.md`) |
| Transactions table does not have a direct `user_id` column — ownership is derived via `listing_id → listings.seller_id`. An RLS policy requires a subquery; consider adding a denormalised `seller_id` column for performance | Future |
| `op.bookshelf_placement_history` is an append-only audit trail — add a SELECT-only policy mirroring `bookshelf_placements_owner` | Future |
