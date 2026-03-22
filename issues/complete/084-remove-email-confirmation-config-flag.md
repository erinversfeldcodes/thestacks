# Issue #084: Remove Email Confirmation Config Flag

## Summary
Remove the `REQUIRE_EMAIL_CONFIRMATION` config flag and make email confirmation always required. The flag exists because email delivery infrastructure isn't fully wired in all environments — once it is, the flag is scaffolding that should be removed.

## User Stories
N/A — infrastructure cleanup.

## Goal
Email confirmation is always enforced. No config flag. Registration always generates a token and sends a confirmation email. Authentication always gates on `email_confirmed`. The flag, its config entries, and the conditional branches are removed.

## Scope Check
- 1 context modified (Accounts)
- 0 new endpoints
- Net negative LOC (removing conditionals)

## Wiring
- [x] This issue is implementation only. No new router wiring needed.

## Prerequisites (must be true before starting)
- [ ] Swoosh Local adapter works in dev with mailbox viewer accessible
- [ ] Preview deployments have SMTP/Resend credentials configured
- [ ] E2E auth tests create users with confirmed email (seeds handle this)

## Technical Requirements
1. Remove `require_email_confirmation` from `config.exs`, `test.exs`, `runtime.exs`
2. Remove `require_email_confirmation?/0` helper from `Accounts`
3. Make `check_email_confirmed/1` unconditional in `authenticate/2`
4. Make `register/1` always generate confirmation token (never auto-confirm)
5. Make `EmailConfirmationHandler` always enqueue (remove flag check)
6. Update `AuthController.register/2` to always return "confirmation_email_sent"
7. Update seeds to set `email_confirmed: true` on seeded users
8. Update E2E auth setup to confirm seeded users

## Definition of Done
- [ ] No references to `require_email_confirmation` in codebase
- [ ] `authenticate/2` always checks `email_confirmed`
- [ ] `register/1` always generates token
- [ ] All tests pass without the flag
- [ ] `just verify` passes

## Dependencies
Issue #073 (email confirmation gate — complete). Email delivery infrastructure must be verified working in all environments.

## Agent Assignment
elixir-agent

## Progress Notes
