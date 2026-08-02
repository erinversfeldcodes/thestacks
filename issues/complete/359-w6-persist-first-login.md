# Issue #359: W6 child — The login token must not be downstream of an animation frame

## Summary
Child of epic #316, Level 1 — the wave's founding defect, root-caused live on 2026-07-30. `apps/core/assets/app.js:495-503` gates the auth-token write on a Web Animations API promise. **With the browser window occluded or backgrounded, WAAPI never fires** — so the login `200` arrives, and the credential is silently discarded. Observed: **three logins returning 200 with the token never stored**, ten frozen 300 ms transitions, zero WAAPI animations, and no follow-up XHR.

The door animation is decoration. It must never sit between a successful authentication and the persistence of its credential.

## User Stories
US-14.2.1 (sign in), US-14.3.2 (session expiry).

## Goal
On `GotAuthResponse (Ok r)` the app sets auth, saves it, fires completion effects and navigates **immediately**. The animation plays or doesn't; either way the reader is logged in. Losing a token becomes unrepresentable rather than unlikely.

## Scope Check
One Elm page + the app shell + one JS port. Under the bar. ⚠️ The `Arrival`/`StoredAuth` types and the `document.title` derivation are **#360**; the 401 wrapper is **#361**. Do not absorb them.

## Wiring
Router wiring: none new. User-facing: login works when the window is not in front.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-14.2.1 sign in with the window occluded | token write gated on the WAAPI promise (`app.js:495-503`) | **3× login 200 discarded** (2026-07-30) | ❌ | build in-scope |
| US-14.2.1 land on the page you asked for | `redirectAfterLogin` read after navigation | asked-for page lost | ❌ | fix in-scope |

## Technical Requirements
1. **Persist first, animate second.** On `GotAuthResponse (Ok r)`: set auth → `saveAuth` → completion effects → `pushUrl`, all before any animation concern. The animation becomes an ornament that cannot gate anything.
2. **Make the loss unrepresentable:** `AuthState = Anonymous | Authenticated Auth | Arriving Auth`. The point is the type, not the refactor — after this, "authenticated but token not saved" should not be a state anyone can construct.
3. **Backstop the sleep race on the port.** Even with persist-first, the port can be entered on a machine that then sleeps; state the behaviour you chose.
4. **Reset the `transitionState` trap** (`Login.elm:650` + `ModeSwitched`) — a stuck transition state currently survives a mode switch.
5. **Capture `redirectAfterLogin` at `initPage`,** so the page the reader actually asked for is not lost by the time login completes.
6. **Clear `pendingAuthResponse` on `UrlChanged`** — or delete it outright if `AuthState` subsumes it. Say which and why.

## Reviewer Context
- BOOTSTRAP: **`just bootstrap-worktree`** from inside the worktree, then `git merge --ff-only feat/campaign-w6-316` — **LOCAL, UNPUSHED**; no `git fetch`, no `origin/`.
- **NEVER bare `mix`** — `just run mix …`. **`caffeinate -i`** for long suites. **NEVER `git checkout`** to revert a probe — Edit, then `grep -c`. **Stage incrementally** (an agent stalled mid-wave and kept its work only because edits were on disk).
- ⚠️ **The occlusion repro is the acceptance test.** Drive with the window fully covered or backgrounded and assert the token is in `localStorage` **within 1 s of the 200, regardless of animation**. A test that passes only with the window focused reproduces the bug's blind spot.
- ⚠️ **`Page.Login`'s register path (`Login.elm:316-323`) is the model** — copy its shape and its comment discipline rather than inventing a second one.
- ⚠️ You own `Login.elm`, `Main.elm` and `app.js` for this wave. **#360 takes `Main.elm` after you** — leave it in a state someone else can build on.
- ⚠️ Elm pages with tests must expose `Msg(..)`; `elm-review --fix` narrows it back if no test consumes it — land the exposure with its consuming test, never a suppression.
- ⚠️ `frontend/css/main.css` is the only stylesheet source. Run `bash scripts/check-orphan-classes.sh` (add **zero**) and `bash scripts/check-css.sh` if you touch CSS. Note the orphan gate is blind to computed `class (if …)` forms (#356) — verify any such rule by hand.
- Commit: agent commits are DENIED. Stage; ONE-LINE message (no body/trailers) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-359.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine | yes | ❌ persist-first program test: the token is stored **before** any animation msg is processed — probe by skipping `saveAuth` |
| Elm state machine | yes | ❌ `AuthState` impossible-state checks (authenticated-without-saved-token unconstructable) |
| Elm | yes | ❌ `redirectAfterLogin` survives to completion; `transitionState` resets on mode switch |
| E2E | yes | ❌ occluded-login spec, or a documented headless equivalent with the reason it is equivalent |
| Others | no | n/a |

## Definition of Done
- [x] Persist-first: token saved before any animation effect — evidence: `Main.loginEffects` orders `PersistAuth` first and `PlayDoorAnimation` last (⛔ comment on the line); live drive 2026-08-01 measured `token_written_at_ms: 198086` vs `login_200_at_ms: 198087` (`delta_ms: -1`)
- [x] `AuthState` introduced; token loss unrepresentable — evidence: `Main.AuthState = Anonymous | Arriving Auth | Authenticated Auth`
- [x] Sleep-race backstop, with the chosen behaviour stated — evidence: diff + rationale in the module comment
- [x] `transitionState` reset and `redirectAfterLogin` captured at `initPage` — evidence: tests; and confirmed live — a mid-form 401 on `/settings/password` returned the reader to `/settings/password` after re-login (drive, 2026-08-01)
- [x] `pendingAuthResponse` cleared or deleted, with reasoning — evidence: diff
- [x] **Occluded login driven live on preview** — evidence: drive 2026-08-01 against `stacks-core-pr-feat-campaign-w6-316.fly.dev`. Instrumented `Element.prototype.animate`, `Storage.prototype.setItem` and `XMLHttpRequest.prototype.send`; result `{"animations_started":0,"login_200_at_ms":198087,"token_written_at_ms":198086,"delta_ms":-1,"token_present":true,"url":"/antilibrary"}`. **Zero animations ever started and the token was persisted anyway** — strictly stronger than occlusion, which only prevents frames. Also covered by `auth.spec.ts:324` and `:377`, both green against the preview.
- [x] Suites green under `caffeinate`; `check-orphan-classes.sh` zero new — evidence: counts recorded at merge
- [x] `staff-review` verdict recorded below — **LGTM** (recorded in `plans/316-campaign-w6-epic-state.json`)

## Dependencies
Epic #316. **Depends on #313** (Login/Session tests had to be trustworthy before this refactor moved under them). Level 1 — parallel with #332 (fully disjoint file). **Precedes #360, #361, #363.**

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-31 (Wave 6 kickoff).

**staff-review verdict: LGTM** (2026-07-31, lead, Mode B on e3114305). Praise: (a) **the type does the work** — `completeLogin : Api.AuthResponse -> CompletedLogin` returns `{session, authState, effects}` as *one value*, so `Arriving auth` cannot be reached without also being handed the `PersistAuth` that backs it. There is no longer a variant meaning "we hold a token but have not written it", which is exactly what the old `pendingAuthResponse` + `auth = Just` pair could represent; (b) **the test harness has no message capable of delivering an animation-finished signal — that absence *is* the occluded window**, by construction rather than by mocking; (c) it **measured** that a literal occlusion drive is impossible under Playwright rather than assuming either way: three launch modes × two page-open methods, all reporting `visible` with rAF still firing. Its first attempt asserted `visibilityState === "hidden"` and **failed on that assertion instead of passing vacuously** — that failure is what produced the measurement; (d) the two replacement specs reproduce the *mechanism* (unresolvable `finished` promises; CDP `Animation.setPlaybackRate: 0` against the real engine) and each asserts the stall actually took hold (`stallProof`) **before** asserting anything else, so neither can quietly stop reproducing its own precondition; (e) **the counterfactual is the strongest evidence in the campaign so far** — it rebuilt the pristine pre-#359 SPA from git objects into a temp tree, swapped it in and rebuilt, and both new specs **fail with `token: null`**. They demonstrably catch the original bug. And it did that **without `git checkout` or `git stash`**, respecting the rule that has destroyed uncommitted work here three times; (f) it deleted `transitionState` rather than resetting it, having found it duplicated `submitState`, latched on success and had **no reset path anywhere** — so an unfinished animation left the card permanently unable to submit.
Live drives (local stack): plain login **token stored 2 ms after the 200**; deep link `/upload` while signed out → bounce → sign in → **lands on `/upload`** (token 1 ms); wrong password → error, submit re-enabled, retry succeeds. Console clean.
Probe: removing `PersistAuth` from `loginEffects` reddens 4 tests including `completeLogin cannot produce an authenticated state without the effect that saves it`. Reverted via Edit, grep-verified.
**⚠️ P1 disclosed, not hidden → filed as #364.** The door dolly-shot no longer plays (`animationsStarted=0`): navigation unmounts the login scene before the port's frame callback runs. The agent built #359 exactly as written — the issue said three times that the animation must not gate anything — measured the cost, documented it in-code, and **reported it rather than smuggling in a redesign**. Lead-verified: `PlayDoorAnimation` is still in `loginEffects` and still ordered last, so the effect fires; there is simply nothing left on screen. Its proposed fix (render the door from the shell while `AuthState` is `Arriving`, over the destination) is carried into #364 and gives `Arriving` its first observable job.
E2E: **270 passed / 21 failed / 10 skipped**, and all 21 reproduce identically on the pre-#359 baseline — 15 × `assets.spec.ts` (textures are git-lfs pointers in a worktree), 3 × `admin-session.spec.ts` (pass serially), 3 others. Reported with that comparison rather than as a bare count.
Gates: elm-test **1389/0**, `lint-elm.sh` green (elm-format `[]`, elm-review no errors, orphan classes **88 / 0 unstyled — zero added**, CSS 0 problems, vacuous-guard clean, admin-token routing 6/6).
**Findings carried forward:** (1) **`redirectAfterLogin` is not captured on the session-expiry path** — `forceSessionExpiry` pushes `/login` and the asked-for page is lost; natural home **#361**; (2) **a `platform`-visible bookshelf's Atom feed 404s** — traced in the Phoenix log: the visibility PUT returns 200 and updates the row, then `GET /api/feeds/<uid>/library` 404s from `Stacks.Feeds.resolve_shared_bookshelf/2`. Server-side, **pre-existing**, currently red in `rss.spec.ts:189`; (3) **`admin-session.spec.ts` cannot run in parallel with itself** — three tests enrol MFA on the same owner, last write wins, the others 401; green at `--workers=1`, red at 4; (4) `loginEffectCmd`'s effect→`Cmd` mapping is unreachable from elm-test (opaque `Cmd`, unconstructable `Nav.Key`) — covered by an E2E probe, and a `check-*.sh` in the style of `check-admin-token-routing.sh` would make it a permanent gate.
`Main.elm` left clean for #360: `AuthState(..)`, `CompletedLogin`, `completeLogin`, `currentAuth`, `settleArrival`, `loginRedirectFor` all exposed and unit-tested; no `Arrival`/`StoredAuth` names taken.
