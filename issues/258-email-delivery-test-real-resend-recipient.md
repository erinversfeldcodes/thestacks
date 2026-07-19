# Issue #258: EmailDeliveryJob tests hit real Resend and 422 on example.com recipients

## Summary
Under `just run mix test` (the mandated toolchain path), `Stacks.Workers.EmailDeliveryJobTest`'s
delivery tests send through the **real Resend adapter** and fail with Resend `422 validation_error`
("Invalid `to` field … use our testing email address instead of domains like `example.com`"). The
factory default recipient is `user{n}@example.com`, which Resend rejects. Make the delivery tests use
a **real, Resend-accepted recipient read from an environment variable** — not a hardcoded address.

## User Stories
None — test-isolation / harness bug.

## Goal
`just run mix test` is fully green locally (0 failures) without disabling real-adapter delivery, and
CI stays green. The 5 `EmailDeliveryJobTest` failures disappear because the recipient is a deliverable
address supplied by the environment.

## Scope Check
- Controllers: 0. Endpoints: 0. Production LOC: ~0 (test-only, possibly a tiny test-support helper). No
  unrelated concerns. Does not split.

## Wiring
Implementation only (test harness) — no router wiring, not user-facing.

## Feature-Completeness Pre-Check
n/a — no user stories (test-isolation/harness bug).

## Root Cause (verified 2026-07-19)
- `justfile:2` — `set dotenv-load` → every `just` command (incl. `just run mix test`) loads `.env`,
  which carries `RESEND_API_KEY`. So the test process runs with the key present.
- With the key present, the mailer resolves to the real Resend adapter, overriding
  `apps/core/config/test.exs:102` (`config :core, Stacks.Email.Mailer, adapter: Swoosh.Adapters.Test`).
- The factory default recipient is `apps/core/test/support/factory.ex:41`
  (`email: sequence(:email, &"user#{&1}@example.com")`). Resend `422`s `example.com` recipients.
- Deterministic (reproduced across two runs, 5/5). **CI is green** because CI has no local `.env`, so
  `RESEND_API_KEY` is absent → the Test adapter stays configured → no network call.
- Failing tests (all in `apps/core/test/stacks/workers/email_delivery_job_test.exs`):
  marketplace_sale (`:32`), wishlist_availability (`:58`), registration_confirmation (`:` bypass),
  password_reset, gdpr_export_ready.

## Technical Requirements
- The delivery tests must send to a **recipient supplied by an env var** (e.g. `TEST_EMAIL_RECIPIENT`),
  whose value in `.env` is `erinversfeld@gmail.com` (the Resend account owner, which Resend accepts).
  **Do not hardcode the address in the test** — read it from the environment; the value lives in `.env`
  (and CI/`.env.example` documentation), not in source.
- When the env var is unset (e.g. a clean checkout with the Test adapter active), the tests must still
  pass — the Test adapter accepts any recipient, so the env-var recipient is only *required* to be a
  real address when a live adapter is in play. Choose a sensible default/fallback so a keyless
  environment (CI) is unaffected.
- Preferred implementation: a small test-support helper (e.g. `Stacks.Factory` override or a
  `test/support` function) that stamps `email:` from `System.get_env("TEST_EMAIL_RECIPIENT")` for the
  delivery tests, rather than editing each `insert(:user, …)` call site. Keep the factory's global
  `example.com` default for the rest of the suite (only the delivery tests need a deliverable address).
- Document `TEST_EMAIL_RECIPIENT` in `.env.example` (or the canonical env doc) with a one-line note.

## Reviewer Context
- `just` auto-loads `.env` via `set dotenv-load` (justfile:2) — this is why a "test" run picks up real
  secrets. Any test that must stay hermetic cannot assume the Test adapter is active under `just run`.
- The self-review must confirm the change does NOT reintroduce a hardcoded recipient and that a keyless
  run (Test adapter) still passes.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 6 (external service calls — email/Resend) | yes | ❌ delivery tests fail against real Resend on `example.com`; needs env-var recipient (→ ✅ when `just run mix test` is 0-failures locally AND CI green) |
| 1–5, 7–13 | no | n/a — test-isolation fix, no app-behaviour change |

## Definition of Done
- [ ] `just run mix test` is 0 failures locally with `RESEND_API_KEY` present — evidence: command→output (`… tests, 0 failures`)
- [ ] Recipient is read from an env var, not hardcoded — evidence: test/support diff showing `System.get_env("TEST_EMAIL_RECIPIENT")`
- [ ] Keyless run (Test adapter / CI) still passes — evidence: run with the var unset → 0 failures
- [ ] `TEST_EMAIL_RECIPIENT` documented in `.env.example` — evidence: diff
- [ ] `just verify` passes — evidence: command→output
- [ ] Test audit (above) GREEN — evidence: regenerated table

## Dependencies
None. Discovered during Issue #110 (2B-i regression gate); pre-existing, unrelated to the cost fixture.

## Agent Assignment
elixir-agent

## Progress Notes
- 2026-07-19: Filed from #110's regression gate. Root-caused (justfile dotenv-load + real Resend adapter
  + factory `example.com` default). Fix direction set by owner: env-var recipient (`erinversfeld@gmail.com`
  via `.env`), not hardcoded.
