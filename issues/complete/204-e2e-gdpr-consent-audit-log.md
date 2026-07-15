# Issue #204: E2E — browser-drive the untested GDPR UI surfaces (writing-assistant consent + audit-log read)

## Summary
Two shipped GDPR stories were never browser-live-driven — they pass only at the program/controller-test layer. Add Playwright specs that drive the writing-assistant consent toggle and the audit-log read page through the real UI.

## User Stories
- US-8.3 (writing-assistant consent half — the analytics half is already E2E-driven)
- US-8.5 (audit-log read)

## Goal
Both GDPR surfaces are exercised against a running stack through the real UI, satisfying completion-bar item 1 (every named story driven live, not program-test-only).

## Scope Check
- Touches 0 controllers (test-only). OK.
- Adds 0 endpoints. OK.
- ~2 Playwright specs, well under 300 LOC. OK.
- Single concern (GDPR UI E2E). OK.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only (test harness). No production wiring.

## Feature-Completeness Pre-Check
Both stories are BUILT (pages ship; the gap is live-drive, not implementation).

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-8.3 WA consent | `frontend/src/Page/Settings/Consent.elm` (WA toggle + save + off-copy); route `/settings/consent` | ⬜ to verify | 🟡 built, not driven | add Playwright flow |
| US-8.5 audit-log read | `frontend/src/Page/Settings/AuditLog.elm`; `audit_log_controller.ex:24` index; route `/settings/audit-log` (#189) | ⬜ to verify | 🟡 built, not driven | add Playwright spec |

Verdict: 🟡 partial — happy paths built, live-drive missing.

## Technical Requirements
- **WA consent flow** (extend `e2e/tests/settings.spec.ts` — today `:17-19` only drives `analytics-consent-toggle`): drive the writing-assistant toggle, save, assert the off-copy string rendered by `Consent.elm`, reload and assert persistence.
- **Audit-log spec** (new `e2e/tests/audit-log.spec.ts` — none exists today): navigate `/settings/audit-log`, assert entries render with decrypted `metadata`; assert **no IP column** is ever shown (`audit_log_controller.ex:41` never selects hashed IP); cover empty-state and error-state.
- Reuse the flake-lessons proven in `e2e/tests/gdpr.spec.ts`: seeded vs throwaway users, dismiss the onboarding overlay, `:auth` 429-retry, and `STACKS_E2E_TEST_HELPERS` for state setup.

## Reviewer Context
- `analytics-consent-toggle` is a distinct test-id from the WA toggle; do not conflate.
- Audit log stores hashed IPs but the controller deliberately excludes them — the spec must assert their absence, not just presence of rows.
- Preview E2E needs seeded users; local stack via `scripts/test-e2e.sh` first (completion-bar §7).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls (consent save, audit index) | yes | ❌ driven only in program tests → ✅ when Playwright asserts live |
| auth & middleware guards (consent-gated audit route) | yes | ❌ → ✅ via authed E2E |
| Elm state machine (Consent, AuditLog) | yes | ⚠️ program-tested, not browser → ✅ |
| 1–13 remaining app layers | no | n/a — pure E2E test issue, backends shipped and unit-covered |

Punch list:
1. WA consent toggle+save+off-copy — `e2e/tests/settings.spec.ts`.
2. Audit-log renders/empty/error + no-IP — new `e2e/tests/audit-log.spec.ts`.

Verdict: ❌ until both specs green on local then preview.

## Definition of Done
- [ ] WA-consent E2E flow added to `settings.spec.ts` and green.
- [ ] `e2e/tests/audit-log.spec.ts` added (renders, empty, error, no-IP) and green.
- [ ] Both specs green on the local stack, then preview.
- [ ] **Feature-Completeness Pre-Check is ✅ for US-8.3 and US-8.5** (driven live).
- [ ] Every behaviour has a validation path.
- [ ] Tests written and passing.
- [ ] Standards compliance verified (`just verify` passes).
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items.

## Dependencies
#189 (audit-log read page), #184 (WA consent toggle), #192 (session-mint helper) — all shipped.

## Agent Assignment
testing-coordinator.

## Progress Notes
_none yet._
