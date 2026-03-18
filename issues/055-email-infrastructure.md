# Issue #055: Email Infrastructure

## Summary
Build the email delivery system: Swoosh adapter for Resend/Postmark, HTML email templates, registration confirmation flow, password reset flow, and the `EmailDeliveryJob` Oban worker that respects user notification preferences.

## User Stories
US-14.1.1 (registration confirmation), US-17.2.3 (password reset), US-17.3.1 (notification preferences), US-7.2 (marketplace sale notification), US-2.5.3 (opt-out confirmation), US-8.1 (GDPR export ready)

## Goal
The platform can send transactional email via Resend or Postmark. Registration requires email confirmation. Password reset works via email link. Marketplace and notification emails respect user preferences.

## Technical Requirements

**`Stacks.Email` context:**
- `Stacks.Email.Mailer` — Swoosh adapter, configured via `EMAIL_PROVIDER` env var
- `send/1` — accepts a Swoosh email struct, delivers via configured provider
- In dev/test: use `Swoosh.Adapters.Local` (no real email sent)

**Email templates (`apps/core/lib/stacks/email/templates/`):**
- `registration_confirmation.html.heex` — "Confirm your email" with token link
- `password_reset.html.heex` — "Reset your password" with token link (24h expiry)
- `marketplace_sale.html.heex` — "Your book has been purchased" (seller) / "Your purchase is confirmed" (buyer)
- `gdpr_export_ready.html.heex` — "Your data export is ready to download"
- `wishlist_availability.html.heex` — "A book on your WishList is now available"
- `opt_out_confirmation.html.heex` — "Your removal request has been received"
- All templates use platform aesthetic: parchment tones, serif typeface, warm palette

**Registration email confirmation:**
- On register: generate confirmation token (signed, 48h expiry), send confirmation email
- `StacksWeb.EmailVerificationController.confirm/2` — `GET /api/auth/confirm/:token`
- Account is created but flagged `email_confirmed = false` until confirmed
- Config flag: `REQUIRE_EMAIL_CONFIRMATION` (true in production, false in dev/test)
- New column: `users.email_confirmed BOOLEAN DEFAULT false`, `users.email_confirmation_token TEXT NULL`

**Password reset:**
- `POST /api/auth/forgot-password` — generates reset token, sends email. Always returns 200 (no email enumeration).
- `POST /api/auth/reset-password` — accepts token + new password. Token expires after 24h.
- New columns: `users.password_reset_token TEXT NULL`, `users.password_reset_sent_at TIMESTAMPTZ NULL`

**`Stacks.Workers.EmailDeliveryJob` (Oban):**
- Queue: `notifications`, concurrency: 3
- Accepts: `{template, recipient_user_id, params}`
- Checks `users.notify_*` preferences before sending (except ToS changes and registration confirmation)
- Retries with exponential backoff (max 3 attempts)

**Rate limiting:**
- Max 10 emails/user/hour (prevent abuse)
- Max 100 emails/hour total (respect provider limits on free tier)

## Definition of Done
- [ ] Registration sends confirmation email; account inactive until confirmed
- [ ] Password reset flow works (request → email → reset with token)
- [ ] `EmailDeliveryJob` checks notification preferences before sending
- [ ] Templates render correctly (test with `Swoosh.Adapters.Local`)
- [ ] Rate limiting prevents email flooding
- [ ] `REQUIRE_EMAIL_CONFIRMATION=false` bypasses confirmation in dev
- [ ] Migration adds email_confirmed, email_confirmation_token, password_reset_token, password_reset_sent_at to users
- [ ] `mix test` passes
- [ ] No PII in email subject lines

## Dependencies
Issue #043 (users table columns — notification preferences)

## Agent Assignment
elixir-agent

## Progress Notes
