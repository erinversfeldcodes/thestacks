# Issue #221: Paginate + batch the public shelf-browse resolver

## Summary
`GET /api/u/:handle/bookshelves/:name` (`ProfileController.render_shelf`) loads
**every** active placement on the shelf (no LIMIT) and runs
`Visibility.resolve_visibility/2` once per placement on an optional-auth surface.
#210 landed the cheap half of the fix (preload `bookshelf: :user` so the profile
ceiling reuses loaded data instead of a per-row `Accounts.get_user`). The residual:
`check_block` (`Social.blocked?`) and `viewer_age_verified?` (`Accounts.get_user`)
still fire per placement even though both are identical for every row on one shelf,
and the collection is unbounded.

## Goal
The public browse is O(1) shared-gate queries + a bounded page of placements.

## Scope
- Memoize the (viewer, owner) block status and the viewer's `age_verified` once per
  request rather than per placement — e.g. a batch resolver entrypoint that takes a
  preloaded viewer + a list of placements, or resolve the shared gates in the
  controller and only run the per-placement bits (placement ceiling + age gate) in
  the loop.
- Add a page/limit (or hard cap) to the shelf response so one request cannot walk
  thousands of placements. Do NOT add the limit to the shared `active_placements_query`
  (it also backs the owner's own full-shelf view) — cap only the public path.

## Definition of Done
- [ ] Per-request query count is independent of placement count (bar the page).
- [ ] Response is bounded; owner's own view is unaffected.

## Delegation spec (agent)
⚠️ This touches the **security-critical** resolver — visibility decisions must NOT change.
Prove parity: `visibility_test.exs`, `visibility_property_test.exs`, and
`profile_controller_test.exs` must stay green (run them).
**Files:** `apps/core/lib/stacks/visibility.ex`, `apps/core/lib/stacks/shelving.ex`,
`apps/core/lib/stacks_web/controllers/profile_controller.ex`.
**Acceptance criteria:**
1. In the public browse (`ProfileController.render_shelf`), the (viewer, owner) block check
   and the viewer's `age_verified` are resolved **once per request**, not per placement.
   Approach: a batch entrypoint on `Visibility` that takes a preloaded viewer + a list of
   placements, OR resolve the shared gates in the controller and only run the per-placement
   bits (placement ceiling + book age gate) in the loop. (The `bookshelf: :user` preload for
   the profile ceiling is already done in #210 — build on it.)
2. Add a page/limit (or a hard cap, e.g. 500) to the public shelf response. Do NOT add the
   limit to the shared `active_placements_query` (it also backs the owner's own full-shelf
   view) — cap only the public path.
3. A test asserts the bound (e.g. a shelf with N+1 placements returns ≤ cap) and, if feasible,
   asserts no per-row owner/viewer reload (telemetry or a query-count probe). Owner's own
   `/library` view still returns all placements (existing bookshelf_controller test green).
**Verify:** `just run mix test` for the three suites above + the new test; `just run just verify`.

## Source
elixir-reviewer P2 (+ principal-engineer), #210 epic review. Cheap half done in #210.
