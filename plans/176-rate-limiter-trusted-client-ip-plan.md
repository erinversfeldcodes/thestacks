# Plan: Rate limiter keys on spoofable X-Forwarded-For — use the trusted Fly client IP
**Issue**: #176
**Created**: 2026-07-09
**Status**: Approved

## Context
`StacksWeb.Plugs.RateLimiter.get_ip/1` keys every per-IP bucket on the **first** `X-Forwarded-For`
value. Behind Fly's proxy that value is client-supplied and trivially rotated, so an attacker can
bypass all IP-based rate limits (`:auth` 60/60s, `:password_change` 20/60s, `:public`, `:admin`,
`:e2e_helper`) by sending a fresh `X-Forwarded-For` per request. Key on the trusted `Fly-Client-IP`
header instead. **(SECURITY)**

## Research Summary
- Current impl (`apps/core/lib/stacks_web/plugs/rate_limiter.ex:162-167`):
  ```elixir
  defp get_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] -> ip                                   # <-- spoofable first hop
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
  ```
- `Fly-Client-IP` is not referenced anywhere yet (greenfield). Fly sets it at the edge and overwrites
  any client-supplied value, so it is the trusted client IP; behind Fly's private 6PN `conn.remote_ip`
  is the *proxy*, which is why a header is needed.
- Tests using `x-forwarded-for` that must migrate to `Fly-Client-IP`:
  `apps/core/test/stacks_web/plugs/rate_limiter_test.exs` (3) and
  `apps/core/test/stacks_web/auth_controller_test.exs` (3, the `:auth`/`:password_change` isolation).
- Out of scope (noted so it isn't reintroduced): the limiter fails **open** if the ETS table is
  unavailable (`rate_limiter.ex:91-96`).

## Approach Options
- **Option A (chosen):** `Fly-Client-IP` → `conn.remote_ip`; drop `X-Forwarded-For` entirely.
  Trusted, purpose-built signal; simplest. Recommended.
- **Option B:** Use the *last* `X-Forwarded-For` hop (the one Fly appends). Works but is fragile
  (depends on hop count / proxy topology); `Fly-Client-IP` is the clean signal. Not recommended.
- **Option C:** Trust `conn.remote_ip` only. Behind Fly's 6PN that is the proxy, collapsing every
  client into one bucket — breaks rate limiting. Rejected.

**Human decision (2026-07-09):** Option A; 2B-iii = attempt once, accept if Fly-blocked.

## Phases

### Phase 1: Key rate-limit buckets on the trusted Fly client IP
**Objective**: `get_ip/1` keys on `Fly-Client-IP` (fallback `conn.remote_ip`), never the client
first `X-Forwarded-For`; the spoof path is closed by test; existing isolation tests migrated.
**Agent(s)**: security-agent
**Steps**:
1. Rewrite `get_ip/1`:
   ```elixir
   defp get_ip(conn) do
     case get_req_header(conn, "fly-client-ip") do
       [ip | _] when ip != "" -> ip
       _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
     end
   end
   ```
   No `X-Forwarded-For` handling remains.
2. Tests (test-first, ExUnit):
   - **Spoof (SECURITY):** N requests with a rotating `X-Forwarded-For` but a *fixed* `Fly-Client-IP`
     → same bucket → 429 at the threshold. Fails on the current impl (rotation dodges the limit).
   - **Migrate** the `:auth`/`:password_change` per-IP isolation tests in `rate_limiter_test.exs`
     and `auth_controller_test.exs` from `X-Forwarded-For` → `Fly-Client-IP`; assert isolation holds.
   - **Local fallback:** no `Fly-Client-IP` header → `conn.remote_ip` (unchanged behaviour).
3. Regenerate the issue's embedded audit to GREEN (final step).
**Test Command**: `cd apps/core && mix test test/stacks_web/plugs/rate_limiter_test.exs test/stacks_web/auth_controller_test.exs`
**DoD Items**:
- [ ] `get_ip/1` keys on `Fly-Client-IP` (trusted), falling back to `conn.remote_ip`; never first XFF
- [ ] Spoof test: rotating `X-Forwarded-For` with a fixed `Fly-Client-IP` is rate-limited (429)
- [ ] Existing `:auth`/`:password_change` per-IP isolation tests migrated to `Fly-Client-IP` and passing
- [ ] Local/test fallback (`conn.remote_ip`) preserved
- [ ] `just verify` passes
- [ ] Test audit (embedded in issue) is GREEN

## Gate Plan
- 2B-i Regression: elixir `mix test` + `just verify`. Required.
- 2B-ii Spec Coverage: orchestrator-built. Required.
- 2B-iia Fresh DB: **skip** — no migration/schema/dbt/`persisted.exs` changes.
- 2B-iii Deploy-Preview + E2E: **attempt once, accept if Fly-blocked** (human) — ships deployed
  Elixir code, but the fix is fully unit-testable and the deploy gate is currently broken by an
  unrelated Fly release-command timeout (blocked #177 twice).
- 2F Principal Engineer: required (final phase; security lens).

## Open Questions
None.

## Integration Handoffs
None — single phase, single domain (security/Elixir). Lands on `feat/124-e2e-auth` via merge.
