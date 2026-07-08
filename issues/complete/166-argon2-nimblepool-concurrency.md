# Issue #166: Argon2 concurrency safety via NimblePool

## Summary
Concurrent Argon2 operations (password verify + hash during password change,
or simultaneous logins) can exhaust available memory on constrained machines.
At `m_cost: 16` each Argon2 call allocates ~64 MB; two concurrent calls plus
Phoenix baseline (~100 MB) exceeds 256 MB and produces OOM / 502 responses.

This is exposed on the Fly.io preview machine under E2E test load and is a
latent production risk whenever real concurrent logins or password changes
occur on an instance without headroom.

## User Stories
N/A (platform / reliability).

## Goal
Argon2 operations are serialised through a bounded `NimblePool` worker pool.
When all workers are busy the API returns `503 Service Unavailable` with a
`Retry-After` header rather than OOMing and returning 502. Peak memory is
bounded and predictable regardless of concurrent request volume.

## Scope Check
- One new module: `Stacks.Accounts.ArgonPool` (NimblePool wrapper).
- One context function change: `Stacks.Accounts.verify_password/2` and
  `hash_password/1` delegate through the pool.
- Two controllers indirectly affected: `AuthController` (login),
  `UserSettingsController` (password change).
- Zero DB migrations, zero new endpoints, zero Elm changes.
- ~100-150 LOC of production code.

## Wiring
- [ ] `Stacks.Accounts.ArgonPool` — NimblePool with `pool_size: 2` (tunable via
      application env). Each worker holds no state; `checkout!/execute!` wraps
      the Argon2 call.
- [ ] `Stacks.Accounts.verify_password/2` and `hash_password/1` delegate to pool.
- [ ] When pool is exhausted, return `{:error, :argon2_pool_exhausted}`.
- [ ] `AuthController` and `UserSettingsController` map that error to 503 with
      `Retry-After: 5`.
- [ ] Add `ArgonPool` to the supervision tree in `application.ex`.
- [ ] Unit tests: pool checkout, exhaustion → 503, successful auth still works.

## Technical Requirements

### ArgonPool design
```elixir
defmodule Stacks.Accounts.ArgonPool do
  @moduledoc false
  use NimblePool

  @pool_size Application.compile_env(:core, :argon2_pool_size, 2)

  def child_spec(_opts) do
    NimblePool.child_spec(worker: {__MODULE__, []}, pool_size: @pool_size, name: __MODULE__)
  end

  def run(fun) do
    NimblePool.checkout!(__MODULE__, :checkout, fn _from, nil ->
      result = fun.()
      {result, nil}
    end, _timeout = 10_000)
  catch
    :exit, {:timeout, _} -> {:error, :argon2_pool_exhausted}
  end

  @impl NimblePool
  def init_worker(pool_state), do: {:ok, nil, pool_state}
end
```

### Memory budget at pool_size: 2
- Phoenix baseline: ~100 MB
- 2 concurrent Argon2 ops: 2 × 64 MB = 128 MB
- Total peak: ~228 MB — fits in 256 MB with ~28 MB headroom
- With pool_size: 2, a third request waits up to 10 s then gets 503

### m_cost reference
Current: `Argon2.verify_pass/hash_pwd_salt` uses library default of
`m_cost: 16` (2^16 = 65,536 KiB ≈ 64 MB). Do not lower m_cost as a
workaround — that weakens password security.

## Definition of Done
- [ ] `mix test apps/core/test/stacks/accounts/argon_pool_test.exs` passes
- [ ] `mix test` full suite passes (no regressions)
- [ ] `GET /api/health` still returns 200 under pool exhaustion
- [ ] `POST /api/login` under pool exhaustion returns 503 with `Retry-After: 5`
- [ ] E2E password tests no longer need the 502 graceful-skip guard (remove it)
- [ ] `mix dialyzer` passes

## Progress Notes
- 2026-05-13: Issue filed. E2E password tests carry a graceful-skip for 502
  until this fix lands (see `e2e/tests/settings.spec.ts` password test blocks).
