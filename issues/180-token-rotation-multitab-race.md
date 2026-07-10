# Issue #180: Token-rotation multi-tab / in-flight race causes spurious logout

## Summary
#173's silent renewal rotates the access token (revoke old + mint new) every ~7h. Two races can log
a user out spuriously: (1) **in-flight** — a request that left with the old token but reaches the
server *after* the rotation's revoke gets a 401 → the interceptor logs the user out; (2) **multi-tab**
— tab A renews (revokes `T0`, saves `T1` to localStorage) while tab B still holds `T0` in memory; tab
B's next request 401s and its `clearAuth ()` wipes the `T1` tab A just saved, logging out every tab.
Neither is a security hole (the token was validly rotated), but both are jarring UX.

## User Stories
US-14.3.2 (Session Expiry & Token Refresh) — robustness of the renewal introduced there.

## Goal
Token rotation never causes a spurious logout: an in-flight request with a just-rotated token, and
other tabs, gracefully adopt the renewed token instead of being kicked to `/login`.

## Scope Check
- Frontend coordination in `Main.elm` (renewal + the interceptor) ± a small backend grace window. One
  concern (rotation race). < 300 LOC.

## Wiring
- [x] Router/UI-adjacent (SPA auth state); no new endpoint unless the grace-window option is chosen.

## Technical Requirements
Pick one (or combine) after weighing:
1. **Re-check localStorage before logout:** on a `Http.BadStatus 401`, before running `sessionExpired`,
   re-read stored auth — if a *newer* token exists (a peer tab renewed), adopt it and retry/continue
   instead of logging out.
2. **Cross-tab coordination:** propagate a renewed token to other tabs (a `storage` event or
   `BroadcastChannel`) so tabs swap to `T1` rather than using stale `T0`.
3. **Backend grace window:** keep the old token verifiable for a few seconds after rotation
   (guardian_db) so in-flight requests don't 401. (Weigh against the security intent of immediate
   rotation from #179.)

## Reviewer Context
- Renewal + interceptor live in `Main.elm` (`RenewToken`/`TokenRefreshed`/`sessionExpired`, ~1591-1620);
  `saveAuth`/`clearAuth` ports persist/clear localStorage.
- Coordinate with #179 (if a grace window is added it must not undermine the reuse-detection cap).

## Test Audit
_Compact — SPA auth-state robustness. Green when a rotation no longer logs peer/in-flight sessions out._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 Elm state machine | yes | ❌ a 401 with a newer stored token adopts it (no logout); renewal propagates across tabs. Validation: elm program test (401 + newer stored token → not logged out) + (if feasible) a Playwright two-context test that a renewal in one context doesn't log out the other. |
| 2 Auth / grace window (if chosen) | maybe | ❌ backend grace-window verify test |
| others | no | n/a |

## Definition of Done
- [ ] A 401 caused by a just-rotated token does NOT log the user out when a newer valid token is available
- [ ] A renewal in one tab does not log out other tabs / wipe the renewed token
- [ ] Validation path: elm program test for the re-check-before-logout path; a browser test for the multi-tab case where feasible (else documented n/a)
- [ ] `elm-test` + `just verify` pass
- [ ] Test audit (embedded) is GREEN

## Dependencies
- #173 (renewal + interceptor). Coordinates with #179 (grace window vs immediate rotation).

## Agent Assignment
elm-agent (± security-agent for a grace window).

## Progress Notes
- 2026-07-10: Filed from #173's PE gate (P3). Reviewers confirmed it's UX degradation, not an auth
  hole — the rotated token is validly dead; the fix is graceful adoption of the renewed token.
