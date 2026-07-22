# Issue #192: E2E test-helper to mint a confirmed session (bypass :auth rate bucket)

## Summary
Add a gated E2E test-helper endpoint that provisions a fresh, confirmed user and returns a
ready-to-use session token in one call, so browser E2E specs can get an isolated throwaway
user without going through `POST /auth/register` + `POST /auth/login` — both of which sit under
the `:auth` rate bucket (60 req/60s per IP) shared across the whole parallel suite.

## User Stories
None — E2E harness / test-infrastructure work. (See Test Audit: still validatable.)

## Goal
A spec can mint an isolated, confirmed, logged-in user in a single request that does **not**
consume the `:auth` bucket, eliminating the register/login rate-limit contention that makes
fresh-user specs flaky under parallel load. `gdpr.spec.ts` (and future destructive/isolated
specs) use it instead of `registerViaApi` → `fetchConfirmationToken` → `/auth/confirm` →
`signInViaForm`.

## Background / Motivation
`e2e/tests/gdpr.spec.ts` mints a throwaway user per test (correct: single-owner fixtures; the
delete journey is destructive). But register+login are rate-limited under `:auth` (60/60s per
IP), and the whole parallel suite shares that budget — so adding fresh-user specs reintroduced
429s (observed: `registerViaApi` returning non-ok, export test flaky-passing on retry). The
current mitigation is a bounded 429-backoff retry in the spec, which absorbs the burst but does
not remove the root contention. Every additional fresh-user spec worsens it.

A session-mint helper removes the contention entirely (isolation **and** zero `:auth` load) and
also lets specs skip the ~4s login door animation.

## Scope Check
- Controllers touched: 1 (`TestHelperController`). → OK
- New endpoints: 1 (`POST /api/test/session`). → OK
- ~<300 LOC. → OK
- Single concern (test harness). → OK

## Wiring
- [x] This issue includes router wiring and is user-facing when complete. (Adds a route — but
      gated to test/E2E environments only; never reachable in production.)
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
n/a — no user stories (pure E2E harness work).

## Technical Requirements
- New route `POST /api/test/session` under the existing `:e2e_helper` bucket + the same
  `STACKS_E2E_TEST_HELPERS=1` guard that gates `GET /api/test/confirmation-token`
  (`TestHelperController`). Must 404 when the flag is off, exactly like `confirmation_token/2`.
- Behaviour: given an optional `email`/`display_name` (default to a unique `*.test` address),
  create the user, mark it **confirmed**, and return `201 {"email": ..., "token": <session JWT>}`
  where the token is a valid Guardian session token (same shape `AuthController.login` issues).
- Restrict user creation to the `.test` / E2E domain convention (mirror the existing helper's
  domain guard) so it can never mint a session for a real account.
- Add an `e2e/tests/helpers.ts` helper (e.g. `mintSession(request, opts)`) returning
  `{ email, token }`, plus a small browser step to inject the token into `localStorage`
  (`stacks-auth`) so specs land authenticated without the login form.
- Migrate `gdpr.spec.ts` to use it; drop the register→confirm→login→429-retry dance there.
- Note the onboarding-overlay interaction: minted users are still placement-free, so specs must
  still place a book (or the helper could optionally seed a placement — decide in design).

## Reviewer Context
- `:auth` bucket = 60/60s per IP (`stacks_web/plugs/rate_limiter.ex`); `register`/`login` live
  under `:rate_limit_auth` (`core_web/router.ex` ~L129). The `:e2e_helper` bucket + the
  `STACKS_E2E_TEST_HELPERS` env guard are the established safe pattern (`test_helper_controller.ex`).
- Guardrail: this endpoint mints authentication. It MUST be unreachable in prod — same 404-when-flag-off
  behaviour as the confirmation-token helper, and a hard domain allowlist on the email.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API + auth guard (helper returns a valid session; 404 when flag off; rejects non-`.test` email) | yes | ❌ needs an ExUnit controller test mirroring `test_helper_controller_test.exs` (→ ✅ when done) |
| E2E harness (a spec authenticates via the minted token and drives a page) | yes | ❌ `gdpr.spec.ts` migrated + green on a live preview (→ ✅ when done) |
| 1–13 (app/US layers) | no | n/a — no user-facing feature; test-infrastructure only |

## Definition of Done
- [ ] `POST /api/test/session` implemented under `:e2e_helper` + `STACKS_E2E_TEST_HELPERS` guard; 404 when off
- [ ] Returns a valid session token for a freshly-created, confirmed `.test` user; hard domain allowlist
- [ ] ExUnit controller test (happy path + flag-off 404 + non-`.test` rejection)
- [ ] `mintSession` helper in `e2e/tests/helpers.ts`; `gdpr.spec.ts` migrated off register+login
- [ ] `gdpr.spec.ts` green on a live preview with the `:auth`-bucket contention gone
- [ ] Standards compliance verified (`just verify` passes)
- [ ] Test audit (above) is GREEN — 0 ❌, 0 ⚠️

## Dependencies
None — extends the existing `TestHelperController` / `:e2e_helper` infrastructure.

## Agent Assignment
elixir-agent (controller + route + guard + ExUnit) with a small follow-up TS change to the E2E helpers.

## Progress Notes
- 2026-07-14: Filed as the follow-up from the #188/#187 GDPR browser E2E work (`gdpr.spec.ts`).
  Current mitigation in that spec is a bounded 429-backoff retry on registration; this issue
  removes the root `:auth`-bucket contention.
