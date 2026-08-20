# ADR 006: Row-Level Security Plus Application-Layer Visibility (Defence in Depth)

**Status:** Accepted
**Date:** 2026-03-05
**Deciders:** Platform owner
**Technical area:** Security, data access control, multi-user

---

## Context

The Stacks is a multi-user platform with a nuanced visibility model:

- Users have a profile-level visibility (`owner` | `platform`)
- Bookshelves have their own visibility (`owner` | `group` | `platform`), bounded by the profile ceiling
- Individual placements can be more restrictive than their bookshelf
- Users can block each other — blocks are bidirectional in effect
- Active marketplace listings punch through the profile visibility ceiling (always visible to platform users)
- The `looking_for_home` bookshelf defaults to `platform` visibility

This creates a multi-dimensional access control problem: who can see what, given profile visibility, bookshelf visibility, placement visibility, group membership, and block status?

**Two enforcement mechanisms were considered:**

**Option A — Application layer only (`resolve_visibility/2`):**
All visibility decisions made in Elixir code. Database has no access restrictions beyond role-based grants. A bug in `resolve_visibility/2` leaks data.

**Option B — Database RLS only:**
All visibility enforced via PostgreSQL Row-Level Security policies. Application layer queries without visibility filters. A misconfigured RLS policy leaks data (or denies legitimate access).

**Option C — Both (defence in depth):**
Application layer (`resolve_visibility/2`) is the primary enforcement path — it has full business logic context (block graph, group membership, ceiling rules). Database RLS is a secondary safety net — it enforces the broadest access constraints at the storage layer independently of application code.

---

## Decision

**Use both application-layer visibility enforcement (`resolve_visibility/2`) and database Row-Level Security. Defence in depth.**

**Application layer: `Stacks.Visibility.resolve_visibility/2`**

This is the primary gate. Called before any content is returned to a user. It resolves the effective visibility for a resource given:
- The requesting user (or anonymous)
- The resource owner
- The resource's visibility setting
- The owner's profile ceiling
- Group membership (if `visibility = 'group'`)
- Block status (if either party has blocked the other)
- Marketplace listing exception (active listings ignore profile ceiling)

The function returns `:visible | :hidden` (see `Stacks.Visibility.resolve_visibility/2` in `apps/core/lib/stacks/visibility.ex`). Callers that need to distinguish "blocked" from "absent" (for example, to return 404 instead of 403 when a blocked user looks up a blocker's profile) layer that decision on top of the visibility result.

**Database layer: Row-Level Security**

RLS policies are designed early in Phase 1 (MVP) alongside the migrations, and enforced once the visibility contexts pass their tests. They enforce the coarsest access rules:

| Table | RLS policy |
|-------|-----------|
| `bookshelf_placements` | `stacks_app` role can only read/write rows where `bookshelf_id` belongs to the authenticated user, except marketplace listings (`listing_status = 'active'`) which are readable by all platform users |
| `blog_posts` | `stacks_app` role can only write rows where `user_id = current_user_id`. Read access filtered by visibility column |
| `offer_threads` / `offer_messages` | Scoped to `(placement_id, buyer_id)` — only the buyer and the listing owner can read |

RLS policies are documented in `docs/rls-design.md` and enabled by migration `apps/core/priv/repo/migrations/20260319000008_enable_rls_policies.exs`.

**Database roles:**
- `stacks_app` — CRUD on `op`, SELECT on `wh`, INSERT-only on `audit`. This is the role the Phoenix app uses.
- `stacks_dbt` — SELECT on `op` + `audit`, CRUD on `wh`. Used by dbt transforms.
- `stacks_readonly` — SELECT on `op` + `wh`. Used for analytics/debugging.

**Enforcement order:**
1. Phoenix controller calls `Stacks.Visibility.resolve_visibility/2` → returns `:hidden` or `:not_found` → 403/404 before any DB query.
2. If `:visible`, the Ecto query runs. RLS policies on the DB-side enforce the storage-layer constraints independently.

---

## Consequences

**Positive:**
- A bug in `resolve_visibility/2` that incorrectly returns `:visible` is still blocked by RLS at the database layer.
- A misconfigured RLS policy is still blocked by `resolve_visibility/2` at the application layer.
- Two independent failure modes must both fail simultaneously to leak data — the probability is substantially lower than either alone.
- `stacks_app` role cannot access data it's not supposed to even if application code is compromised (SQL injection, for example, is bounded by RLS).
- The separate DB roles (`stacks_dbt`, `stacks_readonly`) ensure that dbt and analytics queries cannot write operational data even if those processes are compromised.

**Negative:**
- Maintaining two visibility systems adds cognitive overhead — a change to the visibility rules must be applied in both `resolve_visibility/2` and the RLS policies.
- RLS policies are harder to test than Elixir code — requires database-level test setup with role switching.
- Performance: RLS adds a small overhead to every query. At Phase 1 scale this is negligible; worth revisiting at 10K+ users.
- The marketplace listing exception (active listings punch through profile ceiling) must be encoded consistently in both the application layer and RLS — a divergence here could cause a listing to be visible in the DB but rejected by the application, or vice versa.

**Testing requirement:**
- `resolve_visibility/2` must be property-tested with a generated suite of (requester, owner, resource, block status, group membership) combinations. See the Testing Strategy section of `docs/technical-architecture.md`.
- RLS policies must be tested with database-level role switching in integration tests.

**Known gap at time of writing:**
- RLS policies are designed but not yet activated. Activation is gated on the visibility contexts passing their tests; until then only `resolve_visibility/2` is enforced.

**Update (2026-03-19):** RLS policies were activated by migration `20260319000008_enable_rls_policies.exs`, alongside Issue #047 (`issues/complete/047-visibility-infrastructure.md`). Both layers are now in force.
