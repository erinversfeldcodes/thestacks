# Issue #324: W0 child C — Elm fixes: header reflow, reading-pile panel, notifications init

## Summary
Child of epic #311. Three one-liner-class Elm fixes proven live 2026-07-30: the user-menu dropdown reflows the whole header; the reading-pile status card floats detached mid-wall; the Notifications page spins "Loading…" forever when tokenless.

## User Stories
US-14.3.3 (user menu), US-1.2.4 (reading pile), US-17.3.1 (notifications).

## Goal
Menu opens as an overlay without moving the header; the "To Read" panel renders below the armchair scene where its CSS expects it; tokenless Notifications renders NotAsked (matching AuditLog's correct handling).

## Scope Check
3 files + 1 test file, ~15 LOC. No split.

## Wiring
Router wiring: none — user-facing rendering fixes on existing routes.

## Feature-Completeness Pre-Check
n/a — defect fixes on built surfaces; epic-level live drive observes them.

## Technical Requirements
- **0f**: delete `style "position" "relative"` (and audit the sibling inline `z-index`) from `frontend/src/Components/UserMenu.elm:93-98` — the inline style defeats `.app-nav__dropdown-menu`'s `position: absolute` (`main.css:231-234`) and pulls the menu into the header's flex flow. Do NOT fix the model/`:focus-within` dual-authority here (that's #316's disclosure rework) — this child only stops the reflow.
- **0g**: move `viewProgressPanel model` out of the `.reading-pile__scene` child list (`frontend/src/Page/Bookshelf/ReadingPile.elm:323`) to a sibling AFTER the scene under `.reading-pile`; its CSS (`main.css:4446-4452`, `margin: 1.5rem auto 0`) is already written for that position. No CSS change.
- **0h**: `frontend/src/Page/Settings/Notifications.elm:37-46` — tokenless init returns `( { prefs = NotAsked, … }, Cmd.none )` instead of `Loading`; mirror `AuditLog.elm:47-48`. Add the missing view branch for NotAsked if absent.

## Reviewer Context
- `elm-format` via hook; `elm-review --fix` narrows `Msg(..)` exposures — don't run it standalone here.
- Screenshot evidence for 0f/0g is captured at the epic finalization drive (layout claims need a browser, not elm-test — "needs a browser" is narrow but real here); 0h gets a unit test now.
- Elm suite baseline 1,285/0 — cite the post-change count.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine | yes | ❌ tokenless-init test (`NotificationsTest` or program test): init without token → NotAsked, no Http effect |
| Visual/live | yes | ❌ finalization drive: menu-open screenshot pair (no logo shift); anchored panel screenshot |
| Others | no | n/a |

## Definition of Done
- [x] 0h test green — evidence: `NotificationsTest.elm` "tokenless init yields NotAsked…" + view test; suite 1176/0 on integration branch
- [x] Mutation probe — evidence: builder transcript (2 failures quoted) + reviewer independent re-probe: revert → 2 red, restore → 1176/0, tree clean
- [x] 0f/0g landed; elm-test green — evidence: 1176 passed 0 failed post-merge; `just ci` elm groups PASS
- [x] Finalization drive — evidence: ss_4933q9aro (panel below scene, closed header) + ss_2563sec80 (menu open, header pixel-identical — vs ss_0455t8fed's 40px drop)
- [x] `staff-review` verdict recorded below — evidence: LGTM, Progress Notes 2026-07-30

## Dependencies
Epic #311. No sibling dependencies.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-30 (Wave 0 kickoff approved).
Built in worktree; commit b43ec4fc; merged to feat/campaign-w0-311 (e5b7a0f3).
**staff-review verdict: LGTM** (2026-07-30, Mode B on b43ec4fc). Praise: every comment states a constraint the code can't show (the z-index/backdrop pairing, the sibling-not-child rationale, the tokenless invariant); the view's `_` catch-all split into explicit `NotAsked`/`Loading` branches makes all four RemoteData variants exhaustive — future variant drift is now a compile error (ladder rung 2); test-first with a genuine red/green probe. Reviewer re-probed independently on the integration branch: reverting init to `Loading` → 2 failures ("tokenless init yields NotAsked…", "does not render the loading copy"), restore → 1176/0, tree clean. 🟦 (recorded, non-actionable): the `showAgeGate` guard now lives in two sibling expressions — acceptable duplication until #316's disclosure/gating rework. Screenshot evidence for 0f/0g lands at epic finalization drive.
