# Issue #200: E2E — Placement Visibility (Playwright)

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Add Playwright E2E coverage for the placement-visibility override UI (punch #16) against the real API. HARD dependency on #194 — the placement-visibility frontend must exist first. Test-only — no new user stories.

## User Stories
None claimed. Drives the US-10.2.2 frontend (built in #194) live.

## Wiring
- [ ] This issue includes router/UI wiring and is user-facing when complete.
- [x] This issue is implementation only (E2E spec). Wired by n/a.

## Feature-Completeness Pre-Check
n/a — no new user stories claimed; builds/tests against the already-built surface (see #122 audit). The placement-visibility frontend is built by #194 (hard dependency); this child only drives it live.

## Technical Requirements
Playwright — **real API, no `page.route` mocking** (punch #16):
- Owner sees the faint-outline spine for an owner-only hidden book on an otherwise-visible shelf.
- Placement ceiling options greyed with a tooltip.

## Reviewer Context
- E2E runs against a live preview (`TEST_TARGET=deployed`); real API, no mocking.
- The faint-outline spine (`Components/Spine.elm`) and greyed ceiling options are delivered by #194 and must exist before this spec can pass.

## Definition of Done
- [ ] Playwright: faint-outline owner-only spine on a visible shelf + greyed ceiling options with tooltip.
- [ ] Real API (no `page.route` mocking).
- [ ] `just verify` passes.
- [ ] Spec green on a live preview.
- [ ] The #122 audit E2E item #16 goes GREEN.

## Dependencies
Epic #122. **Hard: #194** (placement-visibility frontend must exist).

## Agent Assignment
testing-coordinator.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
