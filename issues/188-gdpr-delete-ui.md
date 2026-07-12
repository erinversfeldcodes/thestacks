# Issue #188: GDPR Delete-Account UI (Elm)

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Build the user-facing account-deletion flow on the Settings/GDPR page with a type-to-confirm guard, wired to the existing delete endpoint.

## User Stories
US-8.2 (Delete All Personal Data — frontend).

## Goal
A signed-in user can request account deletion behind a "type DELETE to confirm" guard, see it queued, and be logged out / shown a farewell.

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (Elm only).
- Does this issue add more than 2 new endpoints? No (backend already returns 202).
- Does this issue exceed ~300 lines of production code? No.
- Does this issue combine unrelated concerns? No (delete UI only).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.2 — Delete All Personal Data (frontend) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Elm Settings/GDPR page: "Delete My Data" → confirmation dialog → `UserTypesDeleteConfirmation` enabling the submit button **only when the text is exactly `"DELETE"`** → `UserClicksDeleteAccount` → Loading → Success ("Account deletion has been queued") → logout/farewell OutMsg.
- Wired to `DELETE /api/gdpr/account` (backend returns 202).
- Use `RemoteData` for the call state.

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- The submit button must be disabled until the confirmation text equals exactly `"DELETE"` (not a substring/case-insensitive match).
- All Elm API calls use `RemoteData`; Msg types for tested pages must expose `Msg(..)`.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] "Delete My Data" → confirmation dialog
- [ ] `UserTypesDeleteConfirmation` enables submit only when text is exactly `"DELETE"`
- [ ] `UserClicksDeleteAccount` → Loading → Success ("Account deletion has been queued")
- [ ] Logout/farewell OutMsg on success
- [ ] Wired to `DELETE /api/gdpr/account` via `RemoteData`
- [ ] `just verify` passes
- [ ] E2E / elm-test coverage

## Dependencies
None — the delete backend endpoint already exists (returns 202).

## Agent Assignment
elm-agent.

## Progress Notes
