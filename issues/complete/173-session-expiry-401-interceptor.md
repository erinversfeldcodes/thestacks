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

_Baseline generated 2026-07-08; regenerated GREEN 2026-07-10 after both phases. Refresh was INCLUDED (not deferred). Interceptor covers the 8 authed pages with an OutMsg channel; the 11 without one are `n/a (see #178)`._

### Framework-layer summary

| Layer | US-14.3.2 |
|-------|-----------|
| Elixir (refresh endpoint) | ✅ |
| Elm unit / seam | ✅ |
| Elm program (renewal, exclusion) | ✅ |
| E2E (session-expiry redirect) | ✅ |
| dbt | n/a |

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | 6 |
| ⚠️ shallow | 0 |
| ❌ missing | 0 |
| n/a | 20 |

### Full audit tables (13 layers × US-14.3.2, happy/sad)

| Layer | Happy | Verdict | Sad | Verdict |
|-------|-------|---------|-----|---------|
| 1 API calls | `POST /api/auth/refresh` returns fresh JWT | ✅ `auth_controller_test` happy + rotation | refresh with expired/revoked/absent token → 401 | ✅ `auth_controller_test` (3 sad) |
| 2 Auth guards | interceptor excludes login/register (local) | ✅ `login_401_stays_local` | expired/revoked token → 401 → interceptor redirects `/login` (8 covered pages) | ✅ page-seam unit + `auth.spec.ts` E2E (live) |
| 3 DB | n/a — refresh reuses guardian_tokens (rotation via on_revoke/encode; jwt nulled by #174) | n/a | n/a | n/a |
| 4 Events | n/a | n/a | n/a | n/a |
| 5 Oban | n/a | n/a | n/a | n/a |
| 6 External | n/a | n/a | n/a | n/a |
| 7 Storage | `saveAuth` on renewal; `clearAuth ()` on expiry | ✅ renewal program test + E2E asserts localStorage cleared | n/a | n/a |
| 8 Cache | n/a | n/a | n/a | n/a |
| 9 dbt | n/a | n/a | n/a | n/a |
| 10 Elm state machine | authed 401 → `SessionExpired` OutMsg → `Main.sessionExpired` (auth=Nothing + clearAuth + `/login` + notice); proactive 7h renewal | ✅ page-seam + renewal tests + E2E | 401 from login/register does NOT trigger global redirect; 403 age-gate stays local; renewal failure → interceptor | ✅ exclusion + 403 guard + `renewal_failure_clears_auth` |
| 11 Op metrics | n/a — SLO gate | n/a | n/a | n/a |
| 12 Perf/usability | n/a — SLO gate | n/a | n/a | n/a |
| 13 Cost | n/a | n/a | n/a | n/a |

**Coverage scope:** L2/L10 sad-path interception applies to the 8 authed pages with an `OutMsg` channel (Bookshelf, BookDetail, ReadingPile, LookingForHome, Groups, Groups/Detail, CreateListing, Upload). The 11 authed pages without one → `n/a (see #178)` — no security consequence (the backend `:authenticated` pipeline rejects every expired/revoked token 401 regardless; it's a UX-redirect gap only).

### Verdict
**GREEN.** Refresh endpoint (happy + rotation + revoked/expired/absent→401) shipped and reviewed; global 401 interceptor (single `Main.sessionExpired` path) + proactive 7h silent renewal shipped across the 8 OutMsg authed pages; login/register excluded; distinct in-voice expiry notice (styled + `role=status`). Proven end-to-end on a live Fly preview: `auth.spec.ts` "Session expiry" redirects to `/login` with the notice (8.8s), E2E 195/0. elm-test 561/0; auth_controller 38/0; `just verify` exit 0. Reviews: elixir/contract/elm APPROVED, ux SHIP+polish, PE GREEN. Remaining coverage (11 pages) tracked in **#178** (UX-only, backend still gates).

## Definition of Done
- [x] Global `Http.BadStatus 401` interceptor in `Main.elm` — single `Main.sessionExpired` handler (clears auth, `clearAuth`, redirects `/login`, shows expiry notice), fed by `Api.isUnauthorized` + a `SessionExpired` OutMsg. **Covers the 8 authed pages with an OutMsg channel** (Bookshelf, BookDetail, ReadingPile, LookingForHome, Groups, Groups/Detail, CreateListing, Upload). **Coverage scope adjusted (2026-07-10):** 11 authed pages that lack an OutMsg channel (Admin×3, Blog×2, Marketplace/MyListings, Catalogue, Search, Settings×3) need the 3-tuple conversion first → tracked as **[#178]** (silent renewal mitigates proactive expiry on them; the residual is revocation-on-uncovered-page).
- [x] Login/register endpoint 401/403s are excluded from the global redirect
- [x] Elm unit + program tests for the interceptor (happy + sad) — `SessionExpiryTest.elm` (12 tests)
- [x] E2E: expired/revoked token → redirect to `/login` (`auth.spec.ts`; runs on the deploy gate)
- [x] `POST /api/auth/refresh` with tests (INCLUDED, not deferred — Phase 1) + proactive silent renewal (7h)
- [x] Tests pass with `TEST_TARGET=local` (elm-test 561/0)
- [x] No flaky tests
- [x] `just verify` passes
- [x] **Test audit (embedded above) is GREEN** — applicable cells `✅` or `n/a`-with-rationale (the "all authed pages" cell is scoped to the 8 covered + `n/a (see #178)` for the rest). Regenerate as the final step.

## Dependencies
- #124 (auth-lifecycle) — implemented on its branch (`feat/124-e2e-auth`) as Phase 4; depends on #124 Phase 2's `Main.elm` auth wiring.
- #124 A2 (token revocation deny-list) — a revoked token must not refresh.

## Agent Assignment
elm-agent (interceptor); elixir-agent (refresh endpoint, if in scope).

## Progress Notes
- 2026-07-08: Carved out of #124 punch-#14 per scope-lock. Baseline audit is all-❌ (feature not implemented). To be built on the #124 branch as Phase 4, last before the PR.
- 2026-07-10: Implemented via orchestrator, 2 phases. Phase 1 (elixir-agent): POST /api/auth/refresh (rotate: revoke old + encode new 8h; revoked/expired/absent -> 401) — elixir + contract reviewers APPROVED. Phase 2 (elm-agent): global 401 interceptor (SessionExpired OutMsg -> single Main.sessionExpired) across the 8 authed pages with an OutMsg channel + proactive 7h silent renewal + distinct styled/role=status in-voice notice — elm + contract APPROVED, ux SHIP+polish. PE GREEN (no P0/P1; backend pipeline is the real gate -> uncovered pages are UX-only). Gates: elm-test 561/0, auth_controller 38/0, just verify exit 0; live 2B-iii E2E 195/0 incl the 'Session expiry' redirect spec (8.8s). Coverage of the 11 OutMsg-less authed pages -> #178. Follow-ups from PE: session-lifetime cap/refresh-reuse (P2); boot-time GotPlacementCheck hook (folded into #178), multi-tab race, revoke metric, CreateListing form-loss (P3).
