# Issue #316: [EPIC] Campaign Wave 6 — Session UX + the deduplication sweep

## Summary
Epic for Wave 6 of `plans/staff-campaign-2026-07-30.md`. The auth credential must never be downstream of a browser animation frame (root-caused live: occluded window → login 200 silently discarded). Plus the "correct decision, hand-copied N times, no gate" sweep: 401 wrapper + reflection gate, save-button, password rule, visibility type, duration.

## User Stories
US-14.2.1 (sign in), US-14.3.2 (session expiry), US-14.4.1 (reset ack), US-16.2.1 (network failures), US-16.3.1, US-17.2.x (settings forms).

## Goal
Login persists the token the moment the 200 arrives (animation is decoration); a hung request can never render as an empty shelf; every authed page handles 401 and a gate enforces it forever; success states are committed states, not paragraphs; the five duplication families collapse to one source each.

## Scope Check
Epic; children per family below.

## Wiring
Router wiring: none; user-facing behaviour changes throughout.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-14.2.1 sign-in completes while window occluded | token write gated on WAAPI promise (app.js:495-503) | 3× login 200 discarded, 2026-07-30 | ❌ | build in-scope (persist-first) |
| US-16.2.1 offline shelf nav shows failure state | none — Loading renders as empty bookcase | silent no-op driven live | ❌ | build in-scope |
| US-14.3.2 mid-form 401 on Password/Profile/Notifications | 2-tuple updates, no OutMsg | "try again" lie driven live | ❌ | build in-scope |

## Technical Requirements (child phases)
1. **Persist-first login + AuthState**: on `GotAuthResponse (Ok r)` set auth, `saveAuth`, fire completion effects, `pushUrl` immediately; door animation becomes ornament (`AuthState = Anonymous | Authenticated Auth | Arriving Auth` — token loss unrepresentable); sleep-race backstop on the port; reset the `transitionState` trap (`Login.elm:650` + `ModeSwitched`); `redirectAfterLogin` captured at `initPage` (stop losing the asked-for page); clear `pendingAuthResponse` on UrlChanged (or delete it — subsumed by AuthState).
2. **Title + notices**: derive `document.title` from `Page` (closes six route/content divergences, `Main.elm:2735-2905`); `Arrival = Fresh | SessionExpired {draftSaved} | AccountDeleted | ForgotPassword` replacing six booleans + five inits + two view predicates; `decodeFlags` → `StoredAuth = NoStoredAuth | CorruptStoredAuth String | ValidStoredAuth` with the corrupt case surfaced.
3. **401 wrapper + gate**: authed-request wrapper whose result type forces 401 handling; convert Profile/Password/Notifications (the three write-forms — `Password.elm:61`, `Profile.elm:89`, `Notifications.elm:49`); **the reflection gate**: a test enumerating `src/Page/` modules that make authed `Api.*` calls and asserting each exposes `SessionExpired` (the #173/#178 lesson: hand-written coverage lists rot).
4. **Loading ≠ empty + connectivity**: every `RemoteData` shelf consumer renders a real Loading (never shares a branch with `Success []` — `Bookshelf.elm:522-527`); `Api.elm` requests gain timeouts; shell connectivity banner via online/offline port on the `handleSessionExpiry` architecture.
5. **Success states + dedup**: forgot-ack becomes a `role="status"` notice (the component exists on that card); reset success survives keystrokes (`ResetPassword.elm:61,64`) + auto-advances; promote `Profile.viewSaveButton` to `Components/` (fix its dead Success button) replacing the ×6 copies; single password-rule source (9 sites, 4 wordings); `Visibility` custom type at the decode boundary replacing `== Just "owner"` ×3 (+ visible "hidden" affordance — currently labelled only for screen readers, opacity fails contrast); `Duration.to_seconds/1` for the ×3 `{n,unit}` copies.

## Reviewer Context
- Occlusion repro recipe: drive with the browser window fully covered/backgrounded; assert token in localStorage within 1s of the 200 regardless. The 2026-07-30 evidence: ten frozen 300ms transitions, zero WAAPI animations, no follow-up XHR.
- Register path (`Login.elm:316-323`) is the model — copy its shape, keep its comment discipline.
- Do NOT write per-page 401 tests before the wrapper lands (they'd be deleted by it) — prior plan's Wave-5 warning stands.
- `elm-review --fix` narrows `Msg(..)` exposures — land enabling changes with their consuming tests.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine | yes | ❌ persist-first program test (token stored before any animation msg); AuthState impossible-state checks; Arrival/StoredAuth decode tests; Loading-view tests per shelf page |
| Auth & guards | yes | ❌ the reflection gate itself; 3 converted pages' 401 → SessionExpired tests |
| API | yes | ❌ timeout behaviour test |
| E2E | yes | ❌ occluded-login spec (or documented headless equivalent); mid-form 401 redirect spec |
| Others | n/a at epic level | per child |

Punch: 8 items; suites named at spin-out.
Verdict: baseline ❌ ×8.

## Definition of Done
- [ ] Live drives on preview: login with window occluded → authenticated (token stored ≤1s after 200); mid-form 401 on Password → redirect + notice (not "try again"); offline shelf nav → visible failure state; hung request → Loading view, never empty bookcase — evidence: screenshots/recordings + localStorage timing
- [ ] Reflection-gate probe: adding an authed page without SessionExpired fails the suite — evidence: probe transcript
- [ ] Mutation probe: skip `saveAuth` → the persist-first test reddens — evidence: transcript
- [ ] Feature-Completeness rows ✅; validation path per behaviour; suites + `just verify` green
- [ ] Test audit GREEN; `completion-audit` passed; Completion Bar met (incl. logs clean under drive)
- [ ] `staff-review` verdict per child in Progress Notes

## Dependencies
- #313 — Login/Session tests must be trustworthy before the AuthState refactor moves under them. Reason: guarantees before refactors.
- #312 — `Route.Settings` collapse and notice cleanups land there first. Reason: deletions first.
- Precedes #317 (its notices/copy use these components) and #318 (nav uses the Elm-owned disclosure pattern established here).

## Agent Assignment
Orchestrator; elm-agent (primary), elixir-agent (Duration, timeout config).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
