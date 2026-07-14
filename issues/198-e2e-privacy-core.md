# Issue #198: E2E — Privacy Core Flows (Playwright)

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Add core Playwright E2E coverage for the privacy surface in a new `e2e/tests/privacy.spec.ts` (does not exist yet). Covers punch items #13, #15, #17, #18, #19 against the real API (no `page.route` mocking). Test-only — no new user stories.

## User Stories
None claimed. Drives the already-built (and #196-finished) surface for US-10.1.1, US-10.2.1, US-10.2.3, US-10.3.1, US-10.4.1 live.

## Wiring
- [ ] This issue includes router/UI wiring and is user-facing when complete.
- [x] This issue is implementation only (E2E spec). Wired by n/a.

## Feature-Completeness Pre-Check
n/a — no new user stories claimed; builds/tests against the already-built surface (see #122 audit). Soft-depends on #196 having built the partial-story render bits (save-confirmation, info text, ViewAs label) that these specs assert.

## Technical Requirements
New `e2e/tests/privacy.spec.ts` — **real API, no `page.route` mocking**:
- **#13** Profile visibility flow: `/settings/privacy` → select → Save → "Saved!"; auth guard on the page.
- **#15** Shelf visibility rows + ceiling-violation feedback.
- **#17** Blog editor visibility dropdown → Save Draft / Publish.
- **#18** ViewAs: `?view_as=unauthenticated` → amber banner "Viewing as: Not logged in" → "Exit preview" removes the param.
- **#19** `robots.txt` disallow + `<meta name="robots" content="noindex, nofollow">` in the SPA shell + on-page search-privacy info text.

## Reviewer Context
- E2E runs against a live preview (`TEST_TARGET=deployed`); real API, no mocking (project convention).
- The ViewAs "Not logged in" label and shelf "Saved!" render are delivered by #196 — this spec asserts them.

## Definition of Done
- [ ] `e2e/tests/privacy.spec.ts` created covering punch #13, #15, #17, #18, #19.
- [ ] Real API (no `page.route` mocking).
- [ ] `just verify` passes.
- [ ] Spec green on a live preview.
- [ ] The #122 audit E2E items #13/#15/#17/#18/#19 go GREEN.

## Dependencies
Epic #122. **Soft: #196** (built partials + selectors: "Saved!" render, info text, ViewAs label).

## Agent Assignment
testing-coordinator.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
