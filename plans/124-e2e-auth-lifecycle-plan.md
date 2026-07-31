# Plan: E2E Test Suite — Authentication Lifecycle
**Issue**: #124
**Created**: 2026-07-08
**Status**: Approved

## Context
Green the embedded auth-lifecycle test audit (13 layers × US-14.1.1–14.3.3) and fix the four confirmed register/login frontend bugs it surfaced. Auth is the foundation every other E2E suite rides on, so this is the first issue of the test-hardening sprint. Security-flagged throughout.

## Research Summary
The issue's **embedded Test Audit** is the research (verified citations, spot-checked). Baseline: strong backend coverage (Layers 1–9), with the gap surface concentrated in Layer 10 (Elm) and a handful of backend sad-paths. Confirmed code state:
- `Guardian.revoke/1` is a **no-op** — no `guardian_db` dep, no `on_revoke` callback. Logout does not invalidate the token server-side today. → Option A2 fixes this.
- Bugs 1–4 confirmed in `Page/Login.elm` (no `passwordConfirm`, wrong decoder on register, no `RegistrationPending`, no 403 message branch).
- Bug 5: preview email delivery depends on `EMAIL_PROVIDER=resend` + `RESEND_API_KEY` secrets.

## Approach Options (resolved by human)
- **A2 (chosen):** Real server-side token invalidation — add a token deny-list (guardian_db or ETS+Postgres, specialist's choice per standards) so logout truly revokes. Adds a migration → triggers the Fresh Database gate.
- **B (chosen, modified):** E2E confirmation uses the deterministic DB-token path for local/CI, **plus a flag** (`EMAIL_PROVIDER=resend` + `RESEND_API_KEY` on the PR preview) to exercise **real Resend** delivery before merge — we validate real email against the real provider in the PR.
- **C (chosen):** US-14.3.2 (global 401 interceptor + refresh-token) is a **new issue (#173)** with its own embedded baseline audit + green-audit DoD, implemented **on this branch as Phase 4**, last, before opening the PR.

## Phases

### Phase 1: Backend auth hardening + server-side logout revocation
**Objective**: Close backend sad-path gaps (punch #1–7) and implement A2 (real token revocation on logout).
**Agent(s)**: security-agent (lead) + database-agent (deny-list migration)
**Steps**:
1. A2: add a token deny-list (recommend `guardian_db`: `guardian_tokens` table + `Guardian.DB` hooks; else ETS+Postgres), wire `AuthController.logout` to revoke, and make the AuthPipeline reject revoked tokens.
2. punch #1: login 422 (missing fields) + 503 `service_busy` + `Retry-After: 5` (ArgonPool exhausted).
3. punch #2: end-to-end expired-JWT → 401 on `GET /api/auth/me` (drive Guardian TTL).
4. punch #3: new `RequireConfirmedEmail` plug test (authed + `email_confirmed=false` → 403 on a protected route).
5. punch #4: after `DELETE /api/auth/logout`, same JWT rejected (401) on `/api/auth/me` — now a real assertion thanks to A2.
6. punch #5: negative-emission (no `user.registered` in `event_log` on Multi rollback).
7. punch #6: assert `AuthController.login/2` writes the `user.login` audit row (hashed IP).
8. punch #7: `EmailDeliveryJob` per-user (10/hr) + global (100/hr) rate-limit tests; assert `args.params.token`.
**Test Command**: `mix test` (apps/core)
**DoD Items**: punch #1–7 resolved (their audit cells → ✅); A2 revocation verified.

### Phase 2: Frontend bug fixes + Elm tests
**Objective**: Fix Bugs 1–4 and close the Layer-10 Elm gaps (punch #8–13, 15–16).
**Agent(s)**: elm-agent
**Steps**:
1. Bug 1: `passwordConfirm` field + `validatePasswordConfirm` + `isSubmitDisabled` requires match.
2. Bug 2: `Api.register` uses `registrationResponseDecoder`; introduce `GotRegisterResponse`.
3. Bug 3: `RegistrationPending String` mode + "check your inbox" card + "Back to Sign In"; no JWT/no door/no nav.
4. Bug 4: `errorMessage` `Http.BadStatus 403` → confirm-email message; add 423/503 messages.
5. Tests: register happy/sad (#8–9), onboarding Main wiring (#10), login 403 (#11), nav auth-state (#12–13), UserMenu logout + Escape/click-outside (#15–16).
**Test Command**: `npx elm-test` (frontend)
**DoD Items**: Bugs 1–4 fixed; punch #8–13, 15–16 audit cells → ✅.

### Phase 3: E2E specs + email strategy (Bug 5)
**Objective**: Playwright E2E for the auth journeys + the real/deterministic email strategy.
**Agent(s)**: testing-coordinator (E2E) + platform-agent (preview secrets/flag)
**Steps**:
1. E2E specs: registration→pending, confirm-email success/error pages, unconfirmed-login message, owner-only admin dropdown, logout→redirect + protected-page redirect.
2. **Onboarding E2E (punch #10 E2E leg — added after DoD gap review):** 3-step overlay (Welcome→Upload→Complete) displays for a first-time authed user with no placements, skip link dismisses it, progress dots track the step. This is the only way to exercise the Main.elm onboarding wiring (opaque Nav.Key blocks unit testing); without it the US-14.1.2 L10-happy audit cell stays ⚠️.
3. Deterministic confirmation-token retrieval for local/CI (DB read / seed pre-confirmed user); no real-email dependency in CI.
4. B-flag: wire `EMAIL_PROVIDER=resend` + `RESEND_API_KEY` on the PR preview so the real Resend path is exercised before merge; document the toggle.
**Test Command**: `mcp__project-tools__run_e2e_gate(124)`
**DoD Items**: E2E legs of #8–16 (incl. onboarding #10); Bug 5 resolved (real-email validated in PR + deterministic CI path); `TEST_TARGET=local` green.

### Audit re-baseline + gap plan (immediately after `TEST_TARGET=local` passes in Phase 3)
1. **Regenerate #124's embedded audit against the shipped state** — re-verify every cell by grep/Read of the real suites (not by assuming the phases closed it). This is a discovery step: it surfaces anything Phases 1–3 missed, weakened, or only partially covered.
2. **Identify residual `⚠️`/`❌` cells** from the regenerated audit (excluding punch #14 → `n/a (see #173)`).
3. **Produce a gap-remediation plan** for those cells: for each, decide land-now (in-scope test/fix), reclassify-to-`n/a`-with-rationale, or spin-out-as-new-issue (scope-lock). Present this plan to the human before executing.
4. Only once the remediation plan is executed does the audit reach GREEN (Bug ❌ → ✅, ⚠️ → ✅, #14 → `n/a (#173)`), satisfying the audit-green DoD item.

### Phase 3.5: PE-gate remediation (human-directed scope fold-in, 2026-07-09)
The Principal Engineer gate (GREEN, no P0s) surfaced P1–P3 findings; the human chose to address them **within #124** rather than spin out. Re-triggers 2A → 2A-iv → 2B → 2C → 2F on the delta.
- **Code (security-agent):** rate-limit `GET /api/test/confirmation-token` AND scope it to e2e test-domain emails only, so the preview helper can never leak a real user's confirmation token or serve as an open enumeration oracle (P2 preview-surface). Test-first.
- **Docs (general/docs):** (a) reconcile `docs/technical-architecture.md` token-lifetime row → **8h access, no refresh, access-token DB-stored/revocable**, and add the stateful-JWT blast-radius note (per-request DB verify; login depends on token INSERT; Neon-outage coupling); (b) new ADR `docs/decisions/016-guardian-db-token-revocation.md` (why guardian_db over stateless/ETS; statefulness tradeoff; 8h TTL + daily sweeper; access-only scoping); (c) deploy runbook note: deploy force-logs-out all live sessions + migration/code rollback lockstep; (d) `docs/capacity-model.md` note on per-request guardian_tokens verify.
- **Deferred, unchanged (human call):** #173 (401 interceptor/refresh) = Phase 4; #174 (jwt-at-rest) = Phase 5; #175 (preview warmup). The 8h-hard-expiry UX gap is documented as known-until-#173. 8h is canonical.

### Final gate (after the audit is green + PE remediation, before Phase 4/5 and PR)
- Run `just verify` on the full integrated tree — **dialyzer not yet run locally** (new guardian_db dep + Oban worker); this is the outstanding lint/type gate.
- Confirm "no flaky tests" across repeated E2E runs.

### Phase 4: US-14.3.2 — global 401 interceptor + refresh (Issue #173, on this branch, LAST)
**Objective**: Implement the carved-out session-expiry handling and green #173's own embedded audit.
**Agent(s)**: elm-agent (+ elixir-agent if refresh endpoint is included)
**Steps**:
1. Global `Http.BadStatus 401` interceptor in Main.elm → `auth = Nothing` + `clearAuth ()` + redirect `/login`.
2. (Stretch) `POST /api/auth/refresh` + silent renewal.
3. Green #173's embedded audit; reclassify #124's punch-#14 cell to `n/a` linking #173.
**DoD Items**: #173 audit green; #124 US-14.3.2 L10-sad cell → `n/a (see #173)`.

### Parallel Execution
**Independent phases**: 1 and 2 (backend tests vs frontend code — no data dependency).
**Merge order**: Phase 1 and Phase 2 worktrees merge into `feat/124-e2e-auth` in either order; Phase 3 after both; Phase 4 last.

## Open Questions
- A2 mechanism: `guardian_db` vs custom deny-list — specialist chooses per `docs/agents/standards/`; must add a migration and a passing revoke-then-reject test.

## Integration Handoffs
- Phase 2 → Phase 3: the `registrationResponseDecoder` shape and `RegistrationPending` UI states are what the E2E specs assert against.
- Phase 1 → Phase 3: A2 revocation is what the logout E2E (protected-page-redirect-after-logout) proves end-to-end.
- Phase 4 depends on Phase 2's Main.elm auth wiring being in place.

## Final DoD reconciliation
Regenerate the embedded #124 audit as the last step: 4 Bug ❌ → ✅, ⚠️ → ✅, punch-#14 cell → `n/a (#173)`. Green audit satisfies the DoD.
