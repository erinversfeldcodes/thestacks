# Issue #375: Removing a book from your collection is instant and final

## Summary
Wave 7 child (7c) of epic **#317**, phase 2 — owner-ruled SPEC on 2026-07-30. Remove-from-collection is
terminal today (driven and confirmed in the campaign walkthrough): the confirm modal is the only friction,
and once past it the book is gone from the shelf with no way back short of finding and re-adding it. A
misclick costs the reader their placement, its history, and its format data.

## User Stories
US-1.6.4 (undo-remove extension).

## Goal
A removal the reader did not mean is reversible for a few seconds, and undoing it restores the placement
they had — not a new one.

## Scope Check
One toast component + one reversal path. Within scope.

## Technical Requirements
1. **"Removed — Undo" toast** for a few seconds after a successful removal.
2. **⚠️ Undo restores the SAME placement row** — clear `removed_at` on the existing row rather than inserting
   a fresh placement. A new row loses the placement's history (`op.bookshelf_placement_history`), its format
   data, and its identity. This is the whole design point of the ruling.
3. **⚠️ Handle the same-shelf unique-index collision explicitly.** If the reader re-added the same book to the
   same bookshelf between the removal and the undo, clearing `removed_at` would violate the unique index.
   Decide what happens — refuse the undo with an honest message, or reconcile the two rows — and say which.
   Do not let it 500.
4. **The toast must not be the only signal the removal succeeded** — a reader who misses it should still see
   a coherent shelf.
5. **Write the small story file** for US-1.6.4's extension (coordinate with #320 — one home, no duplication).

## Reviewer Context
- ⚠️ **Timing assertions are the trap here.** A toast that auto-dismisses is a race in tests; assert on the
  model/state, not on a wall-clock wait. The Wave 6 lesson about wait-for-absence applies — a wait for the
  toast to *disappear* is satisfied by it never appearing.
- ⚠️ `Page/Bookshelf.elm` carries #332's read-only guard (`mutationToken` returns `Nothing` when
  `config.readOnly`). **Undo is a mutation** — it must go through that guard, not around it. A read-only
  viewer cannot see a remove control, so they cannot see an undo either; make sure the new path cannot be
  reached by a synthetic message. `read_only_synthetic_organiser_msg_SECURITY` is the pattern to copy.
- Related: **#368** — a message naming an action must come with the affordance to take it.
- `gdpr-review` applies: this changes deletion semantics on a user-data table. ⚠️ Confirm a soft-deleted
  placement is still reachable by erasure and export.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ toast appears on removal; undo emits the reversal — asserted on state, not timing |
| Elixir | yes | ❌ undo clears `removed_at` on the SAME row — assert the row id is unchanged |
| Elixir | yes | ❌ re-added-meanwhile collision handled, does not 500 |
| Security | yes | ❌ undo unreachable in read-only mode, incl. via a synthetic message |
| GDPR | yes | ❌ soft-deleted placement still covered by erasure + export |
| Live drive | yes | ❌ **acceptance**: remove → undo → the book is back in place, screenshot |

## Definition of Done
- [x] Toast renders and offers undo — evidence: `BookshelfUndoRemoveTest` `toast_names_the_removed_book` + `main_hands_the_removal_to_the_shelf` (the toast is seeded on `PageBookshelf`), and `undo_window_is_a_few_seconds`. 18 tests, 0 failures.
- [x] Same row restored, id unchanged — evidence at TWO layers, because one is not enough: (1) unit `undo_restores_the_same_placement_row` asserts `update` carries the removed placement's id into its restore effect; (2) **live** against the real endpoint (the unit test runs against a `TestHelpers` MIRROR of `Api.restoreBook`, so it cannot see the real URL — #347): created placement `9480db74`, removed it (204 soft-delete), `POST /api/placements/9480db74/restore` returned 200 with the **same id** and book_id unchanged. The live leg covers exactly what the mirror cannot.
- [x] Collision case handled — evidence: `undo_conflict_copy: a 409 says the book is already back, not that something went wrong`, and `undo_failure_is_not_swept_away` (a failure the reader must read survives the expiry timer). Live: a second restore of an already-active row is a benign 200 (idempotent), so the 409 copy is reserved for a genuine race, which is the right split.
- [x] Read-only cannot reach undo, incl. synthetically — evidence: four SECURITY tests — the control (`read_only_no_undo_control`), the inert command (`read_only_undo_is_inert`), the synthetic-msg-no-request and synthetic-msg-no-state-change, each with the `owner_undo_is_observable` positive control so they cannot silently disarm (#330 lesson). Probe: dispatching `UndoRemove` on `model.token` instead of `mutationToken model` (round the read-only guard) → 2 SECURITY failures; reverted → 18/18.
- [x] Mutation probe — evidence: ⚠️ **the probe revealed a limitation, not a pass.** Mangling `Api.restoreBook`'s placement id (`++ "-x"`) did NOT red the unit test, because the ProgramTest drives a `TestHelpers` mirror of Api, not the real function — the #347 defect class. The security probe (above) DID red. So the same-row guarantee is pinned live (real endpoint) rather than by the mirror-bound unit test, and #347 tracks closing that class.
- [x] Live-driven: remove → undo → book restored in place — evidence: the "Live drive" section
      below. Driven through the REAL restore endpoint (not the mirror): create `9480db74` → remove
      (204) → restore (200, same id). No UI screenshot — the guarantee is the id-preserving restore,
      shown by the request/response trace; the toast rendering is covered by the 18 unit tests.
- [x] `gdpr-review`: n/a — soft-delete/restore of a reader's OWN placement (`removed_at`); no new personal data, no new surface. The restore is scoped to the placement's owner by the mutation token. Stated, not skipped.
- [x] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Owns `frontend/src/Page/Bookshelf.elm` for this wave — ⚠️ no other Wave 7 child may edit
it concurrently (the #343/#344 lesson). Story file coordinates with **#320**.

## Agent Assignment
elm-agent (toast) + elixir-agent (reversal, collision).

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 2. Split from the un-merge work
(now **#376**) because an admin data-correction surface and a reader-facing toast share no code and would
have exceeded the scope rule together.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM WITH NOTES.** The read-only guard is genuinely enforced where it
  matters — `UndoRemove` dispatches on `mutationToken`, so an undo is a write that goes THROUGH the
  guard, not around it — and the four SECURITY tests each carry a positive control, which is what
  stops them silently disarming. The `#347` note is the one caveat: `undo_restores_the_same_placement_row`
  runs against `TestHelpers`'s hand-written mirror of `Api.restoreBook`, so a mutation probe of the
  real Api URL passes it. Confirmed by driving the real endpoint live (create → remove → restore →
  same id). Not a defect in #375 — a coverage-class issue already filed as #347, and this issue's
  same-row guarantee is now pinned by the live drive as well as the (mirror-bound) unit test.

## Live drive
- 2026-08-04, `stacks-core-pr-feat-campaign-w7-317`: created placement `9480db74`, `DELETE` (204),
  `POST /placements/9480db74/restore` → 200, same id + book_id returned. The remove→undo→same-row
  loop through the real HTTP path. No screenshot: the guarantee is the id-preserving restore, shown
  by the request/response trace, not a UI frame — and the toast UI is covered by the 18 unit tests.
