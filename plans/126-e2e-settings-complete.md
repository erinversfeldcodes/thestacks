# Complete: Issue #126 — E2E Test Suite: Settings Hub

**Completed**: 2026-07-26 · **Branch**: `feat/125-126-e2e` (epic with #125) · **Status**: all phases done, gates green; PR held for owner inspection

## Phases
1. **Re-baseline + live-drive** (5ff8d413) — 3 stories ✅ live; CG-1/CG-2 failures reproduced; CG-1 found BROADER than scoped (ALL UI profile saves 422'd via the email-key branch).
2a. **Notifications GET + same-email tolerance** (0bb73dcb) — auth-gated read endpoint; `email_change?/2` normalised comparison. elixir + contract reviewers APPROVED; gdpr-review PASS.
2b. **CG-1 + CG-2 frontend** (7f059a60) — conditional current-password input; `encodeProfileBody` omits unchanged email/handle; RemoteData hydration. Revision 1: the live-drive-caught **handle NOT-NULL 500** fixed two-sided (`drop_blank_handle_change` + omit-unchanged-handle). All 3 payoffs re-driven green.
3. **Elixir sad paths + payload strip** (7b5ca24b) — negative emissions ×5, defaults, 422-via-cast, 429 through the real pipeline, 503 ×2; `user.notifications_updated` payload → `%{}` (#121-consistent). APPROVED.
4. **Elm units** (d6ab9f7e) — hub 8, password 17, location/setters 9, notifications 4. APPROVED.
5. **E2E UI flows** (b6ffa7b5) — 9 tests/6 flows incl. auth guard, mobile-select real navigation, CG-1/CG-2 payoffs. APPROVED. (+959eac6e semgrep regex fix.)
6. **dbt guards** (d798a8bb) — country_code shape + profile-column propagation singular tests. database-reviewer APPROVED.
7. **Audit → GREEN** (c6ebd6b4) — 48✅/0⚠️/0❌/82 n/a; 22 punch + 3 CG items closed; GDPR Review Record embedded.

## Final evidence
- Backend 2955/0 · elm-test 1173/0 · dbt 239 PASS · preview settings suite 27/27 in the 62/0/0 epic subset · **far-end proof**: preview Neon branch `op.event_log` rows from the E2E run carry `payload: {}`.
- DoD: 10/10 ticked with evidence tokens (2082f933).

## Follow-ups spawned
- **#299** (filed): GDPR export omits settings personal fields — P1, pre-existing, elevated by the epic PE gate.
- Epic-state notes: interceptor-on-settings-save; write-side email normalisation; local `stacks_dbt` view perms; optional `country_code` CHECK.
