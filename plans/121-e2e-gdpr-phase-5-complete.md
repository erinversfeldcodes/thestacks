# Phase 5 Complete — Issue #121: E2E hardening (GDPR auth guards + consent success/error)

**Status**: APPROVED (testing-coordinator, 0 revision cycles)
**Agent**: testing-agent · **Reviewer**: testing-coordinator
**Type**: E2E test-only (Playwright/TypeScript)

## What landed
`e2e/tests/settings.spec.ts` — three changes:
1. Replaced the weak "save button is visible and clickable" smoke (asserted only
   `.error` count 0) with **"saving consent shows the 'Saved!' success state"** —
   toggles analytics, saves, asserts `getByRole("button",{name:"Saved!"})` visible +
   `.error` count 0 (source: `Consent.elm:110-112`).
2. New **"save failure surfaces the error message"** — `page.route("**/api/gdpr/consent",
   fulfill 500)` installed before Save, asserts the `.error` paragraph shows the exact
   copy "Could not save preferences. Please try again." (`Consent.elm:118-121`).
3. New describe **"GDPR — auth guards"** (clean `storageState`) — asserts
   `POST /api/gdpr/export`, `DELETE /api/gdpr/account`, `POST /api/gdpr/consent` each
   return **401** unauthenticated (mirrors the existing settings-401 pattern).

HTTP methods confirmed against `core_web/router.ex:239-241` (all under
`pipe_through [:api, :authenticated]`).

## Gates
- 2A-iv Reception: DoD §1/§2 — consent success + error + GDPR 401 guards; assertions non-vacuous.
- 2B-i Regression: full `settings.spec.ts` suite (21 tests) green against the live preview.
- 2B-iia Fresh-DB: n/a (no migrations).
- **2B-iii Deploy+E2E: PASSED** — deployed preview `stacks-core-pr-feat-e2e-121.fly.dev`
  (`SKIP_VISION=1`, no Modal spend), warmed healthy, ran `settings.spec.ts` →
  **21 passed (33.0s)**, incl. the 3 new tests. Command:
  `BASE_URL=<preview> E2E_SERVICES=none SKIP_VISION=1` → `npx playwright test settings.spec.ts`.
- 2C Review: testing-coordinator → **APPROVED** first pass (3 non-blocking notes; no changes).

## DoD Evidence
| DoD item (§1/§2) | Test (settings.spec.ts) | Live result | Status |
|---|---|---|---|
| GDPR endpoints 401 unauthenticated | "GDPR — auth guards" :96 | ✓ 1.2s | ✅ |
| Consent save success ("Saved!") | "saving consent shows the 'Saved!' success state" :34 | ✓ 1.4s | ✅ |
| Consent save error copy | "save failure surfaces the error message" :56 | ✓ 1.1s | ✅ |

## Reviewer non-blocking notes (no action required)
- New 401 test uses a clean `storageState` vs the existing one reusing authed state + omitting the header — both valid; new approach cleaner.
- Consent success test has no `test.skip` on 502 (unlike password tests) — correct, consent writes don't run Argon2 so the preview-OOM flake (#166) doesn't apply.
- Optional future: round-trip the persisted `consent_analytics` value (out of DoD scope).

## Preview stack
`stacks-core-pr-feat-e2e-121` left running post-gate — tear down with
`scripts/cleanup-preview.sh` when the epic no longer needs it (Phase 6 is docs-only, no E2E).
