# Issue #395: Orphan onboarding ports — onboarding re-triggers on reload

> **Campaign assignment:** Wave 11 (launch gates) — the behaviour-fix half of #366 (2026-08-07).

## Summary
Two Elm ports are declared but not wired in `app.js`, and the gap is user-visible:
- `saveOnboardingCompleted` (`frontend/src/Main.elm:125`, outbound `Cmd`, fired at `:3074`) has **no** `app.ports.saveOnboardingCompleted.subscribe` in `apps/core/assets/js/app.js` — the string `onboarding` does not appear in app.js at all.
- `onOnboardingStatus` (`Main.elm:128`, inbound `Sub`, subscribed at `:3444`) has nothing sending to it.

Consequence: `Main.elm:3073` sets `onboardingCompleted = True` in-model, but the localStorage mirror never happens (`Main.elm:555` inits it `False`; `shouldShowOnboarding` at `:4332-4335` = `not onboardingCompleted && not hasAnyPlacements`). **A reader who finishes onboarding without shelving anything sees the overlay again on every reload.**

## Goal
Finishing onboarding persists across reloads for every reader, shelved or not.

## Technical Requirements
1. Wire `saveOnboardingCompleted` in app.js to persist to localStorage; wire `onOnboardingStatus` to read it back on boot (or drop the inbound port if hydration already covers it — decide and document).
2. Live-drive the fix: finish onboarding with zero placements, reload, confirm the overlay does NOT reappear.
3. The #366 gate (once it lands) must go green on these two ports.

## Definition of Done
- [x] Ports wired — evidence: `34debb97` — onboarding-completed ports wired to localStorage (`stacks-onboarding-completed`)
- [x] Live drive: finish onboarding, reload, overlay gone — evidence: VALIDATED LIVE 2026-08-08 on the preview (key persists; overlay stays gone) and re-validated by the finalize real-login E2E 2026-08-09 (settings.spec.ts:843, updated by `8553e25b` to stop relying on the pre-fix bug)
- [x] `staff-review` verdict recorded — see Wave 11 close-out below

## Dependencies
The behaviour half of #366 (the gate). #366 lands the detector; this lands the fix it detects.

## Progress Notes
Filed 2026-08-07 from the #366 triage (the gate found two real live orphans, not hypotheticals).

## Verification (2026-08-08, Wave 11)
onboarding-ports wiring validated LIVE on preview (finish → reload → overlay stays gone; stacks-onboarding-completed key persists); gated by #366.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — wired through localStorage with live validation both before and after the E2E spec update; the spec no longer depends on the bug it once accommodated.
