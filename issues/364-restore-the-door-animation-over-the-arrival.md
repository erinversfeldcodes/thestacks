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
- [~] Door plays over the arrival, driven from `Arriving` — BUILT: `viewArrivalDoor : AuthState -> Html Msg` renders the scene (with the port's target ids `#bookshelf` etc.) from the shell over the destination on `Arriving _`, `text ""` on `Anonymous`/`Authenticated`. ⚠️ `animationsStarted > 0` **live drive owed at the epic coherence sweep** — not claimed from the code read (the code-read only shows the ids will be present for `getElementById`).
- [x] Persist-first guarantee intact — evidence: `loginEffects` UNTOUCHED (diff confirms; `PersistAuth` first / `PlayDoorAnimation` last, ⛔ comment verbatim); `PersistFirstLoginTest` green AND its probe (remove `PersistAuth`) reddens `persist_first_no_animation_signal` — re-run 2026-08-05, reverted via Edit. No animation-finished message added to that suite.
- [~] Frozen-animation counterfactual — SPEC BUILT in `e2e/tests/auth.spec.ts` (`#364` block) reusing #359's CDP `Animation.setPlaybackRate: 0` + unresolvable-`finished` technique, asserting the stall took hold before asserting still-authenticated-and-navigated; live run owed at the coherence sweep.
- [x] `check-orphan-classes.sh` zero new; `check-css.sh` clean — evidence: orphans: 0; `check-css` 816 rules 0 problems 0 collisions.
- [x] `staff-review` verdict recorded below

## Dependencies
**#359** (created this, and built the `Arriving` state this should use). Natural fit alongside **#363** (Wave 6's presentation sweep) or Wave 8's first-impressions work — needs an owner call on which.

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-31 by the lead from #359's finding 1. The agent built #359 exactly as specified — the issue said three times that the animation must not gate anything — measured the cost (`animationsStarted=0`), documented it in-code, and reported it rather than smuggling in a redesign. That was the right call; this is the follow-through.
Lead-verified: `PlayDoorAnimation` is present in `loginEffects` and ordered last, so the effect fires — the scene is simply unmounted by the time it runs.

### Built 2026-08-05 (staff-review: LGTM, live drive owed)
Implemented as #359's author proposed on the way out: the door is rendered from the SHELL during
`AuthState.Arriving`, over the destination page, so the port's `getElementById` targets are present
when it animates — rather than racing the login scene's unmount. `viewArrivalDoor` is a pure
`AuthState -> Html Msg` (door on `Arriving`, `text ""` otherwise); the whole diff is additive (+253,
no change to `loginEffects` or `currentAuth`). Reduced-motion: CSS hides `.arrival-door` and `app.js`
short-circuits the port to `signalComplete()` — no dolly, credential already durable.

**staff-review: LGTM.** The safety property is intact and independently confirmed: `loginEffects` is
untouched in the diff, and the persist-first probe still reddens. The NEW behaviour's oracle
(`DoorArrivalTest`) was **mutation-probed** — suppressing the `Arriving` render reds exactly
`door_renders_while_arriving` + `door_animates_the_bookshelf` (the `#bookshelf` layer the port
dollies); reverted via Edit, re-confirmed 19/0. Elm suite 1692/0; gates clean.

⚠️ **Owed at the epic coherence sweep:** the actual `animationsStarted > 0` live drive + a recording of
the dolly-shot, and a live run of the frozen counterfactual. The specs are built and parse; the
measurement — the entire content of this issue — is NOT claimed from the code read.
