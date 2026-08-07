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
- [ ] Root cause identified — evidence: a reproduction + the failing path (file:line)
- [ ] Fix lands; repeated `--project=setup` runs green — evidence: 3× consecutive
- [ ] `staff-review` verdict recorded

## Dependencies
Sibling of #371 (done). Independent otherwise.

## Progress Notes
Filed 2026-08-07 from the #371 triage footnote, so closing #371 does not bury it.
