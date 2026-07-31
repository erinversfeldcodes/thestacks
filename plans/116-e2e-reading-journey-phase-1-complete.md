# Issue #116 — Phase 1 Complete: Shelving fixes

**Committed:** a1499f92 (feat/116-e2e)
**Date:** 2026-07-22

## Delivered
- `Shelving.move_book/3` reassigns `shelf_id` to the destination bookshelf's default (position-0)
  shelf, mirroring `place_book/3`'s creation-time convention — fixes the live-confirmed bug where
  moved books stayed on the source browse and never appeared on the target (US-1.6.1/1.6.2
  blocking finding). `abandon_book/2` inherits the fix.
- `Shelving.reread_book/1` → `reread_book/2(placement_id, user_id)`: ownership check
  (`{:error, :unauthorized}`) and `Repo.get` (`{:error, :not_found}`) instead of `Repo.get!`
  (punch #5/#8).

## Gate evidence
- Tests-first: 9 meaningful pre-implementation failures captured.
- 2B-i regression (independent orchestrator run): 2796 tests, 0 failures, 10 excluded.
- 2B-ii spec coverage: all Phase 1 steps evidenced in diff (orchestrator inspection).
- 2B-iia: skipped — no migrations/schema/dbt changes in diff.
- 2B-iii: deferred to the consolidated preview E2E gate at Phase 5 (recorded deviation).
- Proving gate (live drive, minted user): place wishlist → move antilibrary → wishlist count 0 /
  book absent, antilibrary count 1 / book present. PASS.
- Testing-coordinator: all 6 DoD rows PASS, non-vacuous, through the real read path (76/76 on the
  file).
- elixir-reviewer: **APPROVED**.

## Findings carried into Phase 3 (tracked, not dangling)
- P2 (pre-existing): `shelf_changeset/2` lacks `unique_constraint([:bookshelf_id, :position])`,
  so `get_or_create_default_shelf`'s race fallback is dead code — losing concurrent insert raises
  `Ecto.ConstraintError`. One-line fix + test.
- P3: same-bookshelf `move_book` resets to position-0 shelf — decide no-op guard.
- P3: `get!` vs `get` asymmetry across move/remove/abandon vs reread — align during punch #3 work.
- TC optional: direct `move_book` `:unauthorized` test (currently covered transitively).
- Phase 5 note from reviewer: the browse E2E regression spec must assert DOM presence/absence on
  both bookshelves, not counts.
