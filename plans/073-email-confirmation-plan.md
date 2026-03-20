# Plan: Issue #073 — Email Confirmation Gate

## Context

Most infrastructure already exists: `Email.send_registration_confirmation/1`, `Email.confirm_email/1`, `EmailVerificationController` with `/api/auth/confirm/:token`, `EmailDeliveryJob`, User schema fields (`email_confirmed`, `email_confirmation_token`). The gaps are narrow: gate `authenticate/2`, handle in auth controller, config flag, tests.

## Key Decisions

1. **Use existing Phoenix.Token approach** — not `crypto.strong_rand_bytes` as the issue spec originally suggested. Phoenix.Token is already implemented and provides cryptographic security + built-in expiry.
2. **`email_confirmed` boolean** — use existing field, not `email_confirmed_at` timestamp. The boolean is simpler and already in the schema.
3. **Config flag `REQUIRE_EMAIL_CONFIRMATION`** — bypass in dev/test, require in prod. Already partially configured.
4. **JWT still issued on registration** — but login is gated until confirmed. This allows the frontend to show a "check your email" state while the user is technically authenticated but flagged.

## Implementation Steps

### Step 1: Gate `authenticate/2`
- After credential verification succeeds, check `user.email_confirmed`
- If `require_email_confirmation?()` is true and `email_confirmed` is false: return `{:error, :email_unconfirmed}`
- `require_email_confirmation?/0` reads `Application.get_env(:core, :require_email_confirmation, false)`

### Step 2: Handle in AuthController
- `login/2`: handle `{:error, :email_unconfirmed}` → return 403 with `%{error: "email_unconfirmed"}`
- `register/2`: after successful registration, if confirmation required, return 201 with `%{message: "confirmation_email_sent"}` instead of JWT

### Step 3: Create EmailConfirmationHandler
- `Stacks.Notifications.EmailConfirmationHandler` — implements `Stacks.Events.Handler`
- On `user.registered` event: enqueue `EmailDeliveryJob` with `template: "registration_confirmation"`
- Register in Events.Registry for `"user.registered"`

### Step 4: Configuration
- `config.exs`: `config :core, :require_email_confirmation, false` (dev default)
- `test.exs`: already has `false`
- `runtime.exs`: `if System.get_env("REQUIRE_EMAIL_CONFIRMATION") == "true", do: config :core, :require_email_confirmation, true`

### Step 5: Update factory + tests
- User factory: add `email_confirmed: true` default (so existing tests don't break)
- Test `authenticate/2` with unconfirmed user when flag is true
- Test auth controller 403 response
- Test handler enqueues email job

## File Inventory

### New files
- `apps/core/lib/stacks/notifications/email_confirmation_handler.ex`
- `apps/core/test/stacks/notifications/email_confirmation_handler_test.exs`

### Modified files
- `apps/core/lib/stacks/accounts.ex` — add email gate to authenticate/2
- `apps/core/lib/stacks_web/controllers/auth_controller.ex` — handle :email_unconfirmed
- `apps/core/lib/stacks/events/registry.ex` — add user.registered handler
- `apps/core/config/config.exs` — require_email_confirmation default
- `apps/core/config/runtime.exs` — REQUIRE_EMAIL_CONFIRMATION env var
- `apps/core/test/support/factory.ex` — email_confirmed: true default
- `apps/core/test/stacks/accounts_test.exs` — add confirmation gate tests
- `apps/core/test/stacks_web/controllers/auth_controller_test.exs` — add 403 test
