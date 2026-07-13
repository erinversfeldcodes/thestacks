# Issue #184: Account Recovery — Password Reset + Resend Confirmation

## Summary
Close the two account-recovery gaps that no issue currently owns: **password reset** (US-14.4.1 — backend built but no frontend, and the reset email links to a route that doesn't exist) and **resend confirmation email** (US-14.4.2 — nothing built; the register→confirm flow dead-ends when the 48h token expires). Both are Phase-1-essential: a user who forgets their password or loses the confirmation email is currently locked out with no recovery path. This issue builds the missing pieces and validates both flows end-to-end.

## User Stories
- [US-14.4.1 — Password Reset](../docs/user_stories/US-14.4.1-password-reset.md)
- [US-14.4.2 — Resend Confirmation Email](../docs/user_stories/US-14.4.2-resend-confirmation.md)

## Goal
A locked-out user recovers access without support: (a) requests a password-reset link, follows it to a working reset page, sets a new password, and signs in; (b) an unconfirmed user re-triggers their confirmation email and confirms. Both journeys are built end-to-end and driven live, with no email-enumeration leak and proper rate limiting.

## Scope Check
- Touch more than 3 controllers? No — `AuthController` (+ Elm frontend).
- Add more than 2 new endpoints? No — **one** new endpoint (`POST /auth/resend-confirmation`); password reset adds none (backend exists).
- Exceed ~300 lines of production code? Possibly (two flows). These are **related** (account recovery, same Login-page surface, same email infra), so combined here. **If planning shows >300 LOC, split into 184a (password reset) / 184b (resend confirmation).**
- Combine unrelated concerns? No — both are account recovery.

## Wiring
- [x] This issue includes router + UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Pre-filled from the US-14.4.1 / US-14.4.2 investigation (2026-07). Re-verify at pick-up. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-14.4.1 — Password Reset | Backend built + 6 tests: `POST /auth/forgot-password` + `/reset-password`, `AuthController.forgot_password/2` + `reset_password/2`, `Email.send_password_reset/1` + `reset_password/2` (`Phoenix.Token` salt `password_reset`, 24h + persisted `password_reset_token`), `:password_reset` template/worker, `op.users.password_reset_token`. **Frontend: NONE** (no `Route`/page/`Api` fns, no "Forgot password?" link). **Link BROKEN**: `reset_url` → `/reset-password/{token}` SPA path has no route → dead-ends at NotFound | ❌ not driven (unreachable by a user) | 🟡 partial | **build in-scope**: frontend pages + login link + `Api` client + a real `/reset-password/:token` route |
| US-14.4.2 — Resend Confirmation Email | **NOTHING built** (no route/context/frontend — `grep resend` is empty). Reuses existing: confirmation token (`Phoenix.Token` salt `email_confirm`, 48h), `EmailDeliveryJob` `registration_confirmation`, per-user 10/hr + global 100/hr caps, `GET /auth/confirm/:token`; frontend `RegistrationPending`/`viewPendingCard` + 403 message exist | ❌ not driven (feature absent) | ❌ missing | **build in-scope**: new endpoint + context fn + frontend triggers |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### Phase 1 — Password Reset frontend (US-14.4.1); backend exists
1. **"Forgot password?" link** on `Page/Login.elm` (login mode) → navigates to a request-reset view.
2. **Request-reset view** — email field → `POST /api/auth/forgot-password` via new `Api.forgotPassword`. Show a generic "if that account exists, we've sent a link" confirmation regardless of outcome (the backend already returns 200 always — do not leak account existence).
3. **New Elm route + reset view** — add `Route.ResetPassword token` parsing **`/reset-password/:token`** (the exact path the email's `reset_url` already builds). New-password + confirm fields reusing the register form's password rules; submit → `POST /api/auth/reset-password` via new `Api.resetPassword`. On success → redirect to `/login` with a "password updated, sign in" state.
4. **Sad paths**: an expired or invalid token; a new password that is too weak or does not match its confirmation; a rate-limited request (429). Confirm the reset email's `reset_url` now resolves to the new route (it currently dead-ends).

### Phase 2 — Resend Confirmation (US-14.4.2); build backend + frontend
1. **New endpoint** `POST /api/auth/resend-confirmation` under `:rate_limit_auth` (same enumeration/abuse profile as forgot-password; no new bucket). Returns an **invariant generic 200/202** ("if that account exists and is unconfirmed, we've re-sent it") — never leaks existence or confirmation state.
2. **New context fn** `Stacks.Email.resend_confirmation/1` — **re-signs a fresh token** (do not merely re-deliver the persisted one; the 48h window must reset), no-ops for unknown or already-confirmed accounts, enqueues via the existing `EmailDeliveryJob` `registration_confirmation` + existing per-user/global caps, in one transaction.
3. **Frontend triggers** — a "Didn't get the email? Resend" action on the `RegistrationPending` card AND on the 403-unconfirmed login error state. New `Api.resendConfirmation` + `ResendConfirmationClicked`/`GotResendResponse` Msgs, with a "sent" confirmation + cooldown and rate-limited feedback.

## Reviewer Context
- **No email enumeration** anywhere in this issue: forgot-password and resend-confirmation must return the same response for existing vs unknown accounts. `AuthController.forgot_password/2` is the reference pattern (always 200; `send_password_reset/1` short-circuits on `nil`).
- The reset email is already built and links to `/reset-password/{token}` — Phase 1 must make that exact route real, or the link stays broken.
- Password rules must match the register form (min 8, confirm-match) — reuse `validatePasswordConfirm` from `Page/Login.elm`.
- `RequireConfirmedEmail` returns 403 on login for unconfirmed users; the resend trigger on that 403 state is the primary recovery entry point.
- Guardian/session conventions per `docs/agents/standards/security.md`.

## Test Audit
<!-- Generate with the `test-audit` skill AFTER the Feature-Completeness Pre-Check is ✅ (both flows built). -->

_To be generated by the `test-audit` skill once both flows are built. Baseline expectation: Elixir controller tests for the resend endpoint (enumeration-safe, fresh-token, already-confirmed no-op, rate-limited) reusing the existing forgot/reset tests; Elm unit + program tests for the reset pages and resend triggers; Playwright E2E driving the full forgot→email→reset→login and register→resend→confirm journeys against a real stack (deterministic token retrieval via the existing `/api/test/confirmation-token` helper pattern)._

## Definition of Done
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for both stories** — password-reset and resend-confirmation journeys built end-to-end and observed working on a live stack.
- [ ] A user can complete forgot-password → emailed link → reset page → new password → sign in (the reset email link resolves, no longer dead-ends).
- [ ] An unconfirmed user can resend their confirmation from the pending card and the 403 login state; a fresh token is issued; already-confirmed/unknown accounts no-op with the same generic response.
- [ ] No email enumeration on forgot-password or resend; both are rate-limited.
- [ ] Every behaviour has a validation path — unit/integration + Playwright E2E against a real stack (`TEST_TARGET=deployed`).
- [ ] Tests written and passing (`mix test` via `just run`, `elm-test`, E2E)
- [ ] **Test audit (embedded above) is GREEN** — regenerate as the final step.
- [ ] `just verify` passes (via `just run`)

## Dependencies
- None hard. Password-reset backend + email infra already exist; resend reuses the confirmation email job.

## Agent Assignment
elm-agent (frontend for both flows) + security-agent (resend endpoint, enumeration/rate-limit review) + testing-coordinator (E2E).

## Progress Notes
- 2026-07-13: Cut from the Phase-1 user-story gap review. These two account-recovery stories had no E2E/build issue — auth-lifecycle (#124, now complete) never covered recovery. US-14.4.1 backend exists but is unreachable (no frontend, broken reset link); US-14.4.2 is entirely unbuilt.
