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
- [ ] Persist-first: token saved before any animation effect — evidence: program test + probe transcript
- [ ] `AuthState` introduced; token loss unrepresentable — evidence: the type + impossible-state test
- [ ] Sleep-race backstop, with the chosen behaviour stated — evidence: diff + rationale
- [ ] `transitionState` reset and `redirectAfterLogin` captured at `initPage` — evidence: tests
- [ ] `pendingAuthResponse` cleared or deleted, with reasoning — evidence: diff
- [ ] **Occluded login driven live on preview** — evidence: token-in-localStorage timing vs the 200
- [ ] Suites green under `caffeinate`; `check-orphan-classes.sh` zero new — evidence: counts
- [ ] `staff-review` verdict recorded below

## Dependencies
Epic #316. **Depends on #313** (Login/Session tests had to be trustworthy before this refactor moved under them). Level 1 — parallel with #332 (fully disjoint file). **Precedes #360, #361, #363.**

## Agent Assignment
elm-agent.

## Progress Notes
Filed 2026-07-31 (Wave 6 kickoff).
