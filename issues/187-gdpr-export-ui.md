# Issue #187: GDPR Export UI (Elm)

**Epic:** #121 (E2E Test Suite — GDPR Compliance)

## Summary
Build the user-facing "Export My Data" flow on the Settings/GDPR page, wired to the existing export endpoint.

## User Stories
US-8.1 (Export Personal Data — frontend).

## Goal
A signed-in user can click "Export My Data", see a loading state while the request is queued, and get a clear "Export queued" confirmation (or an error).

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? No (Elm only).
- Does this issue add more than 2 new endpoints? No (backend already returns 202).
- Does this issue exceed ~300 lines of production code? No.
- Does this issue combine unrelated concerns? No (export UI only).

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Baseline = "to verify"; fill verdicts + file:line evidence when picked up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.1 — Export Personal Data (frontend) | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Elm on the Settings/GDPR page: "Export My Data" button → `UserClicksExport` → Loading ("Preparing your export…") → `GotExportResponse (Ok/Err)` → Success ("Export queued").
- Wired to `POST /api/gdpr/export` (backend already returns 202).
- Use `RemoteData` for the call state (project convention for all API calls).

## Reviewer Context
<!-- Non-obvious project conventions relevant to this issue. -->
- All Elm API calls use `RemoteData` (NotAsked / Loading / Success / Failure).
- Msg types for tested pages must expose `Msg(..)` so tests can construct them.

## Test Audit
Test Audit: generated when picked up.

## Definition of Done
- [ ] "Export My Data" button + `UserClicksExport` Msg
- [ ] Loading state ("Preparing your export…")
- [ ] `GotExportResponse (Ok/Err)` handling → Success ("Export queued") / error
- [ ] Wired to `POST /api/gdpr/export` via `RemoteData`
- [ ] `just verify` passes
- [ ] E2E / elm-test coverage

## Dependencies
None — the export backend endpoint already exists (returns 202).

## Agent Assignment
elm-agent.

## Progress Notes
