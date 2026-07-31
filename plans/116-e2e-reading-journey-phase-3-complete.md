# Issue #116 — Phase 3 Complete: Elixir test hardening + carried findings

**Committed:** 8c182af2 (feat/116-e2e)
**Date:** 2026-07-23

## Delivered
- Punch #1–#4, #6/#7, #9–#12 closed: move sad paths (404/invalid-name-422/all-five-targets/
  same-bookshelf no-op), abandon API test (browse-level), reread two-move sequence test (decision:
  NO reread endpoint — context-only), delete idempotency (204), move/abandon rollback via a real
  partial-unique-index seam, `op.books` survives soft-delete, `history.to_bookshelf` pinned,
  audit-positive tests strengthened to pin resource_type/resource_id/user_id, event-isolation
  delta tests for moved/removed/reread.
- Phase-1 carried findings fixed: `shelf_changeset/2` public + `unique_constraint([:bookshelf_id,
  :position])` (race fallback now live); same-bookshelf `move_book` = documented no-op success
  (no history/event/audit/shelf-reset); `move_book`/`abandon_book` → `{:error, :not_found}` with
  controller 404 + invalid-name 422 guard (junk-bookshelf creation closed).
- `placement.reread` registered in Events.Registry with `[]` + rationale (pre-existing no-handler
  behaviour preserved, catalogued in all_event_types/0).

## Gate evidence
- Tests-first for code fixes (8 meaningful pre-implementation failures).
- 2B-i independent: 2825 tests, 0 failures (full suite); post-strengthening file run 94/0.
- 2B-iia skipped (no migrations/schema/proto changes).
- 2B-iii deferred to Phase 5 consolidated preview gate.
- Proving drive (live API, minted user): 404 nonexistent, 422 invalid name (no junk bookshelf
  created), same-bookshelf 200 no-op, idempotent double-DELETE 204. PASS.
- TC: all rows PASS after one revision (audit rows now pin their target; rollback seam verified
  deterministic; remove_book indirect-atomicity argument endorsed).
- elixir-reviewer: **APPROVED**.

## Notes / residuals (non-blocking)
- `remove_book/2` keeps `Repo.get!` (controller pre-guards 404) — boundary-resolved asymmetry,
  noted for future alignment.
- `check_move_capacity/3` same-bookshelf clause now unreachable defensive dead code — left with
  comment (cleanup candidate).
- Context-level bookshelf-name validation remains caller-trusted (pre-existing, unchanged risk).
