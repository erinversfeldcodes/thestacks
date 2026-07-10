# Issue #176: Rate limiter keys on spoofable X-Forwarded-For — use the trusted Fly client IP

## Summary
`StacksWeb.Plugs.RateLimiter` keys every per-IP bucket on the **first** `X-Forwarded-For` value (`get_ip/1`, `apps/core/lib/stacks_web/plugs/rate_limiter.ex:162-167`). Behind Fly's proxy that value is client-supplied and trivially rotated, so an attacker can bypass **all** IP-based rate limits by sending a fresh `X-Forwarded-For` per request. This weakens the real brute-force protections — `:auth` (login/register, 60/60s) and `:password_change` (20/60s) — not just the test-only `:e2e_helper` bucket. **(SECURITY)**

## User Stories
None directly — hardening of the auth/abuse-protection surface (US-14.x login/register brute-force resistance).

## Goal
Rate-limit buckets are keyed on the **trusted** client IP that Fly injects, so the per-IP limits (`:auth`, `:password_change`, `:public`, `:admin`, `:e2e_helper`) actually bound a single client and cannot be bypassed by forging `X-Forwarded-For`. Local/test behaviour (no Fly proxy) is preserved.

## Scope Check
- One function (`get_ip/1`) in one plug + its tests. < 100 LOC. Single concern. No split.

## Wiring
- [x] Implementation only (middleware). No router/UI wiring change; the plug is already applied to the buckets.

## Technical Requirements
1. **Key on the trusted client IP.** On Fly, the real client IP is exposed via the `Fly-Client-IP` header (Fly sets it at the edge; it cannot be spoofed by the client because Fly overwrites it). Prefer that. Do **not** trust the first `X-Forwarded-For` value.
   - Precedence: `Fly-Client-IP` header → else `conn.remote_ip` (which, behind Fly's private 6PN, is the proxy — acceptable fallback only when the header is absent) → never the client-supplied first XFF hop.
   - If `X-Forwarded-For` must be used at all, use the **last** appended hop (the one Fly adds), not the first — but `Fly-Client-IP` is the clean signal and should be primary.
2. **Preserve local/test behaviour.** With no `Fly-Client-IP` header (local dev, ExUnit conns), fall back to `conn.remote_ip`. Existing tests that assert per-IP isolation set the source IP — update them to set `Fly-Client-IP` (or the fallback) so the buckets still isolate by test IP.
3. Applies to every bucket routed through `get_ip/1`: `:auth`, `:password_change`, `:public`, `:admin`, `:e2e_helper`.

## Reviewer Context
- Surfaced by the #124 PE-gate security review of the `:e2e_helper` bucket; it is a **pre-existing, project-wide** weakness, not a #124 regression — but it degrades the *real* auth brute-force limits, so it is security-relevant.
- Fly runs the app behind its proxy over private 6PN, so `conn.remote_ip` is the proxy, not the client — which is exactly why a header is needed; the fix is to use the *trusted* header (`Fly-Client-IP`) rather than the *spoofable* one (`X-Forwarded-For` first value).
- The `RateLimiter` fails **open** if the ETS table is unavailable (`rate_limiter.ex:91-96`) — out of scope here, noted only so it isn't reintroduced as a concern.
- Existing tests use synthetic IPs like `10.99.1.1` / `10.99.1.2` via `X-Forwarded-For` (see `auth_controller_test.exs` rate-limiting describe) — those will need to move to `Fly-Client-IP`.

## Test Audit

_Compact audit — one plug + tests; app/US layers mostly n/a. Baseline generated 2026-07-09; regenerated GREEN 2026-07-10 after implementation._

| Layer | Applies? | Happy | Sad **(SECURITY)** |
|-------|----------|-------|--------------------|
| 2 Auth guards / middleware | yes | ✅ buckets key on `Fly-Client-IP`; per-client isolation holds (unit + `:api`-pipeline integration test) | ✅ forged/rotating `X-Forwarded-For` no longer resets the counter — same client still limited (mutation-verified) |
| 8 Cache (RateLimiter ETS) | yes | ✅ bucket check/increment works on the new key; fallback to `conn.remote_ip` covered | ✅ spoof test: N requests with rotating XFF + fixed `Fly-Client-IP` → 429, for both `:auth` and `:password_change` |
| 1,3–7,9–13 | no | n/a — no app-data/US behavior change | n/a |

### Punch list (resolved)
| # | Cell | What's needed | Where | Status |
|---|------|---------------|-------|--------|
| 1 | L2 sad (SECURITY) | `get_ip/1` prefers `Fly-Client-IP`; never first XFF. | `rate_limiter.ex:168-174` | ✅ |
| 2 | L8 sad (SECURITY) | Spoof test: rotating XFF + fixed `Fly-Client-IP` → 429 (`:auth` + `:password_change`). | `rate_limiter_test.exs` | ✅ |
| 3 | L2 happy | Migrate `:auth`/`:password_change` isolation tests to `Fly-Client-IP` + a two-IP `:api`-pipeline isolation test. | `auth_controller_test.exs`, `rate_limiter_test.exs` | ✅ |
| 4 | L8 happy | Local/test fallback to `conn.remote_ip` when `Fly-Client-IP` absent. | `rate_limiter_test.exs` | ✅ |

### Verdict
**GREEN.** `get_ip/1` keys on the trusted `Fly-Client-IP` (fallback `conn.remote_ip`), never first XFF; rotating-XFF spoof is closed for `:auth` and `:password_change` (mutation-verified — reverting to XFF flips the security tests RED); isolation proven at the unit and `:api`-pipeline layers. 52/0 in the two suites; `just verify` exit 0 (2264 elixir tests). Deploy-preview: app booted on the new limiter, 194 E2E passed through it (the 1 failure was an orthogonal vision test). elixir-reviewer APPROVED; PE GREEN.

## Definition of Done
- [x] `get_ip/1` keys on `Fly-Client-IP` (trusted), falling back to `conn.remote_ip`; never the client-supplied first `X-Forwarded-For` value
- [x] Spoof test: rotating `X-Forwarded-For` with a fixed `Fly-Client-IP` is rate-limited (429) at the bucket threshold
- [x] Existing `:auth`/`:password_change` per-IP isolation tests migrated to `Fly-Client-IP` and passing
- [x] Local/test fallback (`conn.remote_ip`) preserved
- [x] `just verify` passes
- [x] **Test audit (embedded above) is GREEN** — applicable cells `✅`; 0 `❌`/`⚠️`. Regenerate as the final step.

## Dependencies
- None. Independent; can land on this branch (feat/124-e2e-auth) or its own. Touches the `:e2e_helper` bucket added in #124 plus the pre-existing `:auth`/`:password_change` buckets.

## Agent Assignment
security-agent.

## Progress Notes
- 2026-07-09: Raised from the #124 PE-gate security review (LOW, pre-existing, project-wide). The `:e2e_helper` bucket is protected primarily by email-domain scoping, so this is defense-in-depth there — but it materially strengthens the real `:auth`/`:password_change` brute-force limits. To be worked on this branch per human direction.
- 2026-07-10: Implemented via orchestrator (security-agent). `get_ip/1` now keys on the trusted `fly-client-ip` header (fallback `conn.remote_ip`), never first XFF. TDD (RED→GREEN); testing-coordinator mutation-verified + flagged `:password_change` keying MISSING and the auth_controller migration WEAK → both closed (added `:password_change` spoof unit test + two-`fly-client-ip` `:api`-pipeline integration test). Gates: `just verify` exit 0 (2264 elixir tests); 52/0 in the two suites; 2B-iii deploy succeeded (Fly recovered) — 194 E2E passed through the deployed limiter, 1 orthogonal vision-test failure. elixir-reviewer APPROVED; PE GREEN (no P0/P1). Built on branch `176-…` off `feat/124-e2e-auth`. Follow-ups flagged by all three reviewers: `AuthController.get_ip/1` (audit-log IP) has the identical XFF-trust weakness (P2, separate issue); orthogonal vision E2E flake (`upload.spec.ts:352`).
