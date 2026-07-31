# Complete: Issue #125 — E2E Test Suite: Navigation & Error Handling

**Completed**: 2026-07-26 · **Branch**: `feat/125-126-e2e` (epic with #126) · **Status**: all phases done, gates green; PR held for owner inspection

## Phases
1. **Re-baseline + live-drive** (5ff8d413) — all 7 stories driven live; US-15.1.1/US-16.3.1 story docs reconciled to the shipped surface (#235 CTAs, #173/#178 interceptor); form-preservation verified working (contingency fix not needed).
2. **Elm exposing + units** (297d9d18) — `viewHome`/`viewFooter`/`viewNotFound`/`requiresAuth`/`initPage`/`decodeSwipe` exposed; 60 tests incl. the exhaustive 41-route auth matrix (compile-guarded). elm-reviewer APPROVED.
3. **E2E additions** (d4154414) — footer/404/home/swipe-gesture/Marketplace-dropdown/form-preservation/URL-bar-unchanged/redirect-breadth specs; reviewer APPROVED (swipe path traced to app.js listener).
4. **Audit → GREEN** (90f23b3e) — 17✅/0⚠️/0❌/165 n/a; all 9 punch items closed with file:line.

## Final evidence
- elm-test 1173/0 · targeted mix 17/0 · preview chromium 281/0 (default workers, zero 429s) · epic subset 62/0/0 · `just ci` green (dockle local-daemon caveat documented).
- DoD: 9/9 ticked with evidence tokens (2082f933).

## Notes
- The `:auth`-bucket 4-worker 429 artifact does not manifest on the gate environment — tracked in `plans/125-126-e2e-epic-state.json` as a local-ergonomics follow-up.
- Punch #7 (RequireConfirmedEmail 403) was already closed by #124's intervening work; punch #2/#6/#9 were partially closed by `MainNavTest`/`LoginProgramTest`/#173 — the audit credits those honestly.
