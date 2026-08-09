# Issue #394: Intermittent `mfa confirm` 422 on the preview E2E setup

> **Campaign assignment:** Wave 11 (launch gates) — surfaced by the #371 triage (2026-08-07).

## Summary
`e2e/tests/auth.setup.ts` (the owner-MFA enrol step, via `helpers.ts:588` `mfa confirm`) **intermittently returns 422** on the 1024 MB preview — passes one run, fails the next at identical code. When it hits, it blocks `admin-session.spec.ts` + `audit-log.spec.ts`. This is NOT the #371 shared-factor bug (that is fixed, `babcc4be`); it is a separate MFA-reliability / secret-encoding question that was buried as a footnote on the otherwise-complete #371.

## Goal
The owner-MFA enrol setup step is deterministic — `mfa confirm` does not intermittently 422 — so the admin/audit specs run reliably at the shipped worker count.

## Technical Requirements
1. Reproduce + root-cause the intermittent 422 (TOTP time-window edge? base32 decode? a race between enrol and confirm?). The #371 story notes the base32/base64 history (`admin_auth_controller.ex:116-126`) — check whether a residual encoding/timing edge remains.
2. Fix so the confirm is deterministic (e.g. compute the TOTP against the server clock window, retry on the ±1 step boundary, or seam the time).
3. Prove it: repeated setup runs green.

## Definition of Done
- [x] Root cause identified — evidence: `apps/core/lib/stacks/mfa.ex:55` (`confirm_enrollment`) and `:100` (`verify_totp`) validate with a bare `NimbleTOTP.valid?` — EXACTLY the current 30s step, no ±1-step allowance — while `e2e/tests/helpers.ts` computed the code from the LOCAL clock. A code generated in the last moments of a step is stale when validation lands in the next; per-run failure probability = (latency + skew)/30s, matching "passes one run, fails the next at identical code". Not the base32 encoding (that path is fixed and single-shot deterministic).
- [x] Fix lands; repeated `--project=setup` runs green — evidence: `freshTotp/2` in helpers.ts — waits out the step boundary when the server-adjusted clock is within a 5s guard band, computing against the server's `Date`-header clock (skew from the mfa-setup response; +500ms centres the 1s truncation). Deterministic by construction, NOT a retry — an encoding regression still fails every run. Same fix applied to `admin-session.spec.ts`'s gate fill (same hazard, presented as "the gate never opened"). 3× consecutive `--project=setup` runs against the preview 2026-08-09: 3 passed / 3 passed / 3 passed (incl. the enrol step).
- [x] `staff-review` verdict recorded — see Wave 11 close-out

## Dependencies
Sibling of #371 (done). Independent otherwise.

## Progress Notes
Filed 2026-08-07 from the #371 triage footnote, so closing #371 does not bury it.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM** — deterministic by construction (boundary wait against the server clock), NOT a retry — an encoding regression still fails every run, which the old assert message worried about. 3× setup green.
