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
  which carries `EMAIL_PROVIDER=resend` + `RESEND_API_KEY`. So the test process runs with both present.
- `config/runtime.exs:158` (repo-root, runs in ALL envs incl. `:test`): when `EMAIL_PROVIDER == "resend"`
  and `RESEND_API_KEY` is set, it configures `Swoosh.Adapters.Resend`, **overriding**
  `apps/core/config/test.exs:102` (`adapter: Swoosh.Adapters.Test`).
- The factory default recipient is `apps/core/test/support/factory.ex:41`
  (`email: sequence(:email, &"user#{&1}@example.com")`). Resend `422`s `example.com` recipients.
- Deterministic (reproduced across two runs, 5/5). **CI is green** because CI has no local `.env`, so
  `EMAIL_PROVIDER`/`RESEND_API_KEY` are absent → the Test adapter stays configured → no network call.
- Failing tests (all in `apps/core/test/stacks/workers/email_delivery_job_test.exs`):
  marketplace_sale (`:32`), wishlist_availability (`:58`), registration_confirmation, password_reset,
  gdpr_export_ready.
- **Deeper wrinkle:** the delivery tests assert `assert_email_sent(subject: …)`, a Swoosh
  `TestAssertions` macro that reads an in-process mailbox — it ONLY works with `Swoosh.Adapters.Test`.
  So merely fixing the recipient would trade the `422` for an `assert_email_sent` failure under the
  real adapter, and would fire real emails on every `just run mix test`.

## Chosen Approach (owner decision 2026-07-19): hermetic by default, env-var opt-in
1. **`config/runtime.exs:158`** — in `:test`, keep the Test adapter by DEFAULT; only wire
   `Swoosh.Adapters.Resend` when `TEST_EMAIL_RECIPIENT` is ALSO set (explicit real-send opt-in). Leave
   non-test env behaviour unchanged (`EMAIL_PROVIDER=resend` + key → Resend). Net: `just run mix test`
   (which loads `EMAIL_PROVIDER=resend` + key but NOT `TEST_EMAIL_RECIPIENT`) uses the Test adapter →
   green, `assert_email_sent` works, zero real emails.
2. **`email_delivery_job_test.exs`** — the 5 delivery tests read the recipient from
   `System.get_env("TEST_EMAIL_RECIPIENT")`, falling back to the factory default when unset (NOT
   hardcoded). Make the delivery assertion **adapter-aware**: when the configured adapter is
   `Swoosh.Adapters.Test`, assert `assert_email_sent(subject: …)`; when the real adapter is active
   (opt-in), assert only `:ok = perform_job(...)` (a real send to the valid recipient) and skip the
   in-process mailbox assertion. `perform` must return `:ok` in both modes.
3. **`.env.example`** — document `TEST_EMAIL_RECIPIENT` (commented, e.g.
   `# TEST_EMAIL_RECIPIENT=erinversfeld@gmail.com`) as the real-send opt-in for testing the actual
   Resend path. Do **NOT** add it to `.env` — everyday runs stay hermetic.

## Technical Requirements
- Implement the 3 points above. The default (no `TEST_EMAIL_RECIPIENT`) suite must be green AND send
  zero real emails, even with `EMAIL_PROVIDER=resend` + `RESEND_API_KEY` present (the `just run` reality).
- The opt-in path (`TEST_EMAIL_RECIPIENT` set) must exercise the real Resend send to the given
  recipient and still pass (adapter-aware assertion).
- The address value is never hardcoded in a test — it comes from the env var; `.env.example` documents
  it; `.env` does not carry it by default.

## Reviewer Context
- `just` auto-loads `.env` via `set dotenv-load` (justfile:2) — this is why a "test" run picks up real
  secrets. Any test that must stay hermetic cannot assume the Test adapter is active under `just run`.
- The self-review must confirm the change does NOT reintroduce a hardcoded recipient and that a keyless
  run (Test adapter) still passes.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 6 (external service calls — email/Resend) | yes | ✅ hermetic default (Test adapter, 11/0, zero real sends) + real-Resend opt-in via `TEST_EMAIL_RECIPIENT` (adapter=Resend, 11/0); `assert_delivered/1` adapter-aware. `just verify` 0 failures; CI green (no key → Test adapter). |
| 1–5, 7–13 | no | n/a — test-isolation fix, no app-behaviour change |

## Definition of Done
- [x] `just run mix test` is 0 failures locally with `EMAIL_PROVIDER=resend` + `RESEND_API_KEY` present and `TEST_EMAIL_RECIPIENT` UNSET — evidence: `email_delivery_job_test.exs` → `11 tests, 0 failures`, adapter resolved `Swoosh.Adapters.Test`; commit `3c8f355a`
- [x] Default run sends ZERO real emails (Test adapter) — evidence: `config/runtime.exs:169-176` `present?/1` guard keeps Test adapter unless `TEST_EMAIL_RECIPIENT` non-empty; adapter proven `Swoosh.Adapters.Test` for both unset AND empty-string `TEST_EMAIL_RECIPIENT`
- [x] Recipient read from `TEST_EMAIL_RECIPIENT`, not hardcoded — evidence: `email_delivery_job_test.exs` `recipient_opts/0` (`System.get_env("TEST_EMAIL_RECIPIENT")`, factory fallback, `""`→unset)
- [x] Assertion is adapter-aware — evidence: `email_delivery_job_test.exs` `assert_delivered/1` (`assert_email_sent` under Test adapter; `:ok = perform_job` under real Resend)
- [x] Opt-in path works: with `TEST_EMAIL_RECIPIENT` set, the 5 delivery tests exercise the real Resend send and pass — evidence: `TEST_EMAIL_RECIPIENT=delivered@resend.dev` → adapter `Swoosh.Adapters.Resend`, `11 tests, 0 failures` (real HTTP sends)
- [x] `TEST_EMAIL_RECIPIENT` documented (commented) in `.env.example`; NOT added to `.env` — evidence: `.env.example:181` commented; `grep -c TEST_EMAIL_RECIPIENT .env` = 0
- [x] `just verify` passes (0 failures) — evidence: `FINAL_VERIFY_EXIT=0` (elixir 2745/0, elm-review 0, elm-test 867/0, dbt 231/231, credo/dialyzer/proto ✅)
- [x] Test audit (above) GREEN — evidence: L6 cell ✅ below

## Dependencies
None. Discovered during Issue #110 (2B-i regression gate); pre-existing, unrelated to the cost fixture.

## Agent Assignment
elixir-agent

## Progress Notes
- 2026-07-19: Filed from #110's regression gate. Root-caused (justfile dotenv-load + real Resend adapter
  + factory `example.com` default). Fix direction set by owner: env-var recipient (`erinversfeld@gmail.com`
  via `.env`), not hardcoded.
