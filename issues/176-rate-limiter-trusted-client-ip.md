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

_Compact audit — one plug + tests; app/US layers mostly n/a. Pre-implementation baseline generated 2026-07-09. Green when the limiter keys on the trusted IP and the spoof path is closed by test._

| Layer | Applies? | Happy | Sad **(SECURITY)** |
|-------|----------|-------|--------------------|
| 2 Auth guards / middleware | yes | ✅-target: buckets key on `Fly-Client-IP`; per-client isolation holds | ❌ forged `X-Forwarded-For` no longer resets the counter (same client → still limited) |
| 8 Cache (RateLimiter ETS) | yes | ⚠️ existing bucket check/increment tests pass with the new key | ❌ spoof test: N requests with rotating XFF but same `Fly-Client-IP` → 429 |
| 1,3–7,9–13 | no | n/a — no app-data/US behavior change | n/a |

### Punch list (baseline)
| # | Cell | What's needed | Where |
|---|------|---------------|-------|
| 1 | L2 sad (SECURITY) | `get_ip/1` prefers `Fly-Client-IP`; never first XFF. | `rate_limiter.ex:162-167` |
| 2 | L8 sad (SECURITY) | Test: rotating `X-Forwarded-For` with a fixed `Fly-Client-IP` still hits 429 at the limit (spoof no longer bypasses). | `rate_limiter_test.exs` |
| 3 | L2 happy | Migrate existing per-IP rate-limit tests (`:auth`/`:password_change`) from `X-Forwarded-For` to `Fly-Client-IP`; assert isolation still works. | `auth_controller_test.exs`, `rate_limiter_test.exs` |
| 4 | L8 happy | Local/test fallback to `conn.remote_ip` when `Fly-Client-IP` absent — unchanged behavior covered. | `rate_limiter_test.exs` |

### Verdict
Baseline — limiter is spoofable via first-XFF. Green when keying is on the trusted `Fly-Client-IP`, a spoof test proves rotation no longer bypasses, and existing isolation tests pass on the new key.

## Definition of Done
- [ ] `get_ip/1` keys on `Fly-Client-IP` (trusted), falling back to `conn.remote_ip`; never the client-supplied first `X-Forwarded-For` value
- [ ] Spoof test: rotating `X-Forwarded-For` with a fixed `Fly-Client-IP` is rate-limited (429) at the bucket threshold
- [ ] Existing `:auth`/`:password_change` per-IP isolation tests migrated to `Fly-Client-IP` and passing
- [ ] Local/test fallback (`conn.remote_ip`) preserved
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — applicable cells `✅`; 0 `❌`/`⚠️`. Regenerate as the final step.

## Dependencies
- None. Independent; can land on this branch (feat/124-e2e-auth) or its own. Touches the `:e2e_helper` bucket added in #124 plus the pre-existing `:auth`/`:password_change` buckets.

## Agent Assignment
security-agent.

## Progress Notes
- 2026-07-09: Raised from the #124 PE-gate security review (LOW, pre-existing, project-wide). The `:e2e_helper` bucket is protected primarily by email-domain scoping, so this is defense-in-depth there — but it materially strengthens the real `:auth`/`:password_change` brute-force limits. To be worked on this branch per human direction.
