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
- [ ] Ports wired (or inbound dropped with reasoning) — evidence: diff
- [ ] Live drive: finish onboarding, reload, overlay gone — evidence: screenshot/steps on a preview
- [ ] `staff-review` verdict recorded

## Dependencies
The behaviour half of #366 (the gate). #366 lands the detector; this lands the fix it detects.

## Progress Notes
Filed 2026-08-07 from the #366 triage (the gate found two real live orphans, not hypotheticals).
