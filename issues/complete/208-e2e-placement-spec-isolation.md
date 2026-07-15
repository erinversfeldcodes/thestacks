# Issue #208: Isolate the privacy-placement E2E spec from shared-user state

## Summary
Child follow-up of the #122 epic. `e2e/tests/privacy-placement.spec.ts` uses the shared seeded `settings` suite user, whose **profile visibility** and **shelf visibility** are also mutated in parallel by `privacy.spec.ts` and `settings.spec.ts`. Under `fullyParallel`, that race intermittently fails the "faint hidden-spine" test (a concurrent spec tightens the profile to `owner`, which — per the #195 ceiling — forces the shelf to `owner` and disables the `platform`/`public` placement options the test needs).

## User Stories
None — E2E test-isolation hardening for US-10.2.2 (the placement feature itself is validated; this is harness isolation).

## Goal
The placement spec is deterministic under full parallel runs (bar item: **no flaky tests**), with no dependence on another spec's mutation of a shared user's profile/shelf visibility.

## Background
The placement feature is genuinely correct and **live-validated in isolation** (`privacy-placement.spec.ts` passes 5/5 when run alone; the #201 serializer + the shelf-spine visibility serialization are confirmed live). The residual is purely cross-spec state contention. Interim mitigations already landed (privacy.spec restores the shelf it changes; `setShelfCeiling` loosens the profile first) reduce but do not fully eliminate the race.

## Technical Requirements
- Convert `privacy-placement.spec.ts` to a **dedicated throwaway user** per test (the pattern proven reliable in `privacy-block.spec.ts`): register → confirm (`STACKS_E2E_TEST_HELPERS`) → login → `ensureBookOnShelf` (suppresses the onboarding overlay + gives a spine) → set the fresh user's profile to `platform` (fresh users default `owner`). This removes ALL sharing with `privacy.spec`/`settings.spec`.
- Alternatively (if a throwaway user proves too heavy for the greying assertions), place the three visibility-mutating specs in a serial Playwright project so they never run concurrently against the shared user.
- Keep the assertions unchanged (dropdown/greying, "Members" label, faint hidden-spine).

## Definition of Done
- [ ] `privacy-placement.spec.ts` no longer depends on shared-user profile/shelf state
- [ ] Green across 3 consecutive full-suite local runs (no flake)
- [ ] `just verify` + the E2E gate pass
- [ ] Meets the Completion Bar (`docs/agents/standards/completion-bar.md`)

## Dependencies
Epic #122. The placement feature (#194/#201) is complete; this is test-harness isolation only.

## Agent Assignment
testing-coordinator.

## Progress Notes
- 2026-07-14: Filed from the #122 final local-E2E run — 38/39 green, the one failure a cross-spec isolation race on the faint-spine test (feature validated in isolation).
