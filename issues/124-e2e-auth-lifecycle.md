# Issue #124: E2E Test Suite — Authentication Lifecycle

## Summary
Comprehensive E2E test coverage for registration with email confirmation (US-14.1.1), onboarding overlay (US-14.1.2), sign in (US-14.2.1), authenticated navigation state (US-14.3.1), session expiry (US-14.3.2), and logout (US-14.3.3).

## User Stories
US-14.1.1 (Register a New Account), US-14.1.2 (First-Time Onboarding Flow), US-14.2.1 (Sign In to an Existing Account), US-14.3.1 (Authenticated Navigation State), US-14.3.2 (Session Expiry and Token Refresh), US-14.3.3 (Log Out)

## Goal
Validate the complete auth lifecycle: register -> email confirmation -> login -> JWT issuance -> onboarding -> nav state -> session persistence via localStorage -> logout -> token invalidation, plus rate limiting on auth endpoints.

## Scope Check
- Does this issue touch more than 3 controllers? No (AuthController, EmailVerificationController).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all auth-related).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Registration form**: Navigate to `/login` -> click "Register" tab -> display name, email, password, and confirm password fields all shown
- **Password confirmation**: Typing mismatched confirm password shows "Passwords do not match" hint; submit remains disabled
- **Tab switching**: Switch between "Sign In" and "Register" tabs -> email and password preserved; validations reset to Pristine
- **Registration validation**: Email must contain `@` and `.`, password >= 8 chars, passwords match, display name non-empty
- **Field validation styles**: Green border (`login-card__field--valid`) or red border with hint (`login-card__field--error`)
- **Submit disabled**: "Request Entry" button disabled until all four fields validate (including matching passwords)
- **Submit spinner**: Button shows spinner during API request
- **Registration success**: After successful POST, user sees "Check your inbox!" pending state — NOT redirected to antilibrary, no door animation, no JWT stored
- **Registration pending card**: Shows the registered email address; "Back to Sign In" link resets to `LoginMode`
- **Email confirmation success page** (`/confirm-email/success`): "Email confirmed" heading, "Sign in" link to `/login`
- **Email confirmation error page** (`/confirm-email/error`): "Confirmation failed" heading, guidance text
- **Login form**: "Enter the Stacks" submit button, email and password fields
- **Login success**: Door animation plays (4000ms) -> redirect to `/antilibrary`
- **Login error messages**: "The door remains shut. Invalid credentials." on 401
- **Unconfirmed email login**: 403 response shows "Please confirm your email address before signing in. Check your inbox for the confirmation email." — NOT the generic invalid credentials message
- **Onboarding overlay**: After first login, 3-step overlay: Welcome -> Upload prompt -> Complete
- **Onboarding skip**: "Skip" link at any step dismisses overlay
- **Onboarding progress dots**: 3 dots at bottom indicate current step
- **Authenticated nav**: Display name shown in place of "Sign In", full nav items visible
- **Unauthenticated nav**: Only Catalogue, Marketplace, Sign In visible
- **User menu**: Display name click -> dropdown with "Settings" and "Sign Out"
- **Logout**: Click "Sign Out" -> redirect to `/login`, nav reverts to unauthenticated
- **Escape key**: Closes user menu dropdown and book detail overlays

### 2. Playwright Navigation & Visual Tests
- **Login card layers**: Multi-layer animation elements (layer-arrival, layer-passage, layer-bookshelf)
- **Active nav item**: `app-nav__item--active` class on current page's nav item
- **Owner-only admin dropdown**: Admin menu (Metrics, Sources, Scrapers) only for `role: "owner"`
- **Login page public**: `/login` accessible without auth
- **Post-logout protected access**: After logout, navigating to protected page shows login form

### 3. API Endpoint Tests
- `POST /api/auth/register` — 201 `{ message: "confirmation_email_sent" }`
- `POST /api/auth/register` — 422 on duplicate email with changeset errors
- `POST /api/auth/register` — first user gets `role: "owner"` via `maybe_assign_owner_role/1`
- `POST /api/auth/register` — rate limited (`:auth` bucket)
- `GET /api/auth/confirm/:token` — 302 redirect to `/confirm-email/success` on valid token
- `GET /api/auth/confirm/:token` — 302 redirect to `/confirm-email/error` on invalid/expired token
- `POST /api/auth/login` — 200 with `{ token, user: { id, email, display_name, role, ... } }`
- `POST /api/auth/login` — 401 `invalid_credentials` for wrong password
- `POST /api/auth/login` — 403 `email_unconfirmed` for unconfirmed email
- `POST /api/auth/login` — 422 `email and password are required` for missing fields
- `POST /api/auth/login` — rate limited (`:auth` bucket)
- `POST /api/auth/login` — timing attack prevention: `Argon2.no_user_verify()` for non-existent user
- `GET /api/auth/me` — 200 with user data when token valid, 401 when expired/invalid
- `DELETE /api/auth/logout` — 204 No Content, token revoked via `Guardian.revoke/1`
- RequireConfirmedEmail plug: 403 if `email_confirmed == false`

### 4. Database Assertion Tests
- `op.users` record created with Argon2-hashed password, `email_confirmed: false`, `email_confirmation_token` set
- First user: `role: "owner"`, subsequent users: `role: "user"`
- Email format validation: `~r/^[^\s]+@[^\s]+$/`
- Password length validation: min 8 characters
- Unique constraint on email
- Email confirmation: `email_confirmed` set to `true` after token verification
- Ecto.Multi registration steps: `:user` (INSERT), `:set_confirmation` (UPDATE), `:emit_event`

### 5. Event Flow Tests
- `user.registered` emitted with `{ role }` payload within Multi transaction
- `user.registered` triggers `EmailConfirmationHandler` -> `Email.send_registration_confirmation/1`
- `EmailConfirmationHandler` generates Phoenix token (`email_confirm` salt, 48h max_age)
- `user.login` audit entry (via `Audit.log/3`, not `Events.emit/1`) on successful login
- No events for onboarding (client-side only)
- No events for logout

### 6. Background Job Tests
- `EmailDeliveryJob` — queue `:notifications`, template `registration_confirmation`
- `EmailDeliveryJob` — args include `user_id` and `params.token`
- `EmailDeliveryJob` — per-user rate limit (10 emails/hour), global limit (100 emails/hour)
- Email delivered via Resend (production) or logged (dev/test)

### 7. External Service Tests
- Resend email delivery mock in test env
- Email confirmation link format: `/api/auth/confirm/:token`

### 8. Storage Tests
- N/A for auth endpoints
- localStorage persistence: `saveAuth` port stores `{ token, userId, email, displayName, role }`
- `clearAuth` port removes all auth data from localStorage
- `requestOnboardingStatus` / `saveOnboardingCompleted` ports for onboarding state

### 9. Cache Tests
- `RateLimiter` cache: `:auth` bucket keyed by IP, time-based expiry
- Rate limit check and increment on register and login endpoints

### 10. dbt Model Tests
- `stg_users` refreshed on `user.registered` event

### 11. Elm State Machine Tests
- `Page.Login` init: `email = "", password = "", passwordConfirm = "", displayName = "", mode = LoginMode, submitState = NotAsked`
- `ModeSwitched RegisterMode` -> switches to registration mode, resets all validations to Pristine
- `DisplayNameChanged`/`EmailChanged`/`PasswordChanged`/`PasswordConfirmChanged` -> update fields, run validation
- `validatePasswordConfirm password confirm`: `Pristine` if empty, `Valid` if matches password, `Invalid "Passwords do not match"` otherwise
- `isSubmitDisabled` (RegisterMode): disabled if any of email/password/passwordConfirm/displayName is Pristine or Invalid
- `FormSubmitted` (RegisterMode) -> `Api.register` (using `registrationResponseDecoder`, not `authResponseDecoder`), `submitState = Loading`
- `GotRegisterResponse (Ok ())` -> `mode = RegistrationPending email`, OutMsg `RegistrationSucceeded email`; no door animation, no JWT stored
- `GotRegisterResponse (Err err)` -> `submitState = Failure err`
- `FormSubmitted` (LoginMode) -> `Api.login`, `submitState = Loading`
- `GotAuthResponse (Ok response)` -> `submitState = Success`, `transitionState = Transitioning`, OutMsg `StartTransition`
- `GotAuthResponse (Err (Http.BadStatus 403))` -> `submitState = Failure`, view shows "Please confirm your email address before signing in."
- `GotAuthResponse (Err err)` -> `submitState = Failure err`
- Main.elm `StartTransition` -> stores `pendingAuthResponse`, calls `playLoginTransition` port
- `LoginTransitionCompleted` -> constructs Auth, calls `saveAuth` port, navigates to `/antilibrary`
- `Components.OnboardingOverlay` init: `{ step = Welcome, visible = True }`
- `NextStep`: Welcome -> UploadPrompt -> Complete
- `SkipOnboarding` -> `visible = False`, OutMsg `SkipCompleted`
- Main.elm `OnboardingStatusReceived completed` -> sets `model.onboardingCompleted`
- `viewNav` pattern match on `model.auth`: Nothing -> unauthenticated items, Just -> full nav
- `UserMenu.update`: `Toggle` opens/closes, `SignOutClicked` -> OutMsg `SignOut`
- Main.elm on `SignOut`: `auth = Nothing`, `clearAuth`, navigate to `/login`

### 12. Metrics & Telemetry Tests
- Registration success/failure rates
- Rate limiter trigger count on `:auth` bucket
- Email confirmation delivery rate and success rate
- Argon2 hash computation time (p50/p95/p99)
- Guardian token issuance count
- Login success rate, failure rate by type (401/403/422/429)
- JWT issuance count
- Logout request rate and success rate
- Token revocation success rate
- Auth state restoration rate from localStorage
- Onboarding trigger rate, step progression rate, skip rate per step

## Bugs That Must Be Fixed Before This Issue Can Pass

The following bugs were confirmed by attempting to register at `erinversfeld@gmail.com` against the deployed preview environment. All four must be fixed as part of this issue. Full technical detail is in `docs/user_stories/US-14.1.1-register.md` (Section 13) and `docs/user_stories/US-14.2.1-sign-in.md` (Section 12).

### Bug 1: No password confirmation field
`Page.Login.elm` has no `passwordConfirm` field in the `Model`, no `PasswordConfirmChanged` `Msg`, no `passwordConfirmValidation`, and no confirm password input in the view. The registration form asks for the password only once. Users who mistype their password are registered with an unusable account and receive no feedback.

**Fix**: Add `passwordConfirm : String`, `passwordConfirmValidation : FieldValidation`, `PasswordConfirmChanged String` Msg, and a Confirm Password input field to the register form. Add `validatePasswordConfirm : String -> String -> FieldValidation`. Update `isSubmitDisabled` to require `passwordConfirmValidation == Valid`.

### Bug 2: Registration navigates to antilibrary instead of showing "check your email"
`Api.register` uses `authResponseDecoder` (expects `{ token, user: {...} }` — the login response shape). The backend correctly returns `{"message": "confirmation_email_sent"}` on HTTP 201. Because the proto-generated decoder returns a default-value `AuthResponse` with `token = ""` on any JSON input, `GotAuthResponse (Ok { token = "", ... })` fires, triggering the 4000ms door animation and navigating the user to `/antilibrary` with a blank, invalid JWT.

**Fix**: Introduce a dedicated `GotRegisterResponse (Result Http.Error ())` Msg and a registration-specific decoder (`registrationResponseDecoder`) that only checks for the `"message"` key. Change `Api.register` to use this decoder and this Msg.

### Bug 3: No RegistrationPending state
`Page.Login.elm` has no `RegistrationPending` mode. After a successful registration API call, the user should see a "check your inbox" message — not be navigated anywhere. Caused by Bug 2 (blank JWT used as a real login). Once Bug 2 is fixed, this state must be implemented.

**Fix**: Add `RegistrationPending String` as a `Mode` variant (carrying the registered email address for display). When `GotRegisterResponse (Ok ())` fires, switch mode to `RegistrationPending model.email`. Render a confirmation card: "Check your inbox! A confirmation email has been sent to [email]. Click the link in the email to confirm your address and activate your account." Add "Back to Sign In" link that resets mode to `LoginMode`. The door animation must NOT play; no JWT must be stored.

### Bug 4: HTTP 403 shows wrong error message on login
`errorMessage` in `Page.Login.elm` handles `Http.BadStatus 401`, `Http.BadStatus 409`, and `Http.BadStatus 422` explicitly. `Http.BadStatus 403` falls through to the generic message "The door remains shut. Invalid email or password." When a user with an unconfirmed email attempts to log in, they see a misleading error that implies their password is wrong — they cannot know they need to confirm their email.

**Fix**: Add a branch in `errorMessage` for `Http.BadStatus 403` returning: "Please confirm your email address before signing in. Check your inbox for the confirmation email."

### Bug 5: Confirmation email not delivered on preview
The confirmation email was never received after registration on the preview deployment (`stacks-core-pr-chore-close-gaps.fly.dev`). The email delivery chain requires `EMAIL_PROVIDER=resend` and `RESEND_API_KEY` to be set as Fly.io secrets on the preview app. If these are absent, Swoosh falls back to a non-sending adapter and silently drops the email.

**Verify**: Check that `EMAIL_PROVIDER` and `RESEND_API_KEY` are set as preview secrets. The `email_verification_controller_test.exs` and `email_delivery_job_test.exs` already cover the Elixir layer; this is a deployment configuration gap. Either set the secrets or document that email confirmation is disabled on preview and the test strategy for E2E must account for this (e.g., directly calling `GET /api/auth/confirm/:token` using the token from the database).

## Reviewer Context
- `Guardian.Plug.put_current_resource(conn, user)` (not `assign`) sets the Guardian resource in test conns.
- The login animation is 4000ms via `playLoginTransition` port.
- Registration now uses a dedicated `GotRegisterResponse` decoder (not `GotAuthResponse`) — tests must reflect this.
- `RequireConfirmedEmail` plug is part of the auth pipeline and fires on every authenticated request.
- Onboarding display condition: `model.auth == Just _` AND `not model.onboardingCompleted` AND `not model.hasAnyPlacements`.
- E2E tests for the full email confirmation flow require a way to retrieve the confirmation token without email delivery (e.g., read `email_confirmation_token` from the database via a test helper endpoint, or use `scripts/seed.sh` to pre-confirm the test user).
- Proto decoders are lenient — they return default-value structs rather than failing on unexpected JSON shapes. This is why Bug 2 manifests as a silent wrong-path rather than a visible decode error.

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #124)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #124 covers six user stories in the auth lifecycle —
US-14.1.1 (Register), US-14.1.2 (First-Time Onboarding), US-14.2.1 (Sign In),
US-14.3.1 (Authenticated Navigation State), US-14.3.2 (Session Expiry & Token
Refresh), US-14.3.3 (Log Out). The matrix is 13 layers × 6 US, happy/sad per
cell (156 cells). Assertion inventory is taken from each US's per-layer spec
in `docs/user_stories/US-14.*.md` plus Issue #124's Technical Requirements
(§1–§12).

**SECURITY-sensitive audit.** This is authentication: Guardian JWT issuance,
Argon2 password hashing (via `Stacks.Accounts.ArgonPool`, Issue #166),
per-account lockout (Issue #161), the `:auth` rate-limit bucket, email
enumeration defence, and token revocation. Cells touching these are flagged
**(SECURITY)** and are the highest-value sad paths.

**Feature status:** The backend auth stack is fully implemented and strongly
tested (register / confirm / login / lockout / logout / me / onboarding
endpoints). The **frontend** is where Issue #124 is blocked: the four
registration bugs (Bugs 1–4 in `US-14.1.1-register.md` §13 / `US-14.2.1-sign-in.md`
§12) are **NOT yet fixed** — `Page.Login.elm` still has no `passwordConfirm`
field, no `GotRegisterResponse` Msg, no `RegistrationPending` mode, and no
`Http.BadStatus 403` branch. The existing Elm tests (`LoginTest.elm`,
`LoginProgramTest.elm`) assert the *old* behaviour. US-14.3.2 (session expiry /
refresh) is explicitly **NOT IMPLEMENTED** per its spec §2.

---

### Framework-layer summary

| Layer       | US-14.1.1 Register | US-14.1.2 Onboarding | US-14.2.1 Sign In | US-14.3.1 Nav State | US-14.3.2 Session Expiry | US-14.3.3 Logout |
|-------------|--------------------|----------------------|-------------------|---------------------|--------------------------|------------------|
| Elixir      | ✅ strong          | ✅ strong            | ⚠️ (no 422-missing-fields / 503 HTTP / `user.login` audit assertion) | ✅ (minor: `RequireConfirmedEmail` plug untested) | ⚠️ (only 401-on-expired plug; refresh not impl) | ✅ (minor: revocation side-effect not asserted) |
| Elm unit    | ❌ (no passwordConfirm / GotRegisterResponse / RegistrationPending) | ✅ (`OnboardingOverlayTest`) | ✅ (`LoginTest`; Bug 4 403 missing → ⚠️) | ❌ (no `viewNav`/`isOwner` test) | n/a (not implemented) | ❌ (no `UserMenu` test) |
| Elm program | ❌ (no register-pending flow) | n/a (Main.elm not program-tested) | ✅ (`LoginProgramTest`) | ❌ (Main.elm nav not program-tested) | n/a | ❌ (no logout program test) |
| Python      | n/a — vision service not involved in auth | n/a | n/a | n/a | n/a | n/a |
| E2E         | ⚠️ (`register.spec` = fields + tab-switch only) | ❌ (no onboarding E2E) | ✅ (`auth.spec` + `login.spec`) | ⚠️ (display name + unauth nav; no owner/active-item) | ❌ (no session-expiry E2E) | ❌ (no logout E2E; `private-session.spec` covers ctx isolation) |
| dbt         | ✅ (`stg_users`) | ✅ (`stg_users.onboarding_completed`) | n/a | n/a | n/a | n/a |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/auth_controller_test.exs` — register (6), login (4), lockout (2), me (2), logout (2), forgot/reset-password (6), rate-limiting (2), full integration flow (1)
- `apps/core/test/stacks_web/email_verification_controller_test.exs` — 3 tests (valid / invalid / valid-sig-unknown-user token)
- `apps/core/test/stacks/accounts_test.exs` — register (8), authenticate (3 + 2 confirmation-gate), profile/location/password/notifications/visibility, onboarding context (status/complete/reset/generated-column)
- `apps/core/test/stacks/accounts/login_lockout_test.exs` — 15 tests (counter, threshold, ArgonPool skip, backoff, constant-time enumeration defence)
- `apps/core/test/stacks/accounts/argon_pool_test.exs` — 3 tests incl. `{:error, :argon2_busy}` on pool timeout
- `apps/core/test/stacks/accounts_property_test.exs` — StreamData property tests for location/profile/password changesets
- `apps/core/test/stacks_web/onboarding_controller_test.exs` — GET status, PUT step, POST reset, 401s, 422 invalid step, me onboarding fields (~18 tests)
- `apps/core/test/stacks/notifications/email_confirmation_handler_test.exs` — 3 tests (enqueue on `user.registered`, unknown event, user-not-found)
- `apps/core/test/stacks/workers/email_delivery_job_test.exs` — pref-gating + bypass templates (`registration_confirmation`) + unknown-template discard
- `apps/core/test/stacks_web/plugs/auth_error_handler_test.exs` — 401 on `:unauthenticated`/`:token_expired`, 403 on `:unauthorized`
- `apps/core/test/stacks_web/controllers/unauthenticated_redirect_test.exs` — 6 protected routes return 401 incl. `GET /api/auth/me`
- `frontend/tests/LoginTest.elm` — old login/register model (NO passwordConfirm)
- `frontend/tests/Page/LoginProgramTest.elm` — 10 program tests (login flow only)
- `frontend/tests/OnboardingOverlayTest.elm` — StatusLoaded/StepCompleted/Skip/Finish/loading-guard
- `e2e/tests/auth.spec.ts` (5), `login.spec.ts` (7), `register.spec.ts` (3), `private-session.spec.ts` (3)
- `dbt/models/staging/schema.yml` (`stg_users`) — not_null, unique, accepted_values(role, profile_visibility) — proto-generated

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **36** |
| ⚠️ shallow | **11** |
| ❌ missing | **5** |
| n/a (covered higher up / not applicable / by-design) | **104** |

156 cells total (13 layers × 6 US × happy/sad). This is the pre-implementation
baseline; Issue #124's DoD requires regenerating this audit to 0 ❌ / 0 ⚠️
after the punch list lands. The large `n/a` count reflects that four of the
six stories (14.1.2, 14.3.1, 14.3.2, 14.3.3) are almost entirely
client-side / stateless — their backend layers (DB, events, jobs, external,
storage, cache, dbt, cost) legitimately don't apply.

---

### Full audit tables

#### Layer 1: API Calls

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ✅ auth_controller_test — "creates user and returns confirmation_email_sent" (201), "first registered user gets owner role", "sets email_confirmed to false"; email_verification_controller_test — "redirects to /confirm-email/success … valid token" (302) | ✅ | ✅ auth_controller_test — "returns 422 on duplicate email", "returns 422 on missing password", "returns 429 after exceeding rate limit on register"; email_verification_controller_test — "redirects to /confirm-email/error with an invalid token" + valid-sig-unknown-user | ✅ |
| 14.1.2 | ✅ onboarding_controller_test — "returns all steps false for a fresh user", "returns correct next_step for partially completed user", "marks profile step as complete", "completing final step returns completed true" (GET /api/onboarding/status, PUT /api/onboarding/step/:step from #149). NB overlay itself makes no API calls (US §3). | ✅ | ✅ onboarding_controller_test — "returns 422 for invalid step name", "returns 401 when unauthenticated" (status + step + reset) | ✅ |
| 14.2.1 | ✅ auth_controller_test — "returns JWT on valid credentials" (200 `{token}`) | ✅ | ⚠️ auth_controller_test — "returns 401 on wrong password", "returns 401 on unknown email", "returns 403 when email is unconfirmed", "returns 423 … after threshold failures", "returns 429 after exceeding rate limit on login". BUT US-14.2.1 §3 lists **422 `email and password are required`** and **503 `service_busy`** (ArgonPool exhausted, Issue #166) — neither has an HTTP-level test (only `argon_pool_test` covers `{:error, :argon2_busy}` at the pool unit, not the 503 mapping). | ⚠️ |
| 14.3.1 | ✅ auth_controller_test — "returns current user when authenticated" (GET /api/auth/me 200); onboarding_controller_test — "GET /api/auth/me … includes onboarding_completed and next_onboarding_step" | ✅ | ✅ auth_controller_test — "returns 401 without token"; unauthenticated_redirect_test — "GET /api/auth/me without auth returns 401" | ✅ |
| 14.3.2 | n/a — `POST /api/auth/refresh` does not exist; refresh flow explicitly NOT IMPLEMENTED (US §2/§3). | n/a | ⚠️ Expired-token → 401 is asserted only at the plug-handler unit (auth_error_handler_test — "returns 401 for :unauthenticated error" with `:token_expired`). No end-to-end test drives an actually-expired JWT through `GET /api/auth/me`. Feature (Guardian `exp` verify) exists; endpoint-level expiry test missing. | ⚠️ |
| 14.3.3 | ✅ auth_controller_test — "returns 204 on logout" (DELETE /api/auth/logout); integration flow test also exercises it end-to-end | ✅ | ✅ auth_controller_test — "returns 401 without token" | ✅ |

#### Layer 2: Auth & Middleware Guards **(SECURITY)**

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ✅ Register runs through the `:api` + `:rate_limit_auth` pipeline with no auth required — exercised by every register happy-path test. | ✅ | ✅ **(SECURITY)** auth_controller_test — "returns 429 after exceeding rate limit on register" (`:auth` bucket, keyed by IP, 5/60s override). | ✅ |
| 14.1.2 | ✅ onboarding_controller_test — authenticated pipeline verified via authed conns on status/step/reset. (Overlay's own guard `model.auth == Just _` is client-side, audited at L10.) | ✅ | ✅ onboarding_controller_test — "returns 401 when unauthenticated" on all three endpoints. | ✅ |
| 14.2.1 | ✅ **(SECURITY)** No-auth login pipeline exercised by "returns JWT on valid credentials"; email-confirmation gate before token issuance covered by accounts_test — "returns :email_unconfirmed when user is unconfirmed". | ✅ | ✅ **(SECURITY)** login_lockout_test — "unknown email exercises constant-time path" + "unknown email does not crash on the lock check" (Argon2 dummy-verify / enumeration defence); "locked attempts do not consume ArgonPool slots" (traces `Argon2.verify_pass` is NOT called); auth_controller_test — "returns 429 after exceeding rate limit on login". | ✅ |
| 14.3.1 | ✅ **(SECURITY)** AuthPipeline verifies Bearer + loads resource — "returns current user when authenticated" proves the full VerifyHeader→EnsureAuthenticated→LoadResource chain. | ✅ | ⚠️ **(SECURITY)** 401-without-token is well covered (unauthenticated_redirect_test, 6 routes). BUT `RequireConfirmedEmail` — per Reviewer Context "fires on every authenticated request" — has **no dedicated plug test**: no test asserts an authenticated request with `email_confirmed == false` is 403'd on a protected route (the 403 is only tested at the login endpoint). | ⚠️ |
| 14.3.2 | n/a — no refresh guard exists to test (feature not implemented). | n/a | ✅ **(SECURITY)** auth_error_handler_test — "returns 401 for :unauthenticated error" with `{:unauthenticated, :token_expired}`; the AuthPipeline delegates expired/invalid tokens to this handler. (Global frontend 401→redirect is a client gap, at L10.) | ✅ |
| 14.3.3 | ⚠️ **(SECURITY)** logout requires auth ("returns 204 on logout" uses an authed conn), but **token-revocation side-effect is not asserted**: no test confirms the JWT is rejected on a subsequent `/api/auth/me` after `Guardian.revoke/1`. Without GuardianDb, `revoke` may be a no-op — this needs an explicit decision + test or the acceptance "token invalidated server-side" is unverified. | ⚠️ | ✅ auth_controller_test — "returns 401 without token" (logout). | ✅ |

#### Layer 3: Database Interactions **(SECURITY — Argon2)**

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ✅ **(SECURITY)** accounts_test — "creates a user with hashed password" (asserts `password_hash != nil`, `password == nil`), "first user gets owner role", "subsequent users get user role", "always creates user with email_confirmed false and a confirmation token"; email_verification_controller_test — valid token sets `email_confirmed == true`. Argon2 hashing is inside `registration_changeset`. | ✅ | ✅ **(SECURITY)** accounts_test — "returns error on duplicate email" (unique constraint), "returns error on invalid email format", "returns error on short password". | ✅ |
| 14.1.2 | ✅ accounts_test — `onboarding_steps` JSONB writes ("marks a valid step as completed", "completing all three steps sets onboarding_completed to true"), generated column ("empty onboarding_steps map produces onboarding_completed = false at DB level"), `reset_onboarding`. | ✅ | ✅ accounts_test — "returns error for invalid step" (`:invalid_step`). | ✅ |
| 14.2.1 | ✅ **(SECURITY)** accounts_test — "returns user on valid credentials" (Repo.get_by + ArgonPool verify); login_lockout_test — "successful login leaves counter at 0", "successful login resets the counter and clears the lock". | ✅ | ✅ **(SECURITY)** accounts_test — "returns error on wrong password", "returns error for unknown email"; login_lockout_test — "wrong password increments the counter", "expired failure window rolls the counter back to 1". | ✅ |
| 14.3.1 | n/a — nav state is derived entirely from localStorage; `me` reads `op.users` but not during nav render (covered at L1). | n/a | n/a — same. | n/a |
| 14.3.2 | n/a — no DB changes for session expiry; refresh-token storage not implemented (US §5). | n/a | n/a — same. | n/a |
| 14.3.3 | n/a — token revocation handled by Guardian, no direct DB op (no GuardianDb configured; US §5). | n/a | n/a — same. | n/a |

#### Layer 4: Event Flow & Lifecycle

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ✅ accounts_test — "emits user.registered event on success" + "register/1 emits event payload without PII fields" (payload `%{role: …}`, no email); email_confirmation_handler_test — "enqueues EmailDeliveryJob on user.registered" (handler wired in `Events.Registry`, verified), "returns ok when user not found". | ✅ | ⚠️ No negative-emission test: nothing asserts `user.registered` is **absent** from `event_log` when the registration `Ecto.Multi` rolls back (e.g. duplicate email). The upload audit's equivalent ("image.submitted is NOT emitted when storage backend returns an error") has no auth counterpart. | ⚠️ |
| 14.1.2 | n/a — onboarding overlay emits no events (US §6). | n/a | n/a — same. | n/a |
| 14.2.1 | ⚠️ **(SECURITY/audit)** US-14.2.1 §6 requires a `user.login` **audit** entry (`Audit.log/3`) on successful login. `Audit.log` is generically tested (audit_test uses `"user.login"` as a fixture at line 262) but **no test asserts `AuthController.login/2` actually writes the audit row** on a real login. | ⚠️ | n/a — no audit entry on failed login by design (only successful logins are audited). | n/a |
| 14.3.1 | n/a — no events (US §6). | n/a | n/a | n/a |
| 14.3.2 | n/a — no events (US §6). | n/a | n/a | n/a |
| 14.3.3 | n/a — logout emits no events / no audit by design (US §6). | n/a | n/a | n/a |

#### Layer 5: Background Jobs (Oban)

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ✅ email_confirmation_handler_test — "enqueues EmailDeliveryJob on user.registered" (asserts `template: "registration_confirmation"`, `user_id`); email_delivery_job_test — "delivers registration_confirmation regardless of prefs" (queue `:notifications`). | ✅ | ⚠️ email_delivery_job_test — "discards the job immediately without retrying" (unknown template). BUT US-14.1.1 §7 per-user (10/hr) + global (100/hr) email rate limits are **untested**, and the enqueue assertion does not check `args.params.token` is present. | ⚠️ |
| 14.1.2 | n/a — no jobs (US §7). | n/a | n/a | n/a |
| 14.2.1 | n/a — no jobs (US §7). | n/a | n/a | n/a |
| 14.3.1–14.3.3 | n/a — no jobs (US §7). | n/a | n/a | n/a |

#### Layer 6: External Service Calls

| US       | Happy Path | Sad Path |
|----------|------------|----------|
| 14.1.1 | ✅ email_delivery_job_test delivers `registration_confirmation` via the Swoosh **test adapter** (Resend mock in test env); confirmation link format `/api/auth/confirm/:token` is exercised by email_verification_controller_test. | n/a — Resend is mocked in test; real delivery-failure handling is generic Oban retry, not unit-tested (US §8 says emails are logged locally in dev/test). Bug 5 (preview `RESEND_API_KEY` config) is a deployment-config gap, not a unit-test gap. |
| 14.1.2–14.3.3 | n/a — no external calls (US §8). | n/a — same. |

#### Layer 7: Storage (R2 / Local)

| US       | Happy Path | Sad Path |
|----------|------------|----------|
| 14.1.1 | n/a — no storage (US §9). | n/a — same. |
| 14.1.2 | n/a — localStorage onboarding state (`saveOnboardingCompleted` / `requestOnboardingStatus` ports) is client-side; audited at L10. No R2/server storage (US §9). | n/a — same. |
| 14.2.1 | n/a — no storage (US §9). | n/a |
| 14.3.1 | n/a — `saveAuth` localStorage persistence is client-side; audited at L10 (US §9). | n/a |
| 14.3.2 | n/a — token localStorage persistence client-side; audited at L10. | n/a |
| 14.3.3 | n/a — `clearAuth` localStorage removal client-side; audited at L10 (US §9). | n/a |

#### Layer 8: Cache Interactions (RateLimiter `:auth` bucket)

| US       | Happy Path | Sad Path |
|----------|------------|----------|
| 14.1.1 | ✅ RateLimiter `:auth` check+increment exercised by auth_controller_test rate-limiting describe (5/60s override on IP `10.99.1.1`). | ✅ auth_controller_test — "returns 429 after exceeding rate limit on register". |
| 14.2.1 | ✅ Same bucket on login (IP `10.99.1.2`). | ✅ auth_controller_test — "returns 429 after exceeding rate limit on login". |
| 14.1.2, 14.3.1–14.3.3 | n/a — no cache in the read/write path (US §10). | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US       | Happy Path | Sad Path |
|----------|------------|----------|
| 14.1.1 | ✅ `dbt/models/staging/schema.yml` (`stg_users`, proto-generated) — `not_null` + `unique` on `id`/`email`, `not_null` on `email_confirmed`/`role`/`profile_visibility`/`created_at`/`updated_at`. | ✅ `accepted_values` on `role` (`owner`/`user`) and on `profile_visibility` — the schema-level guards for the two enumerations register/login write. (No event-triggered dbt refresh for `user.registered`: `Events.Registry` maps it only to `EmailConfirmationHandler`, not `DbtRefreshHandler` — consistent with US §11 "via DbtRefreshHandler *if configured*"; it is not.) |
| 14.1.2 | ✅ `stg_users.onboarding_completed` — `not_null` test present (generated column surfaced in staging). | n/a — no additional constraint applies to the onboarding overlay. |
| 14.2.1 | n/a — login is a read; no dbt dependency (US §11). | n/a |
| 14.3.1–14.3.3 | n/a — no dbt dependency (US §11). | n/a |

#### Layer 10: Elm Frontend State Machine — **primary gap surface**

| US       | Happy Path | Verdict | Sad Path | Verdict |
|----------|------------|---------|----------|---------|
| 14.1.1 | ❌ **FEATURE GAP (Bugs 1–3).** `Page.Login.elm` has no `passwordConfirm` field, no `GotRegisterResponse` Msg, no `RegistrationPending` mode. `LoginTest.elm`'s model literal (lines 74–83) has no `passwordConfirm`; register is not exercised at all. No test for: confirm-password validation, `GotRegisterResponse (Ok ()) → RegistrationPending email` + OutMsg `RegistrationSucceeded`, "Check your inbox" pending card, or the "no JWT / no door animation / no nav to antilibrary" invariant. `register.spec.ts` E2E covers only field presence + tab switching. | ❌ | ❌ **FEATURE GAP.** No test for: mismatched confirm-password disabling submit ("Passwords do not match"), `GotRegisterResponse (Err _) → Failure`, or the duplicate-email error message ("Registration could not be completed…"). Neither elm-test nor Playwright covers the register sad paths. | ❌ |
| 14.1.2 | ⚠️ `OnboardingOverlayTest.elm` covers the component forward flow strongly (`StatusLoaded` resume at profile/age_verification/privacy, `StepCompleted` advance, `FinishOnboarding → FinishCompleted`, `NextStep` loading guard + disabled Continue button). BUT the US-14.1.2 acceptance lives in **Main.elm wiring**, which is untested: the display condition `auth == Just _ && not onboardingCompleted && not hasAnyPlacements`, the `requestOnboardingStatus`/`saveOnboardingCompleted` ports, and `OnboardingStatusReceived`. | ⚠️ | ✅ `OnboardingOverlayTest.elm` — "SkipOnboarding hides the overlay and emits SkipCompleted", "starts from Welcome on API error (graceful fallback)", "advances locally on API error (user not stuck)". | ✅ |
| 14.2.1 | ✅ `LoginTest.elm` — init/field-updates/mode-switch/submit/`GotAuthResponse Ok → Transitioning`+`StartTransition`/`TransitionCompleted → LoggedIn`/validation-wiring; `LoginProgramTest.elm` — "login_form_submit_shows_spinner", "login_success_transition", "submit_disabled_during_transition". | ✅ | ⚠️ 401 credential error is covered (`LoginTest` — "GotAuthResponse Err BadStatus 401…"; `LoginProgramTest` — "login_failure_shows_error" → "The door remains shut. Invalid credentials."). BUT **Bug 4 unfixed/untested**: no `Http.BadStatus 403` branch → unconfirmed-email message; and no coverage of the 423 `account_locked` or 503 `service_busy` messages (US §2 sad paths). | ⚠️ |
| 14.3.1 | ⚠️ Authenticated display-name is asserted only via E2E (auth.spec — "sign in … shows user name" → `user-menu` has text "Platform Owner"). No Elm test for `viewNav (Just auth)` rendering the full nav set, the `app-nav__item--active` class, or the owner-only Admin dropdown (`isOwner`). Main.elm is not program-tested. | ⚠️ | ⚠️ Unauthenticated nav asserted via E2E only (login.spec — "navbar shows only Costs and Sign In when not authenticated"; `library`/`upload`/`search` hidden). No Elm test for `viewNav Nothing`, `decodeFlags` auth restoration from flags, or owner-vs-non-owner distinction. | ⚠️ |
| 14.3.2 | n/a — silent refresh / periodic renewal not implemented (US §2 "NOT IMPLEMENTED"). | n/a | ❌ **FEATURE NOT IMPLEMENTED.** No global `Http.BadStatus 401` interceptor in Main.elm → `clearAuth` → redirect `/login`. Neither the feature nor a test exists. Exceeds #124's test-only scope → new issue (scope-lock rule). | ❌ |
| 14.3.3 | ❌ `Components.UserMenu` has **no test file at all** (grep: no `UserMenu`/`SignOut`/`clearAuth` reference under `frontend/tests/`). No test for `Toggle`, `SignOutClicked → SignOut` OutMsg, or Main.elm's SignOut handling (`auth = Nothing`, `clearAuth ()` port, `Nav.pushUrl /login`). No logout E2E in any spec. | ❌ | ❌ No test for Escape-key / click-outside-backdrop closing the menu, or the non-blocking logout-API-failure path (`LogoutCompleted` no-op). | ❌ |

#### Layer 11: Operational Metrics

All cells `n/a — covered by SLO gate`. `scripts/check-slo-gate.sh` scrapes
`/internal/metrics` post-deploy and asserts the **`auth_p95_ms`** SLI
(route group `"auth"`, threshold 500 ms — line 643) alongside automatic
Phoenix endpoint + Guardian telemetry. Per-US metrics named in the specs
(registration success/failure rate, `:auth` rate-limiter trigger count,
Argon2 hash p50/p95/p99, JWT issuance count, login failure-by-type, token
revocation success rate, auth-restoration rate, onboarding step/skip rates)
are dashboard/SLO concerns; per-US firing tests add no guarantee.

> Note: unlike the upload pipeline (`upload_telemetry_test.exs`), there is
> **no auth-specific telemetry-firing test**. If Issue #124 §12 wants
> event-firing assertions (register success/failure, rate-limiter trips,
> JWT issuance), those would be net-new — flagged as an optional decision
> in the punch list, not a blocking ❌.

#### Layer 12: Performance & Usability Metrics

All cells `n/a — covered by SLO gate, not unit tests`. In-test SLA bounds
(e.g. login latency, Argon2 timing targets) are an anti-pattern under
variable CI timing. NB the Argon2 *constant-time* property IS asserted
behaviourally in `login_lockout_test.exs` ("unknown-email path … NOT
effectively instantaneous") — but that is a SECURITY assertion (audited at
L2), not a performance SLA.

#### Layer 13: Cost Tracking

All cells `n/a`. Auth has no per-call `BudgetTracker` spend: Resend email
(~$0.001) and Argon2 CPU are absorbed into Fly.io/Neon billing and covered
by the cost dashboard at deploy time (US-14.1.1 §16 / US-14.2.1 §15). There
is no external-API metered cost to record per request.

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Items 8, 9, 11
are the **Issue #124 core** (Bugs 1–4 — feature + test). Item 14 is a
feature gap that exceeds #124's test-only scope.

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 US-14.2.1 sad | HTTP tests for `POST /api/auth/login` **422** `email and password are required` (missing fields) and **503** `service_busy` + `Retry-After: 5` when ArgonPool is exhausted (Issue #166). | `apps/core/test/stacks_web/auth_controller_test.exs` |
| 2 | L1 US-14.3.2 sad | End-to-end expired-token test: an actually-expired JWT to `GET /api/auth/me` returns 401 (drive Guardian TTL, not just the `auth_error_handler` unit). | `apps/core/test/stacks_web/auth_controller_test.exs` |
| 3 | L2 US-14.3.1 sad **(SECURITY)** | `RequireConfirmedEmail` plug test: an authenticated request from a user with `email_confirmed == false` is 403'd on a protected route (currently only tested at the login endpoint). | new `apps/core/test/stacks_web/plugs/require_confirmed_email_test.exs` |
| 4 | L2 US-14.3.3 happy **(SECURITY)** | Assert logout actually invalidates the token: after `DELETE /api/auth/logout`, the same JWT is rejected (401) on `GET /api/auth/me`. If `Guardian.revoke/1` is a no-op without GuardianDb, decide + document (code gap, not just test gap). | `apps/core/test/stacks_web/auth_controller_test.exs` |
| 5 | L4 US-14.1.1 sad | Negative-emission test: no `user.registered` row in `event_log` when the registration `Ecto.Multi` rolls back (duplicate email / invalid changeset). | `apps/core/test/stacks/accounts_test.exs` |
| 6 | L4 US-14.2.1 happy **(SECURITY/audit)** | Assert `AuthController.login/2` writes a `user.login` audit entry (`resource_type: "user"`, hashed IP) on successful login — not just that `Audit.log/3` works generically. | `apps/core/test/stacks_web/auth_controller_test.exs` |
| 7 | L5 US-14.1.1 sad | `EmailDeliveryJob` per-user (10/hr) + global (100/hr) rate-limit tests (US §7); extend the enqueue assertion to check `args.params.token` is present. | `apps/core/test/stacks/workers/email_delivery_job_test.exs` |
| 8 | L10 US-14.1.1 happy **(Bugs 1–3, core)** | Fix + test the register happy path: `passwordConfirm` field/validation (Bug 1), `GotRegisterResponse (Ok ()) → RegistrationPending email` + OutMsg `RegistrationSucceeded` using `registrationResponseDecoder` (Bug 2), "Check your inbox" pending card + no-JWT/no-door/no-nav invariant (Bug 3). Add matching E2E (registration success → pending state; confirm-email success/error pages). | `frontend/tests/LoginTest.elm`, `frontend/tests/Page/LoginProgramTest.elm`, `e2e/tests/register.spec.ts` |
| 9 | L10 US-14.1.1 sad | Register sad paths: mismatched confirm-password disables submit + "Passwords do not match" hint; `GotRegisterResponse (Err _) → Failure`; duplicate-email 422 → "Registration could not be completed…" message. | `frontend/tests/LoginTest.elm`, `frontend/tests/Page/LoginProgramTest.elm`, `e2e/tests/register.spec.ts` |
| 10 | L10 US-14.1.2 happy | Main.elm onboarding wiring: display condition `auth == Just _ && not onboardingCompleted && not hasAnyPlacements`; `requestOnboardingStatus`/`saveOnboardingCompleted` ports; `OnboardingStatusReceived`. Plus onboarding E2E (3-step overlay, skip link, progress dots). | new Main-level program test + `e2e/tests/` onboarding spec |
| 11 | L10 US-14.2.1 sad **(Bug 4)** | Fix + test: `errorMessage` `Http.BadStatus 403` → "Please confirm your email address before signing in. Check your inbox for the confirmation email."; add 423 `account_locked` and 503 `service_busy` messages. E2E: unconfirmed-email login shows the confirmation message (not generic). | `frontend/tests/LoginTest.elm`, `frontend/tests/Page/LoginProgramTest.elm`, `e2e/tests/login.spec.ts` |
| 12 | L10 US-14.3.1 happy | Elm test: `viewNav (Just auth)` renders the full authenticated nav + display name; `isOwner` gates the Admin dropdown (Metrics/Sources/Scrapers); `app-nav__item--active` on the current route. | new `frontend/tests/` nav/Main program test; extend `e2e/tests/auth.spec.ts` (owner-only admin dropdown) |
| 13 | L10 US-14.3.1 sad | Elm test: `viewNav Nothing` renders `[Catalogue, Marketplace, Sign In]` only; `decodeFlags` restores `Maybe Auth` from localStorage flags; owner-vs-non-owner nav distinction. | new `frontend/tests/` nav/Main program test |
| 14 | L10 US-14.3.2 sad **(feature not implemented)** | Global `Http.BadStatus 401` interceptor in Main.elm → `model.auth = Nothing` + `clearAuth ()` + redirect `/login`; optional refresh-token flow. Neither feature nor test exists — **exceeds #124's test-only scope; open a new implementation issue** (scope-lock rule). | new issue → Main.elm + `frontend/tests/` + `e2e/tests/` |
| 15 | L10 US-14.3.3 happy | `Components.UserMenu` tests: `Toggle` open/close, `SignOutClicked → SignOut` OutMsg; Main.elm SignOut handling (`auth = Nothing`, `clearAuth ()` port, `Nav.pushUrl /login`). E2E: display-name dropdown → "Sign Out" → `/login`, nav reverts to unauthenticated, protected page redirects after logout. | new `frontend/tests/UserMenuTest.elm` + Main program test; `e2e/tests/auth.spec.ts` |
| 16 | L10 US-14.3.3 sad | `UserMenu` Escape-key + click-outside-backdrop close; non-blocking logout-API-failure (`LogoutCompleted` no-op). E2E: Escape closes user menu + book-detail overlay (Issue §1). | new `frontend/tests/UserMenuTest.elm`; `e2e/tests/auth.spec.ts` |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 6-US matrix (156 cells):

- **36 ✅ STRONG** — concentrated in the **Elixir backend** (register, confirm,
  login, per-account lockout, constant-time enumeration defence, onboarding
  context + controller, rate limiting) and **dbt** (`stg_users`), plus the
  **login** Elm/program/E2E flow and the **OnboardingOverlay** component.
- **11 ⚠️ shallow** — login 422/503 HTTP gaps, `user.login` audit not asserted
  at the controller, `RequireConfirmedEmail` plug untested, logout-revocation
  side-effect unverified, no negative-emission test, email rate-limit
  untested, and the frontend nav-state / onboarding-wiring / Bug-4 gaps.
- **5 ❌ missing** — all in **Layer 10 (Elm)**: register happy + sad
  (Bugs 1–3), session-expiry 401 handler (feature not implemented), logout
  happy + sad (no `UserMenu` tests at all).
- **104 n/a** — four of six stories are client-side/stateless, so their DB,
  event, job, external, storage, cache, dbt, cost, and metrics layers
  legitimately don't apply; every `n/a` carries an inline rationale.

**Headline findings:**
1. **The backend is production-grade; the frontend is the blocker.** Every
   register/login/lockout/logout/onboarding endpoint has real, often
   security-focused coverage (Argon2 timing parity, ArgonPool-skip tracing,
   exponential-backoff lockout). But the **four registration bugs (Bugs 1–4)
   are unfixed** and the Elm tests still assert the old behaviour — this is
   the core of Issue #124 (punch items 8, 9, 11).
2. **Logout is entirely untested on the client** — `Components.UserMenu` has
   no test file, there is no logout E2E, and the server-side token-revocation
   side-effect is never asserted (SECURITY, items 4, 15, 16). The KNOWN
   private-browsing bug is guarded by `private-session.spec.ts` (browser-context
   isolation), but note it runs under Chromium, not Brave specifically.
3. **Session expiry / token refresh (US-14.3.2) is genuinely not built** —
   no `POST /api/auth/refresh`, no global 401 redirect. This exceeds #124's
   test-only charter and should become a new implementation issue (item 14).
4. Two SECURITY sad-paths worth landing regardless of the bug fixes: the
   `RequireConfirmedEmail` plug (item 3) and the logout-revocation assertion
   (item 4).

**Test runner totals at baseline (auth-relevant):** Elixir ~55 tests across
`auth_controller_test`, `email_verification_controller_test`, `accounts_test`,
`login_lockout_test`, `argon_pool_test`, `onboarding_controller_test`,
`email_confirmation_handler_test`, `email_delivery_job_test`,
`auth_error_handler_test`, `unauthenticated_redirect_test`; Elm ~35 tests
across `LoginTest`, `LoginProgramTest`, `OnboardingOverlayTest`; Playwright
18 tests across `auth.spec`, `login.spec`, `register.spec`,
`private-session.spec`; dbt ~10 generic column tests on `stg_users`. Punch
list: **16 items**, of which 2 (#4, #14) are partially/wholly blocked on
implementation code.
## Definition of Done
- [ ] Bug 1 fixed: confirm password field shown in register mode, submit disabled if passwords don't match
- [ ] Bug 2 fixed: `Api.register` uses `registrationResponseDecoder`; `GotRegisterResponse` Msg introduced
- [ ] Bug 3 fixed: `RegistrationPending email` mode implemented; post-registration shows "check your inbox" card
- [ ] Bug 4 fixed: `errorMessage` handles `Http.BadStatus 403` with unconfirmed email message
- [ ] Bug 5 investigated: preview email delivery confirmed working or documented workaround for E2E
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] New Elm unit tests: `validatePasswordConfirm`, `GotRegisterResponse (Ok)` → RegistrationPending, `GotAuthResponse (Err 403)` → correct message
- [ ] New Elm program tests: register happy path shows pending state; login with 403 shows correct message
- [ ] New E2E tests: registration flow, email confirmation pages, unconfirmed email login error
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires Accounts context, AuthController, Guardian config, EmailDeliveryJob, Onboarding overlay component.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
