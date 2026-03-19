# Issue #073: Accounts Context — Email Confirmation Gate

## Summary
The `users` table has `email_confirmed_at` and `confirmation_token` columns (added in #043), but `Stacks.Accounts.register/1` does not set `email_confirmed_at = nil` / `confirmation_token = <token>`, and `authenticate/2` does not block unconfirmed accounts. Without this gate, users can log in without confirming their email address.

## User Stories
US-4.1.1 (Email-based registration with confirmation)

## Goal
Wire the email confirmation flow into `Accounts.register/1` and `Accounts.authenticate/2`. On registration, generate a confirmation token and send a confirmation email. On login, block users whose email is not yet confirmed. Provide `confirm_email/1` to mark confirmation complete.

## Technical Requirements

**`Stacks.Accounts.register/1` update:**
- Generate a cryptographically secure token: `Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)`
- Set `confirmation_token = <token>` and `email_confirmed_at = nil` on the new user record
- After insert, emit `"user.email_confirmation_requested"` event (payload: `{user_id, email, token}`)
- Return value unchanged: `{:ok, user}` — token delivery is async via event handler

**`Stacks.Accounts.authenticate/2` update:**
- After credential check, before issuing JWT:
  - If `email_confirmed_at == nil` → return `{:error, :email_unconfirmed}`
  - If KYC required and `kyc_status` not in `[:approved, :bypassed]` → return `{:error, :kyc_pending}` (existing, from #069)
- Order: credential check → email gate → KYC gate → issue JWT

**`Stacks.Accounts.confirm_email/1`:**
- `confirm_email(token)` — looks up user by `confirmation_token`, sets `email_confirmed_at = now()`, clears `confirmation_token = nil`
- Returns `{:ok, user}` or `{:error, :invalid_token}` or `{:error, :already_confirmed}`
- Emits `"user.email_confirmed"` event (payload: `{user_id}`)

**`StacksWeb.AuthController` updates:**
- `GET /api/auth/confirm/:token` — calls `Accounts.confirm_email/1`, returns `{:ok}` JSON or error
- `register/2` response: already returns `{:ok, user}` — no change needed (frontend knows to show "check your email" message)
- Handle `{:error, :email_unconfirmed}` in `login/2`: return 403 `{"error": "email_unconfirmed"}`

**Email delivery (stub for now):**
- Define `Stacks.Notifications.EmailHandler` behaviour stub that handles `"user.email_confirmation_requested"` event
- Actual SMTP/SES integration is out of scope — log the token to Logger at info level in dev/test
- In production, the `EmailHandler.handle_event/1` implementation is a separate concern; stub must be `@behaviour Stacks.Events.Handler` compliant (from #070)

**`REQUIRE_EMAIL_CONFIRMATION` config flag:**
- `config :stacks, :require_email_confirmation, System.get_env("REQUIRE_EMAIL_CONFIRMATION", "true") == "true"`
- When `false` (dev/test): `register/1` sets `email_confirmed_at = DateTime.utc_now()` immediately (no token), `authenticate/2` skips email gate
- When `true` (production): full gate active

**Tests:**
- `register/1` sets confirmation token when flag is true; auto-confirms when false
- `authenticate/2` returns `:email_unconfirmed` for unconfirmed user
- `confirm_email/1` with valid token, invalid token, already-confirmed token
- `AuthController` POST /api/auth/confirm/:token — happy path and invalid token

## Definition of Done
- [ ] `register/1` generates token and emits `user.email_confirmation_requested` (when flag true)
- [ ] `authenticate/2` blocks unconfirmed accounts with `{:error, :email_unconfirmed}`
- [ ] `confirm_email/1` implemented with all three return paths
- [ ] `GET /api/auth/confirm/:token` route and controller action
- [ ] `REQUIRE_EMAIL_CONFIRMATION` config flag respected
- [ ] `Stacks.Notifications.EmailHandler` stub (logs token in dev)
- [ ] All tests pass
- [ ] `mix credo --strict` passes

## Dependencies
Issue #043 (`email_confirmed_at`, `confirmation_token` columns on `op.users`), Issue #070 (Events.Handler behaviour for EmailHandler stub)

## Agent Assignment
elixir-agent

## Progress Notes
<!-- Updated by agents during execution -->
Created 2026-03-19 as GAP-07 from roadmap gap analysis. Email confirmation columns existed in #043 schema but were not wired into Accounts context functions.
