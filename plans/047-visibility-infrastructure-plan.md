# Plan: Visibility Infrastructure — resolve_visibility/2 + Blocks + Property Tests
**Issue**: #047
**Created**: 2026-03-19
**Status**: In Progress

## Context
Every content read path must route through a single authoritative visibility gate. This issue builds `Stacks.Visibility.resolve_visibility/2`, the block graph (`Stacks.Social`), `ViewAsPlug`, and property-based tests with StreamData. All schema tables (`user_blocks`, `visibility_grants`, `groups`) exist from Issue #043.

## Research Summary
- All required tables exist: `op.user_blocks`, `op.visibility_grants`, `op.groups`, `op.group_members` ✓
- `Stacks.Social` exists as a stub with schema aliases; no business logic yet
- `StreamData ~> 1.1` already in `mix.exs` (dev/test only) ✓
- Visibility fields confirmed on all resources: `users.profile_visibility`, `bookshelves.visibility`, `bookshelf_placements.visibility`, `books.visibility_tier`
- Existing `AgeGate` plug is kept separate (orthogonal concern: content rating vs. ownership privacy)
- Marketplace exception: `looking_for_home` placements with `listing_status = 'active'` bypass profile ceiling for `{:platform_user, _}` viewers
- Phases 1 and 2 are independent and will run in parallel

## Approach Options
- **A (chosen):** Standalone `Stacks.Visibility` context; controllers call it explicitly. Surgical, testable, doesn't pollute the request pipeline.
- **B:** Global plug auto-gating every request. Too blunt — many routes are legitimately public (catalogue, cost page, health check).
- **C:** Per-controller macros with `use Visibility`. Too verbose, violates DRY, harder to property-test in isolation.

## Phases

### Phase 1: Visibility Core + Social Blocks
**Objective**: Build the authoritative visibility gate and the block graph.
**Agent**: elixir-agent
**Steps**:
1. Create `apps/core/lib/stacks/visibility.ex`:
   - `resolve_visibility(resource, viewer)` — 4-clause: (1) profile ceiling check, (2) block check via `Social.is_blocked?/2`, (3) age gate check, (4) resource-level visibility. Returns `:visible | :hidden`. Returns `:hidden` on all ambiguous/error cases.
   - Marketplace exception: if resource is a placement on `looking_for_home` with `listing_status == "active"`, skip profile ceiling for `{:platform_user, _}` viewers.
   - `can_view?(resource, viewer)` — boolean wrapper
   - `viewable_shelves(user_id, viewer)` — filters bookshelves
   - `viewable_placements(shelf_id, viewer)` — filters placements
   - `validate_visibility_ceiling(child_visibility, parent_visibility, resource_type)` — enforced on write; child ≤ parent
2. Expand `apps/core/lib/stacks/social.ex`:
   - `block_user(blocker_id, blocked_id)` — inserts `user_blocks` row, emits `social.user_blocked` event; returns `{:ok, block} | {:error, changeset}`
   - `unblock_user(blocker_id, blocked_id)` — deletes `user_blocks` row, emits `social.user_unblocked` event
   - `is_blocked?(viewer_id, resource_owner_id)` — true if either direction blocked
   - `blocked_by?(viewer_id, resource_owner_id)` — true if viewer has blocked owner
3. All public functions have `@spec` and `@doc`
**Test Command**: `cd apps/core && mix test test/stacks/visibility_test.exs test/stacks/social_test.exs`
**DoD Items**:
- [ ] `resolve_visibility/2` implemented with all 4 clauses
- [ ] Marketplace ceiling exception works correctly
- [ ] `can_view?/2`, `viewable_shelves/2`, `viewable_placements/2` implemented
- [ ] `validate_visibility_ceiling/3` enforced on write
- [ ] `block_user/2`, `unblock_user/2` work; bidirectional block check
- [ ] `social.user_blocked` and `social.user_unblocked` events emitted
- [ ] Tests: unit tests for each clause; block integration tests

### Phase 2: ViewAsPlug + Anti-scraping
**Objective**: Owner-gated ViewAs query param; robots.txt; unauthenticated redirect.
**Agent**: elixir-agent
**Steps**:
1. Create `apps/core/lib/stacks_web/plugs/view_as_plug.ex`:
   - Parse `?view_as=<perspective>` — perspectives: `unauthenticated`, `platform`, `user:<id>`, `group:<id>`
   - Validate that the current user owns the resource being viewed (Guardian current_resource)
   - Set `conn.assigns[:view_as_context]` with viewer type struct
   - Return 403 for non-owners using ViewAs
   - No-op if `?view_as` absent
2. Create `apps/core/priv/static/robots.txt`:
   ```
   User-agent: *
   Disallow: /u/
   Disallow: /shelf/
   Disallow: /post/
   Disallow: /listing/
   ```
3. Verify unauthenticated requests to `:authenticated` routes return redirect (existing behaviour — just confirm with a test)
4. Wire `ViewAsPlug` into the `:authenticated` pipeline (or as opt-in per route group)
**Test Command**: `cd apps/core && mix test test/stacks_web/plugs/view_as_plug_test.exs`
**DoD Items**:
- [ ] `ViewAsPlug` correctly sets viewer context; 403 for non-owners
- [ ] `robots.txt` disallows `/u/`, `/shelf/`, `/post/`, `/listing/`
- [ ] Unauthenticated API requests to user-data endpoints return 401 (confirmed via test)

### Phase 3: Property Tests + Controller Integration
**Objective**: StreamData invariants (1000+ cases); wire resolve_visibility/2 into controllers.
**Agent**: elixir-agent
**Steps**:
1. Create `apps/core/test/stacks/visibility_property_test.exs` with StreamData:
   - Generate random `{resource, viewer}` pairs
   - Invariant: blocked viewer NEVER sees `:visible`
   - Invariant: viewer NEVER sees content above profile ceiling (except active marketplace listings)
   - Invariant: `:unauthenticated` viewer NEVER sees non-public content
   - Invariant: age-gated resource ALWAYS hidden from unverified viewers
   - Invariant: active marketplace listings on `looking_for_home` ALWAYS visible to platform users
   - Minimum 1000 generated cases per invariant (`check all/2` with `initial_size: 5, max_runs: 200`)
2. Wire `resolve_visibility/2` into controllers (return 404 on `:hidden`):
   - `BookshelfController.show/2` — gate by shelf owner's profile visibility + shelf visibility
   - `BookController.show/2` — gate by book's visibility_tier (age gate already exists; add profile check)
   - `SearchController.index/2` — filter results by `viewable_placements/2`
3. Add integration tests: blocked user gets 404; unauthenticated gets 401 on auth routes
**Test Command**: `cd apps/core && mix test`
**DoD Items**:
- [ ] Property-based tests pass with 1000+ generated cases
- [ ] `BookshelfController` returns 404 for visibility-denied access
- [ ] `BookController` integrates visibility check
- [ ] `SearchController` filters by visibility
- [ ] `mix credo --strict` and `mix sobelow` pass

## Open Questions
- None — resolved in research.

## Integration Handoffs
- Phase 1 and Phase 2 are independent — run in parallel.
- Phase 3 depends on both Phase 1 and Phase 2 being committed.
- Issue #046 `search_platform/2` stub calls this issue's `resolve_visibility/2` once available.
- Reviewer: elixir-reviewer + contract-reviewer. Security concerns reviewed via sobelow + security checklist.

## Parallel Execution
**Independent phases**: 1 and 2 (no data dependency — different files entirely)
**Merge order**: Phase 1 worktree → feat/047 branch; Phase 2 worktree → feat/047 branch; then Phase 3 on feat/047
