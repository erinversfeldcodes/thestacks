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
- [ ] Toast renders and offers undo — evidence: test + screenshot
- [ ] Same row restored, id unchanged — evidence: test asserting the id
- [ ] Collision case handled, with the chosen behaviour stated — evidence: test + rationale
- [ ] Read-only cannot reach undo, incl. synthetically — evidence: test + probe
- [ ] Mutation probe on the same-row assertion — evidence: transcript
- [ ] Live-driven: remove → undo → book restored in place — evidence: screenshots
- [ ] `gdpr-review` verdict cited
- [ ] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. Owns `frontend/src/Page/Bookshelf.elm` for this wave — ⚠️ no other Wave 7 child may edit
it concurrently (the #343/#344 lesson). Story file coordinates with **#320**.

## Agent Assignment
elm-agent (toast) + elixir-agent (reversal, collision).

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phase 2. Split from the un-merge work
(now **#376**) because an admin data-correction surface and a reader-facing toast share no code and would
have exceeded the scope rule together.
