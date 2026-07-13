# Issue #183: Shelf Organization — Manage Books Across Physical Shelves

## Summary
Build the frontend management surface for **physical shelves** (US-1.7.1) — the ordered horizontal rows within a bookshelf's bookcase (`op.shelves`, shipped backend-first in #151). The backend is fully built and tested; the SPA currently only *renders* shelves and can *create* one. This issue adds the missing management UI (move a book between shelves, reorder shelves, delete a shelf) and validates the whole US-1.7.1 journey end-to-end.

## User Stories
- [US-1.7.1 — Organize Books into Shelves](../docs/user_stories/US-1.7.1-organize-shelves.md)

## Goal
A user can arrange the books within a bookcase across ordered shelves by hand: move a book from one shelf to another, reorder shelves, and delete a shelf — each reflected immediately and persisted. The US-1.7.1 happy path is built end-to-end and driven live.

## Scope Check
- Touch more than 3 controllers? No — backend exists (`ShelfController`, `BookshelfPlacementController.move_to_shelf`); this issue is **frontend + E2E only**.
- Add more than 2 new endpoints? No — all endpoints already exist (`GET/POST /bookshelves/:name/shelves`, `DELETE /shelves/:id`, `PUT /bookshelves/:name/shelves/reorder`, `PUT /placements/:id/shelf`).
- Exceed ~300 lines of production code? Borderline — three Elm management flows. If planning shows >300 LOC, split by action (move / reorder / delete) into sub-issues.
- Combine unrelated concerns? No — all shelf management. **Rename is explicitly OUT of scope** (no `name` column exists; renaming needs a schema/proto change first — separate issue).

## Wiring
- [x] This issue includes UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Pre-filled from the US-1.7.1 investigation (2026-07). Re-verify at pick-up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.7.1 — Organize Books into Shelves | Backend built + tested: `Shelving.list/create/delete/reorder_shelves` + `move_placement_to_shelf`; `ShelfController` (index/create/delete/reorder) + `BookshelfPlacementController.move_to_shelf`; `get_bookshelf_shelves/2`; `op.shelves` + `op.bookshelf_placements.shelf_id`. **Frontend: render only** (`viewShelf` → `bookcase__shelf[data-shelf-id]`) **+ create** (`AddShelf`/`Api.addShelf`). MISSING UI: move-to-shelf, reorder, delete (incl. `422 not-empty`) | ❌ not driven (management UI absent) | 🟡 partial | **build in-scope (this issue)**: add move/reorder/delete UI + `Api` client fns, then E2E. See US-1.7.1 Implementation Status. |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### Frontend (Elm) — the gap
1. **Move a book between shelves** — call `PUT /api/placements/:id/shelf` (`BookshelfPlacementController.move_to_shelf`). UI: drag-between-shelves or a per-book "move to shelf…" affordance on the bookcase. New `Api.movePlacementToShelf`, Msg + optimistic model update.
2. **Reorder shelves** — call `PUT /api/bookshelves/:bookshelf_name/shelves/reorder` with the new ordered shelf-id list. UI: drag shelf rows or up/down controls. New `Api.reorderShelves`, Msg.
3. **Delete a shelf** — call `DELETE /api/shelves/:id`. UI: a delete control per shelf with a confirmation. Handle the **`422 shelf not empty`** sad path (books must be moved off first — the backend does NOT reflow; `shelf_id` is `nilify_all` only for already-removed placements). New `Api.deleteShelf`, Msg.
4. Confirm the existing **create** flow (`AddShelf`) fits the new management surface consistently.

### Backend — verify only (should need no changes)
- Confirm ownership checks on all four endpoints (a user may only manage shelves in their own bookshelves).
- Note for the reviewer: shelf mutations emit **no events** and write **no placement history** (unlike cross-*bookshelf* moves) — confirm this is intended; if history/events are wanted, that is a separate concern.

## Reviewer Context
- **Bookshelf ≠ shelf.** Bookshelf = one of the five named collections (`op.bookshelves`). Shelf = an ordered physical row within a bookshelf's bookcase (`op.shelves`). Never conflate.
- `op.shelves` has **no `name` column** — shelves are ordered but anonymous. Rename is not implementable without a schema change (out of scope here).
- Shelf delete does **not** reflow books; deleting a non-empty shelf returns `422`. The UI must guide the user to empty it first.
- Shelves shipped backend-first in **#151**; older docs/memory saying "shelves don't exist" are stale.

## Test Audit
<!-- Generate with the `test-audit` skill AFTER the Feature-Completeness Pre-Check is ✅ (feature built).
The pre-check above is the gate; the test audit is the coverage map that follows it. -->

_To be generated by the `test-audit` skill once the management UI is built. Baseline expectation: Elm program tests for move/reorder/delete + sad paths (422 not-empty), plus Playwright E2E driving the full organize-a-bookcase journey against a real stack._

## Definition of Done
- [ ] **Feature-Completeness Pre-Check (above) is ✅** — US-1.7.1's move / reorder / delete flows built end-to-end and observed working on a live stack.
- [ ] Move a book between shelves from the UI; reorder shelves from the UI; delete an empty shelf from the UI; deleting a non-empty shelf shows the `422` guidance.
- [ ] Every behaviour has a validation path — Elm program tests + Playwright E2E against a real stack (`TEST_TARGET=deployed`).
- [ ] Tests written and passing (`elm-test`, E2E)
- [ ] **Test audit (embedded above) is GREEN** — every applicable cell `✅` or `n/a`-with-rationale; regenerate as the final step.
- [ ] `just verify` passes (via `just run`)

## Dependencies
- #151 (shelves backend — already merged). No new backend work expected.

## Agent Assignment
elm-agent (management UI) + testing-coordinator (E2E). elixir-agent only if backend gaps surface (ownership/events).

## Progress Notes
- 2026-07-13: Cut from the Phase-1 user-story gap review. US-1.7.1 backend exists (#151) but the management UI was never built and the feature had no user story until now.
