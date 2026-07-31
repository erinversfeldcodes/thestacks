# Issue #176 — Complete

**Issue**: #176 — Rate limiter keys on spoofable X-Forwarded-For → use the trusted Fly client IP
**Branch**: `176-rate-limiter-trusted-client-ip` (off `feat/124-e2e-auth`)
**Commits**: `59bb231` (rate limiter) · `a5ede7b` (audit-log IP) · `525fb99` (live-stack validation)
· skill/plan docs commit · (`de4aae5` skills+template rode along)
**Completed**: 2026-07-10
**Agent**: security-agent

## What shipped
`get_ip/1` in both `StacksWeb.Plugs.RateLimiter` and `StacksWeb.AuthController` now key on the
**trusted `fly-client-ip` header** (fallback `conn.remote_ip`), never the client-supplied first
`x-forwarded-for`. This closes an IP-based rate-limit bypass (rotating XFF reset every per-IP
bucket: `:auth`, `:password_change`, `:public`, `:admin`, `:e2e_helper`) and an audit-log provenance
spoof (a forged XFF was stamped into `user.registered`/`user.login` events).

## Coverage — local + live-stack (the key outcome)
- **Local:** `rate_limiter_test.exs` (spoof / isolation / XFF-not-trusted / fallback / `:password_change`,
  mutation-verified) + `auth_controller_test.exs` (`:api`-pipeline two-IP isolation + audit-IP tests).
  52+ tests, `just verify` exit 0 (2264 Elixir tests).
- **Live-stack (verified green against a real Fly-fronted preview):**
  - `e2e/tests/rate-limit.spec.ts` (isolated `ratelimit` Playwright project, runs last) — brute-force
    login flood → 429; rotating `X-Forwarded-For` → still 429. B1 proven in production topology.
  - `apps/core/test/stacks_web/audit_ip_deployed_test.exs` (`:deployed_only`) — one register through
    real Fly with a spoofed XFF → the recorded `audit.audit_log` provenance IP (`c870dc47…`) is NOT
    `sha256("203.0.113.99")` (`4486f606…`). B2 proven in production topology.
  The local tests set `fly-client-ip` by hand (impossible on real Fly); these live-stack tests prove
  Fly actually injects the trusted IP and the app keys on it end-to-end.

## Gate record
- 2A-iv DoD + testing-coordinator: PASS (after closing `:password_change` MISSING + auth_controller WEAK).
- 2B-i: `just verify` exit 0 · 2B-ii spec coverage PASS · 2B-iia skip (no DB migration) ·
  2B-iii deploy-preview: deploy succeeded, 194+ E2E passed through the limiter (lone failure was an
  orthogonal vision test).
- 2C elixir-reviewer: APPROVED · 2F Principal Engineer: GREEN (no P0/P1).
- Scope expansion (human-directed): `AuthController.get_ip/1` audit-IP fix (the class all 3 reviewers flagged).
- Live-stack validation pass (human-directed): both tests green on a real preview.

Revision cycles: 2 (TC gaps; interpolation-analogue) + scope expansion + live-stack pass.

## Deferred / not filed (per human)
- Vision E2E flake (`upload.spec.ts:352` "Train to Crystal City") — orthogonal, not filed.
- Fly release-command machine timeout (from #177) — still unfiled; watch item.
- Deployed-test Repo ergonomics (Core.Repo localhost pin) — candidate small follow-up; lessons folded
  into the `write-validation-test` skill for now.

## Notes
- Built on `feat/124-e2e-auth`; merged back into it.
- This issue also drove the new `create-issue` / `scope-request` / `write-validation-test` skills +
  the `issues/TEMPLATE.md` Test Audit section, and became their first dogfood.
