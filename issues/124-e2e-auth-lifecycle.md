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
- **Registration form**: Navigate to `/login` -> click "Register" tab -> display name, email, password fields
- **Tab switching**: Switch between "Sign In" and "Register" tabs -> email and password preserved
- **Registration validation**: Email must contain `@` and `.`, password >= 8 chars, display name non-empty
- **Field validation styles**: Green border (`login-card__field--valid`) or red border with hint (`login-card__field--error`)
- **Submit disabled**: "Request Entry" button disabled until all fields validate
- **Submit spinner**: Button shows spinner during API request
- **Login form**: "Enter the Stacks" submit button, email and password fields
- **Login success**: Door animation plays (4000ms) -> redirect to `/antilibrary`
- **Login error messages**: "The door remains shut. Invalid credentials." on 401
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
- `Page.Login` init: `email = "", password = "", displayName = "", mode = LoginMode, submitState = NotAsked`
- `ModeSwitched RegisterMode` -> switches to registration mode
- `DisplayNameChanged`/`EmailChanged`/`PasswordChanged` -> update fields, run validation
- `FormSubmitted` (register) -> `Api.register`, `submitState = Loading`
- `FormSubmitted` (login) -> `Api.login`, `submitState = Loading`
- `GotAuthResponse (Ok response)` -> `submitState = Success`, `transitionState = Transitioning`, OutMsg `StartTransition`
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

## Reviewer Context
- `Guardian.Plug.put_current_resource(conn, user)` (not `assign`) sets the Guardian resource in test conns.
- The login animation is 4000ms via `playLoginTransition` port.
- The Elm frontend currently expects an `AuthResponse` from register, but the backend returns `{ message: "confirmation_email_sent" }` — this is a known mismatch.
- `RequireConfirmedEmail` plug is part of the auth pipeline and fires on every authenticated request.
- Onboarding display condition: `model.auth == Just _` AND `not model.onboardingCompleted` AND `not model.hasAnyPlacements`.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires Accounts context, AuthController, Guardian config, EmailDeliveryJob, Onboarding overlay component.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
