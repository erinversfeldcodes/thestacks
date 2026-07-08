# Issue #173: Session Expiry — global 401 interceptor + token refresh

## Summary
Implement client-side session-expiry handling (US-14.3.2): a global `Http.BadStatus 401` interceptor in `Main.elm` that clears auth and redirects to `/login`, plus (stretch) a `POST /api/auth/refresh` silent-renewal flow. Carved out of #124 (auth-lifecycle test hardening) per scope-lock — it is unimplemented **feature** work, not test debt.

## User Stories
US-14.3.2 (Session Expiry and Token Refresh)

## Goal
When a user's JWT expires (or is revoked server-side — see #124 A2), the next authenticated API call returns 401; the SPA detects this globally, drops the stale auth (`model.auth = Nothing`, `clearAuth ()` port), and redirects to `/login` with a "your session expired" notice — instead of leaving the user on a broken authenticated view. No route should silently fail on an expired token.

## Scope Check
- Touches `Main.elm` (global HTTP error handling) + optionally `AuthController`/`Api.elm` for refresh. ≤ 2 endpoints, < 300 LOC.
- Single concern (session expiry). No split needed.

## Wiring
- [x] This issue includes router/UI wiring and is user-facing when complete.
- [ ] This issue is implementation only.

## Technical Requirements

### 1. Global 401 interceptor (required)
- Central handling in `Main.elm` so **every** `Http.BadStatus 401` from an authenticated request routes through one path (not per-page).
- On 401: `model.auth = Nothing`, call `clearAuth ()` port (remove localStorage), `Nav.pushUrl model.key "/login"`.
- Surface a "Your session has expired — please sign in again." notice on the login page (distinct from the invalid-credentials message).
- Must NOT fire the 401→redirect for the login/register endpoints themselves (those 401/403s are handled locally by `Page.Login`).

### 2. Token refresh (stretch)
- `POST /api/auth/refresh` issues a fresh JWT from a valid (non-expired, non-revoked) token/refresh-token.
- Silent renewal before expiry; on refresh failure, fall through to the 401 interceptor.
- Coordinate with #124 A2 (revocation deny-list): a revoked token must not refresh.

## Reviewer Context
- Depends on #124 Phase 2's `Main.elm` auth wiring (`decodeFlags`, `saveAuth`/`clearAuth` ports) being in place — this issue is implemented on the `feat/124-e2e-auth` branch as #124's Phase 4.
- Proto decoders are lenient (return default structs) — a real 401 must be detected by HTTP status, not decode failure.
- `RemoteData` is used for API calls; the interceptor sits above per-page `RemoteData` handling.

## Test Audit

_Baseline test-coverage map for this issue (13 layers × US-14.3.2, happy/sad columns), generated 2026-07-08. Pre-implementation baseline — the feature does not exist yet, so most cells are `❌ (feature not implemented)` or `n/a`. Regenerate as the feature + tests land; the issue is Done when this audit is green (see Definition of Done)._

### Framework-layer summary

| Layer | US-14.3.2 |
|-------|-----------|
| Elixir (refresh endpoint) | ❌ stretch |
| Elm unit | ❌ |
| Elm program | ❌ |
| E2E | ❌ |
| dbt | n/a |

### Coverage tally (baseline)

| Status | Count |
|--------|-------|
| ✅ STRONG | 0 |
| ⚠️ shallow | 0 |
| ❌ missing | 6 |
| n/a | 20 |

### Full audit tables (13 layers × US-14.3.2, happy/sad)

| Layer | Happy | Verdict | Sad | Verdict |
|-------|-------|---------|-----|---------|
| 1 API calls | `POST /api/auth/refresh` returns fresh JWT (stretch) | ❌ | refresh with expired/revoked token → 401 | ❌ |
| 2 Auth guards | interceptor bypasses login/register endpoints | ❌ | expired token on protected route → 401 flows to interceptor | ❌ |
| 3 DB | n/a — no DB write (refresh is stateless unless refresh-token store added) | n/a | n/a | n/a |
| 4 Events | n/a — no events | n/a | n/a | n/a |
| 5 Oban | n/a | n/a | n/a | n/a |
| 6 External | n/a | n/a | n/a | n/a |
| 7 Storage | `clearAuth ()` removes localStorage on 401 | ❌ | n/a | n/a |
| 8 Cache | n/a | n/a | n/a | n/a |
| 9 dbt | n/a | n/a | n/a | n/a |
| 10 Elm state machine | global 401 → `auth = Nothing` + `clearAuth` + redirect `/login` + expiry notice | ❌ | 401 from login/register does NOT trigger global redirect | ❌ |
| 11 Op metrics | n/a — covered by SLO gate | n/a | n/a | n/a |
| 12 Perf/usability | n/a — covered by SLO gate | n/a | n/a | n/a |
| 13 Cost | n/a | n/a | n/a | n/a |

### Punch list (baseline — 0 items resolved)

| # | Cell | What's needed | Where it belongs |
|---|------|---------------|------------------|
| 1 | L10 happy | Elm test: a simulated `Http.BadStatus 401` on an authed request sets `auth = Nothing`, calls `clearAuth`, and pushes `/login`. | `frontend/tests/` Main program test |
| 2 | L10 sad | Elm test: a 401 from the login/register endpoints does NOT trigger the global redirect. | `frontend/tests/` Main program test |
| 3 | L2 happy/sad | E2E: expired/revoked token → next action redirects to `/login` with the expiry notice. | `e2e/tests/auth.spec.ts` |
| 4 | L1 (stretch) | Elixir: `POST /api/auth/refresh` happy (fresh JWT) + sad (expired/revoked → 401), coordinated with #124 A2 revocation. | `apps/core/test/stacks_web/auth_controller_test.exs` |
| 5 | L7 | Elm test: `clearAuth` port invoked on 401 (localStorage cleared). | `frontend/tests/` Main program test |

### Verdict
Baseline — feature unimplemented. Green when the 401 interceptor (required) ships with unit + program + E2E coverage; the refresh endpoint (stretch) may be deferred to a follow-up if scoped out, in which case its cells reclassify to `n/a (deferred — see follow-up)` with a link.

## Definition of Done
- [ ] Global `Http.BadStatus 401` interceptor in `Main.elm`: clears auth, calls `clearAuth`, redirects to `/login`, shows expiry notice
- [ ] Login/register endpoint 401/403s are excluded from the global redirect
- [ ] Elm unit + program tests for the interceptor (happy + sad)
- [ ] E2E: expired/revoked token → redirect to `/login`
- [ ] (Stretch) `POST /api/auth/refresh` with tests, or explicitly deferred with the audit cells reclassified to `n/a` + follow-up link
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × US cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️`. Regenerate the embedded audit tables + tally as the final step.

## Dependencies
- #124 (auth-lifecycle) — implemented on its branch (`feat/124-e2e-auth`) as Phase 4; depends on #124 Phase 2's `Main.elm` auth wiring.
- #124 A2 (token revocation deny-list) — a revoked token must not refresh.

## Agent Assignment
elm-agent (interceptor); elixir-agent (refresh endpoint, if in scope).

## Progress Notes
- 2026-07-08: Carved out of #124 punch-#14 per scope-lock. Baseline audit is all-❌ (feature not implemented). To be built on the #124 branch as Phase 4, last before the PR.
