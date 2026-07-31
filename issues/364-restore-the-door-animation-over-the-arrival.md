# Issue #364: The login door dolly-shot no longer plays

## Summary
A deliberate, disclosed cost of **#359**, not an accident. That issue's whole point was that the auth credential must not be downstream of a browser animation frame — an occluded window meant `requestAnimationFrame` never fired, the completion signal never arrived, and **three login 200s were silently discarded**. The fix persists the token and navigates on the same update that decodes the 200.

The consequence: navigation unmounts the login scene before the port's frame callback runs, so the door animation is started against elements that are already gone. Measured on a live drive: **`animationsStarted=0`**.

`PlayDoorAnimation` is still in `loginEffects` and still ordered last — the effect fires, there is simply nothing left on screen to animate.

## Why this matters
The login door is not incidental chrome. It is a stated design: the secret-bookshelf passage with a dolly-shot, the moment the product introduces itself. Losing it silently would be the kind of quiet erosion this campaign exists to catch — so it is filed rather than absorbed.

⚠️ **Do not fix this by making the token wait again.** The ordering in `Main.loginEffects` carries a ⛔ comment explaining exactly why `PersistAuth` is first and `PlayDoorAnimation` last: *"Anything a browser may decline to run belongs after the credential is durable, never in front of it."* Any restoration must keep that true.

## User Stories
US-14.2.1 (sign in) — the experience half.

## Goal
The dolly-shot plays again, and a reader whose browser declines to run it is still logged in.

## Scope Check
One shell-level view concern plus the port. No auth logic changes. Under the bar.

## Wiring
Router wiring: none. User-facing.

## Technical Requirements
1. **Render the door layers from the shell while `AuthState` is `Arriving`**, over the destination page — the approach #359's author proposed on the way out. `AuthState = Anonymous | Arriving Auth | Authenticated Auth` already exists and `Arriving` currently has **no observable job**; this gives it one, which is a good sign the type was carved at the right joint.
2. **`Arriving` must remain indistinguishable from `Authenticated` for access purposes.** `currentAuth` answers `Just` for both today, and `settleArrival` is total and idempotent so the transition may fire twice or never. Keep both properties — they are what make the backstop safe.
3. **The animation still cannot gate anything.** If it never starts, never finishes, or is cancelled by a fast navigation, the reader is signed in and on the destination page regardless. Prove it: the persist-first suite must stay green **and** its probe must still redden.
4. **Verify it actually plays** — `animationsStarted` > 0 on a real drive, not merely that the effect was dispatched. That distinction is the entire content of this issue.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** (now links `frontend/node_modules`, so `elm-test`/`elm-review` work), then `git merge --ff-only <wave branch>` — local, unpushed.
- **NEVER bare `mix`** — `just run mix …`. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. Stage incrementally.
- ⚠️ Read `Main.loginEffects`' ⛔ comment before touching the ordering. It is the record of a live-diagnosed defect, not style.
- ⚠️ `frontend/tests/PersistFirstLoginTest.elm` has **no message capable of delivering an animation-finished signal** — that absence *is* the occluded-window simulation. Do not add one to make a door test convenient; add a separate harness.
- ⚠️ A literal occluded-window drive is **not achievable under Playwright** — #359 measured it across three launch modes × two page-open methods: the page always reports `visible` and rAF keeps firing. Its two specs reproduce the *mechanism* instead (unresolvable `finished` promises; CDP `Animation.setPlaybackRate: 0`), each asserting the stall took hold before asserting anything else. Reuse that technique rather than rediscovering it.
- Design intent: the secret-bookshelf passage / dolly-shot. Match it rather than inventing a new motion.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm | yes | ❌ the door renders while `AuthState` is `Arriving` and stops at `Authenticated` |
| Elm | yes | ❌ persist-first suite still green; its probe still reddens (the guarantee is untouched) |
| E2E | yes | ❌ `animationsStarted > 0` on a real login — the measurement this issue exists for |
| E2E | yes | ❌ animation frozen/cancelled → reader still lands authenticated on the destination |
| Others | no | n/a |

## Definition of Done
- [ ] Door plays over the arrival, driven from `Arriving` — evidence: screenshot/recording + `animationsStarted > 0`
- [ ] Persist-first guarantee intact — evidence: suite green + probe still red
- [ ] Frozen-animation counterfactual: still authenticated, still navigated — evidence: spec output
- [ ] `check-orphan-classes.sh` zero new; `check-css.sh` clean — evidence: outputs
- [ ] `staff-review` verdict recorded below

## Dependencies
**#359** (created this, and built the `Arriving` state this should use). Natural fit alongside **#363** (Wave 6's presentation sweep) or Wave 8's first-impressions work — needs an owner call on which.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #359's finding 1. The agent built #359 exactly as specified — the issue said three times that the animation must not gate anything — measured the cost (`animationsStarted=0`), documented it in-code, and reported it rather than smuggling in a redesign. That was the right call; this is the follow-through.
Lead-verified: `PlayDoorAnimation` is present in `loginEffects` and ordered last, so the effect fires — the scene is simply unmounted by the time it runs.
