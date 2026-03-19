# Phase 3 Completion: Issue #055 — Email Infrastructure

**Completed**: 2026-03-19
**Status**: APPROVED (one revision cycle — 7 non-blocking reviewer items, all addressed)
**Tests**: 414 tests, 0 failures (new tests: email_test, email_delivery_job_test, email_verification_controller_test updated)
**Credo**: Clean (`mix credo --strict`)
**Elm**: Compiles clean (9 modules)
**E2E gate**: `e2e/tests/confirm-email.spec.ts` added (4 tests; requires dev server)

---

## What Was Built

### Migration
| File | Content |
|------|---------|
| `20260319000007_add_email_confirmation_and_password_reset_to_users.exs` | Adds `email_confirmed boolean NOT NULL DEFAULT false`, `email_confirmation_token text NULL`, `password_reset_token text NULL`, `password_reset_sent_at timestamptz NULL` to `op.users` |

### Elixir — Core Email Context (`lib/stacks/email.ex`)
- `send_registration_confirmation/1` — rate-check → `Repo.transaction` wrapping token write + `Oban.insert!`
- `confirm_email/1` — verifies `Phoenix.Token` (48h), sets `email_confirmed = true`, clears token
- `send_password_reset/1` — no-enumeration (returns `:ok` for unknown emails); known users: rate-check → transaction wrapping token write + job
- `reset_password/2` — verifies token (24h expiry), validates password length (min 8) via changeset before hashing
- Hammers rate limiter: 10 emails/user/hour (`Hammer.check_rate/3`)

### Elixir — Email Worker (`lib/stacks/workers/email_delivery_job.ex`)
- Queue: `notifications`, concurrency: 3, max_attempts: 3
- Template allow-list via `@known_templates` map; unknown templates → `{:discard, reason}` (no retry)
- `should_send?/2` catch-all is `false` — new templates opt-in explicitly
- Preference exemptions: `:registration_confirmation` and `:opt_out_confirmation` always send

### Elixir — Controllers
- `EmailVerificationController.confirm/2` — redirects to `/confirm-email/success` or `/confirm-email/error` (browser-friendly, no JSON)
- `AuthController.reset_password/2` — handles `{:error, %Ecto.Changeset{}}` → 422 with validation details
- `AuthController.get_ip/1` — handles comma-separated `x-forwarded-for` (multi-proxy chains)

### Elixir — User Changeset (`Accounts.User`)
- `email_confirmation_changeset/2` — casts `email_confirmation_token`
- `password_update_changeset/2` — accepts `:password` virtual field, validates `min: 8`, then hashes via Argon2; clears reset token and `sent_at`

### Elm — Route & Page
- `Navigation.Route` — `ConfirmStatus(EmailConfirmed | EmailConfirmFailed)`, `ConfirmEmail ConfirmStatus` route, parser entries for `/confirm-email/success` and `/confirm-email/error`
- `Main.elm` — `PageConfirmEmail ConfirmStatus` page variant; `viewConfirmEmail` renders success/error states with appropriate CTA links; no auth required

### Swoosh Config
- `config/dev.exs`, `config/test.exs` — `Swoosh.Adapters.Local`
- `config/prod.exs` — `Swoosh.Adapters.Resend` (key via `RESEND_API_KEY` env var)

### Email Templates (HEEx, platform aesthetic)
- `registration_confirmation.html.heex`
- `password_reset.html.heex`
- `marketplace_sale.html.heex`
- `gdpr_export_ready.html.heex`
- `wishlist_availability.html.heex`
- `opt_out_confirmation.html.heex`

---

## Issues Found and Fixed During Review

| Item | Resolution |
|------|-----------|
| `change/0` vs `down/0` for migration | Kept `change/0` — migration adds only nullable columns, fully reversible |
| Token write + job enqueue not atomic | Wrapped in `Repo.transaction`; rate-check precedes transaction |
| `String.to_existing_atom` on template string | Replaced with `@known_templates` map + `{:discard, reason}` for unknowns; test added |
| Password length not validated on reset | `password_update_changeset` validates `min: 8` before hashing; controller handles `{:error, changeset}` → 422 |
| `should_send?/2` catch-all was `true` | Changed to `false` — explicit opt-in for each template |
| `x-forwarded-for` multi-proxy edge case | Split on comma, take leftmost (original client) IP |
| Confirm endpoint returned JSON | Changed to redirect; `ConfirmEmail` Elm route + page added |

---

## Integration Handoffs

- **#056** (RSS feeds + metrics marts) — no dependencies on email
- **#057** (Elm overlay, upload, settings) — `email_confirmed` flag available for gating features in Elm model
- **#060** (Marketplace backend) — `EmailDeliveryJob` template `:marketplace_sale` stubbed and ready
- **Frontend** — `/confirm-email/success` and `/confirm-email/error` are live routes; nav links can reference them
