# Issue #199: E2E — Block/Unblock Flow (Playwright)

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Add Playwright E2E coverage for the block/unblock flow (punch #14) against the real API. HARD dependency on #193 — the block-user frontend must exist first. Test-only — no new user stories.

## User Stories
None claimed. Drives the US-10.1.2 frontend (built in #193) live.

## Wiring
- [ ] This issue includes router/UI wiring and is user-facing when complete.
- [x] This issue is implementation only (E2E spec). Wired by n/a.

## Feature-Completeness Pre-Check
n/a — no new user stories claimed; builds/tests against the already-built surface (see #122 audit). The block frontend is built by #193 (hard dependency); this child only drives it live.

## Technical Requirements
Playwright block/unblock flow — **real API, no `page.route` mocking** (punch #14):
- Block from the overflow menu → confirmation modal → blocked user's content disappears.
- Settings → Blocked Users → Unblock → content reappears.

## Reviewer Context
- E2E runs against a live preview (`TEST_TARGET=deployed`); real API, no mocking.
- This flow's UI (overflow block action, confirmation modal, Blocked Users list) is delivered by #193 and must exist before this spec can pass.

## Definition of Done
- [ ] Playwright block → confirm → content-disappears and unblock → content-reappears flow.
- [ ] Real API (no `page.route` mocking).
- [ ] `just verify` passes.
- [ ] Spec green on a live preview.
- [ ] The #122 audit E2E item #14 goes GREEN.

## Dependencies
Epic #122. **Hard: #193** (block-user frontend must exist).

## Agent Assignment
testing-coordinator.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
