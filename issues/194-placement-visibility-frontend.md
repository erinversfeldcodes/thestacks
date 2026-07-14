# Issue #194: Override Placement Visibility — Frontend (Elm)

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Build the per-placement visibility-override FRONTEND for US-10.2.2. Backend exists and is tested; only the Elm client + UI are missing. De-scoped from #122 (its audit wrongly claimed this shipped).

Backend evidence (already built + tested):
- Route: `apps/core/lib/core_web/router.ex:220` → `apps/core/lib/stacks_web/controllers/bookshelf_placement_controller.ex:106` (`update_visibility`).
- `frontend/src/Api.elm` has NO `updatePlacementVisibility` (confirmed by grep).

## User Stories
US-10.2.2 (Override Placement Visibility) — **frontend**.

## Wiring
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
The named story's frontend is ❌ MISSING — no `updatePlacementVisibility` client or placement-visibility UI exists (grep-confirmed). This child BUILDS it in-scope. Baseline verdicts below; fill file:line hops + live-drive when picked up.

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.2.2 — Override Placement Visibility (frontend) | ⬜ to verify (build in-scope) | ⬜ to verify | ❌ → build here | Built in-scope by this child |

Verdict: ❌ missing → built in-scope by this issue. Becomes ✅ (built end-to-end + driven live on a preview) at DoD.

## Technical Requirements
1. **Api client fn** — `Api.updatePlacementVisibility` in `frontend/src/Api.elm` (Bearer auth, `RemoteData`).
2. **Per-placement visibility dropdown** — in the book-detail overlay.
3. **Ceiling greying** — client-side greying of options that exceed the shelf ceiling, with a tooltip.
4. **Owner-only spine rendering** — faint-outline spine in `frontend/src/Components/Spine.elm` for a hidden placement on an otherwise-visible shelf (owner-only).
5. **Elm state-machine tests** — happy + sad — punch #10.

**DESIGN note (Phase-1 research):** `Components/Spine.elm` currently has no visibility param. A Phase-1 research pass decides the faint-outline approach and where the visibility control lives (overlay vs. spine) before implementation.

## Definition of Done
- [ ] `Api.updatePlacementVisibility` implemented via `RemoteData`.
- [ ] Per-placement visibility dropdown in the book-detail overlay.
- [ ] Ceiling-exceeding options greyed client-side with tooltip.
- [ ] Faint-outline owner-only spine in `Components/Spine.elm` for hidden placements on visible shelves.
- [ ] Elm state-machine tests (happy + sad) written and passing (punch #10).
- [ ] `just verify` passes.
- [ ] **Feature-Completeness Pre-Check is ✅ for US-10.2.2** — happy path built end-to-end and driven live on a preview.

## Dependencies
Epic #122. Backend (`router.ex:220` → `BookshelfPlacementController.update_visibility`) already exists. Blocks E2E child #200 (hard).

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
