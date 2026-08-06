# Issue #191: Account Recovery — Password Reset + Resend Confirmation

## Summary
⚠️ **The build is done. What is left is one validation gap and one half-built sad path — nothing else.** This issue's original summary (both flows unbuilt or frontend-less) is obsolete; both journeys ship end-to-end and a reader can recover access.

**Shipped — password reset (US-14.4.1):** "Forgot your password?" on the login card (`frontend/src/Page/Login.elm:986-992`) switching to `ForgotPasswordMode` (`viewForgotForm`, `:757-837`); `/forgot-password` and `/reset-password/:token` are real routes (`frontend/src/Navigation/Route.elm:57`, `:59`, parsers `:111`, `:113`) wired at `frontend/src/Main.elm:1379-1394`; `Page.ResetPassword` exists; `Api.forgotPassword` / `Api.resetPassword` exist (`frontend/src/Api.elm:772`, `:815`). The emailed link resolves — the worker's `"/reset-password/#{token}"` (`apps/core/lib/stacks/workers/email_delivery_job.ex:113`) matches the parser. A completed reset also revokes every existing session (`apps/core/lib/stacks/email.ex:243`), which the original scope did not ask for. Driven by `e2e/tests/password-reset.spec.ts`.

**Shipped — resend confirmation (US-14.4.2):** `POST /api/auth/resend-confirmation` in the `:auth` bucket (`apps/core/lib/core_web/router.ex:167`) → `AuthController.resend_confirmation/2` (`apps/core/lib/stacks_web/controllers/auth_controller.ex:237`), answering an invariant literal 200. Context is `Email.send_confirmation_resend/1` (`email.ex:109`) — **note the shipped name is not the `resend_confirmation/1` named in Phase 2 below** — which re-signs a fresh token, no-ops for unknown/already-confirmed accounts, and is additionally capped by `Accounts.confirmation_resendable?/1` so an anonymous caller cannot renew a stranger's abandoned signup indefinitely (`email.ex:169-183`). Frontend: `ResendConfirmationMode` + `viewResendForm` (`Login.elm:673-715`), `Api.resendConfirmation` (`Api.elm:795-805`), reachable from the pending card and from a dead confirmation link (`Arrival.ConfirmationExpired`).

### Real residue

1. **No Playwright E2E for the resend-confirmation journey.** `grep -rl resend e2e/tests/` returns nothing. Resend has Elixir controller tests (`apps/core/test/stacks_web/auth_controller_test.exs`) and Elm tests (`frontend/tests/Page/ResendConfirmationTest.elm`), but the register → resend → confirm journey has never been driven in a browser against a real stack — while its sibling has `e2e/tests/password-reset.spec.ts`. The DoD below requires E2E for **both**, so this is the item that keeps this issue open.
2. **The reset page's two 400 sad paths are collapsed into one, with no way back.** Phase 1 item 4 asks for "an expired or invalid token" to be handled distinctly. The backend does return distinct bodies — `{"error": "token_expired"}` and `{"error": "invalid_token"}` (`auth_controller.ex:257-265`) — but `Api.resetPassword` uses `Http.expectWhatever`, so the body is discarded, and `frontend/src/Page/ResetPassword.elm:283-285` matches `Http.BadStatus 400` once and shows "This reset link is invalid or has expired. Request a new one." with **no link to `/forgot-password`**. The reader is told to request a new link and left to find the route themselves.
3. **The embedded Test Audit (below) is still ungenerated**, and the DoD checkboxes have never been ticked against the shipped code.

Out of scope, worth a follow-up issue rather than reopening this one: a completed reset writes **no audit entry**, so it does not appear on the US-8.5 audit page — which is where a victim would otherwise notice a reset they did not request.

## User Stories
- [US-14.4.1 — Password Reset](../docs/user_stories/US-14.4.1-password-reset.md)
- [US-14.4.2 — Resend Confirmation Email](../docs/user_stories/US-14.4.2-resend-confirmation.md)

## Goal
A locked-out user recovers access without support: (a) requests a password-reset link, follows it to a working reset page, sets a new password, and signs in; (b) an unconfirmed user re-triggers their confirmation email and confirms. Both journeys are built end-to-end and driven live, with no email-enumeration leak and proper rate limiting.

## Scope Check
- Touch more than 3 controllers? No — `AuthController` (+ Elm frontend).
- Add more than 2 new endpoints? No — **one** new endpoint (`POST /auth/resend-confirmation`); password reset adds none (backend exists).
- Exceed ~300 lines of production code? Possibly (two flows). These are **related** (account recovery, same Login-page surface, same email infra), so combined here. **If planning shows >300 LOC, split into 191a (password reset) / 191b (resend confirmation).**
- Combine unrelated concerns? No — both are account recovery.

## Wiring
- [x] This issue includes router + UI wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!-- Re-verified against the tree 2026-08-06. The 2026-07 pre-fill this replaces was written before either flow shipped. -->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-14.4.1 — Password Reset | **Built end-to-end.** Login-card link `Login.elm:986-992` → `ForgotPasswordMode` / `viewForgotForm` `:757-837` → `Api.forgotPassword` `Api.elm:772` → `router.ex:160` → `AuthController.forgot_password/2` `auth_controller.ex:197` → `Email.send_password_reset/1` `email.ex:58` → `EmailDeliveryJob` `email_delivery_job.ex:111-119` builds `/reset-password/{token}` `:113` → `Route.elm:113` parses it → `Page.ResetPassword` (`Main.elm:1393`) → `Api.resetPassword` `Api.elm:815` → `router.ex:161` → `auth_controller.ex:252` → `Email.reset_password/2` `email.ex:123` → sessions revoked `email.ex:243` → `/login` via `Main.resetPasswordDestination` `Main.elm:928` | ✅ driven — `e2e/tests/password-reset.spec.ts` walks forgot → real email (`GET /api/test/sent-emails`, `router.ex:426`) → link → new password → sign in | 🟡 partial | **Residue #2 only**: the two 400 bodies collapse into one message with no path back to `/forgot-password` (`ResetPassword.elm:283-285`; `Api.resetPassword` uses `Http.expectWhatever`, so the `"error"` field is discarded before the page could branch on it) |
| US-14.4.2 — Resend Confirmation Email | **Built end-to-end.** Pending card / `ConfirmationExpired` arrival → `ResendConfirmationMode` / `viewResendForm` `Login.elm:673-715` → `ResendRequested` `:448` → `Api.resendConfirmation` `Api.elm:795` → `router.ex:167` → `AuthController.resend_confirmation/2` `auth_controller.ex:237` (invariant literal 200) → `Email.send_confirmation_resend/1` `email.ex:109` → `do_send_confirmation_resend/1` `:169-183` (nil and already-confirmed no-op; `Accounts.confirmation_resendable?/1` caps renewal so an anonymous caller cannot revive a stranger's abandoned signup forever) → `issue_confirmation_link/1` `:185-210` re-signs a **fresh** token and writes + enqueues atomically → `GET /auth/confirm/:token` | ❌ **never driven in a browser** — `grep -rl resend e2e/tests/` is empty. Covered only by `apps/core/test/stacks_web/auth_controller_test.exs` and `frontend/tests/Page/ResendConfirmationTest.elm` | 🟡 partial | **Residue #1**: write the Playwright register → resend → confirm journey, reusing the `sent-emails` helper pattern from `password-reset.spec.ts` |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

⚠️ Both rows are 🟡, for different reasons: US-14.4.1 is built **and** driven but one sad path is half-done; US-14.4.2 is built and unit-tested but has **never been driven**. A row that is green in unit tests and absent from E2E is exactly the shape this project's Completion Bar refuses to read as done, which is why neither is ✅.

## Technical Requirements

> Requirement text kept as the spec; status appended per item.

### Phase 1 — Password Reset frontend (US-14.4.1) — **DONE except item 4's token sad path**
1. **"Forgot password?" link** on `Page/Login.elm` (login mode) → navigates to a request-reset view. ✅ `Login.elm:986-992`. Shipped as an in-card **mode switch** rather than a navigation (`ForgotPasswordMode`), with `/forgot-password` as a deep link into the same mode (`Main.elm:1385`) — same scene, same card.
2. **Request-reset view** — email field → `POST /api/auth/forgot-password` via new `Api.forgotPassword`; generic confirmation regardless of outcome. ✅ `viewForgotForm` `Login.elm:757-837`, `Api.forgotPassword` `Api.elm:772`. Non-enumeration is structural: the client decodes the response as `()`, so there is no richer value to branch on. `isForgotDisabled` also locks the button after a `Success`, because a 200-for-everything endpoint cannot refuse a duplicate itself.
3. **New Elm route + reset view** — `Route.ResetPassword token` parsing `/reset-password/:token`; new-password + confirm; submit → `POST /api/auth/reset-password`; on success → `/login` with a "password updated, sign in" state. ✅ `Route.elm:59`/`:113`, `Page.ResetPassword`, `Api.resetPassword` `Api.elm:815`, redirect via `AdvanceToLogin` → `Main.resetPasswordDestination` `Main.elm:928` after a 2s readable confirmation.
4. **Sad paths**: expired or invalid token; weak or mismatched password; 429; and the emailed `reset_url` resolving. 🟡 **Partly done.** Weak/mismatch ✅ (`ResetPassword.elm:78-87`, plus a double-submit guard at `:110-118` and `clearStaleError` at `:180-187`). Emailed link resolving ✅ (driven in `e2e/tests/password-reset.spec.ts`). **Expired-vs-invalid ❌** — one message for both 400s and no link back to `/forgot-password` (`:283-285`); `Api.resetPassword`'s `Http.expectWhatever` throws the `"error"` field away first, so this is a two-line change in the client as well as the page. 429 lands in the generic catch-all.

### Phase 2 — Resend Confirmation (US-14.4.2) — **DONE; E2E outstanding**
1. **New endpoint** `POST /api/auth/resend-confirmation` under the existing `:auth` bucket, returning an invariant generic 200. ✅ `router.ex:167`, `auth_controller.ex:237-243` — the body is a literal, and the limiter is consumed per-IP in the plug *before* the action, so it cannot become the oracle the body refuses to be.
2. **New context fn** re-signing a fresh token, no-op for unknown/already-confirmed, atomic write + enqueue. ✅ — **shipped as `Email.send_confirmation_resend/1`** (`email.ex:109`), not the `resend_confirmation/1` named here. `issue_confirmation_link/1` (`:185-210`) rate-limits before any write, then writes the token and enqueues in one transaction, so a failed enqueue never leaves a token no email will carry. Adds a cap this issue did not ask for: `Accounts.confirmation_resendable?/1` refuses renewal past the account's absolute lifetime, so an anonymous caller cannot keep a stranger's abandoned signup alive indefinitely.
3. **Frontend triggers** on the pending card and the unconfirmed-login state, with a "sent" confirmation and cooldown. ✅ `viewResendForm` `Login.elm:673-715`, `Api.resendConfirmation` `Api.elm:795`; `ResendRequested`/`GotResendResponse` `Login.elm:197-198`. The cooldown is `isResendDisabled` (`:286-290`) — empty address, in-flight, or already-succeeded — and `ModeSwitched` clears `resendState` so a spent acknowledgement is not carried across a deliberate mode change (`:415-421`).
4. **NOT DONE — Playwright journey.** No `resend` spec exists in `e2e/tests/`. This is the one build item still open.

## Reviewer Context
- **No email enumeration** anywhere in this issue: forgot-password and resend-confirmation return the same response for existing vs unknown accounts. `AuthController.forgot_password/2` is the reference pattern (always 200; the `nil` clause of `do_send_password_reset/1` short-circuits, `email.ex:141`). Preserve this when touching residue #2 — decoding the reset endpoint's `"error"` body is safe (that endpoint answers about a *token*, not an address), but do not extend the same treatment to forgot-password.
- The emailed `reset_url` (`email_delivery_job.ex:113`) and the SPA parser (`Route.elm:113`) agree today, and nothing but `e2e/tests/password-reset.spec.ts` holds them together. A reviewer changing either string should expect that spec to be the only thing that fails.
- Password rules live in `Types.PasswordRule` (`PasswordRule.isLongEnough`, `.tooShort`, `.requirementHint`) and are shared by the reset page — the register form's `validatePasswordConfirm` was **not** reused, and the shared rule module is the better seam. Keep new work on `PasswordRule`.
- `RequireConfirmedEmail` returns 403 on login for unconfirmed users; the resend trigger on that state is the primary recovery entry point, reached as `Arrival.ConfirmationExpired` (`Login.elm:121`) → `ResendConfirmationMode`.
- Guardian/session conventions per `docs/agents/standards/security.md`.

## Test Audit
<!-- Still ungenerated. Both flows are now built, so the precondition is met — run the `test-audit` skill. -->

_Not yet generated (residue #3). Both flows are built, so this is now unblocked. What already exists, to audit against rather than duplicate:_
- _Elixir: `describe "POST /api/auth/forgot-password"` / `"POST /api/auth/reset-password"` (`apps/core/test/stacks_web/auth_controller_test.exs:1001`, `:1181`) and resend coverage in the same file._
- _Elm: `frontend/tests/Page/ForgotPasswordNoticeTest.elm`, `frontend/tests/Page/ResendConfirmationTest.elm`, `frontend/tests/LoginTest.elm`, `frontend/tests/ArrivalTest.elm`._
- _E2E: `e2e/tests/password-reset.spec.ts` (forgot→email→reset→sign-in). **No register→resend→confirm spec** — residue #1._
- _Note the spec skips cleanly when `GET /api/test/sent-emails` is absent (`router.ex:426`, `STACKS_E2E_TEST_HELPERS`-gated). A skip is not a pass: the audit must confirm the helper is on for the target stack, or the E2E cell is not green._

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
- 2026-08-06 (docs pass, no code change): re-verified against the tree. **Both flows now ship end-to-end** — the 2026-07-13 note above is history, not current state. Summary, pre-check table, Technical Requirements statuses, Reviewer Context and Test Audit rewritten to the shipped reality with citations. Three items remain: (1) no Playwright register→resend→confirm journey; (2) the reset page collapses `token_expired`/`invalid_token` into one message and offers no path back to `/forgot-password`, because `Api.resetPassword` discards the body via `Http.expectWhatever`; (3) the embedded test audit is ungenerated. Also noted for a separate follow-up: a completed reset writes no audit entry, so it never appears on the US-8.5 audit page — which is where a victim would notice a reset they did not request. Companion story file `docs/user_stories/US-14.4.1-password-reset.md` refreshed in the same pass (its "Frontend + link wiring — NOT BUILT" block was flatly false).
