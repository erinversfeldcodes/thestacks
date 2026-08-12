# ADR 012: Behaviour + Process Dictionary Mocks over Mox

**Status:** Accepted
**Date:** 2026-03-20
**Deciders:** Platform owner
**Technical area:** Testing strategy, external client abstraction

---

## Context

The Stacks has seven external service clients that must be swappable for testing:

| Client | External Service | Introduced |
|--------|-----------------|-----------|
| `Stacks.AI.Client` | Modal vision sidecar (GPU) | Wave A |
| `Stacks.Books.HttpClient` | Open Library / Google Books | Wave A |
| `Stacks.Enrichment.ScraperClient` | Rust price scraper | Wave C |
| `Stacks.Discovery.BraveClient` | Brave Search API | Wave C |
| `Stacks.Discovery.SearxngClient` | Self-hosted SearXNG | Wave C |
| `Stacks.AI.TogetherClient` | Together AI LLM API | Wave C |
| `Stacks.Enrichment.RssFetcher` | RSS feed HTTP fetch | Wave C |

Each needs a test double that:
1. Returns controlled responses per test
2. Supports `async: true` test isolation
3. Does not make real HTTP calls

**Options evaluated:**

| Approach | Isolation | Contract safety | Complexity | Community adoption |
|----------|----------|----------------|-----------|-------------------|
| Mox (behaviour-verified mocks) | Per-test via allowances | Compile-time verification that mock implements behaviour | Medium — requires `Mox.defmock`, setup, expect/verify | High — José Valim's recommended approach |
| Process dictionary mocks | Per-process via `Process.put/get` | Runtime only — mock must manually implement behaviour | Low — simple module with `put_response/1` | Medium — common in Phoenix projects |
| Bypass (HTTP-level mocking) | Per-port via `Bypass.open` | None — mocks at HTTP layer, not behaviour layer | Medium — requires port management | Medium — good for integration tests |
| Req test adapters | Per-request via adapter config | None | Low | Emerging |

---

## Decision

**Use behaviour modules with process dictionary mocks, wired via `Application.get_env`.**

Each external client follows a three-file pattern:

```
lib/stacks/discovery/brave_client_behaviour.ex           # @callback declarations
lib/stacks/discovery/brave_client.ex                     # Real HTTP implementation
test/support/mocks/discovery/mock_brave_client.ex        # Process dictionary mock
```

**Amended 2026-07-30 (Issue #327):** mocks live under `apps/core/test/support/mocks/`,
not `lib/`. `mix.exs` puts `test/support` on the `:test` elixirc path only, so no mock
compiles into the dev or prod release artifact. Correspondingly, `config.exs` names only
real clients — every mock binding lives in `test.exs`.

Wiring:
```elixir
# config.exs (dev/prod) — real clients only
config :core, :brave_client, Stacks.Discovery.BraveClient

# test.exs — the only place a mock is named
config :core, :brave_client, Stacks.Discovery.MockBraveClient

# In production code:
defp brave_client, do: Application.get_env(:core, :brave_client, Stacks.Discovery.BraveClient)
```

Mock usage in tests:
```elixir
MockBraveClient.put_response({:ok, [%{title: "Result", url: "https://...", description: "..."}]})
# ... exercise the code under test ...
```

**Why not Mox:**

1. **Single implementer.** Mox's compile-time contract verification is most valuable when multiple developers might drift the mock from the behaviour. With a single implementer, the behaviour and mock are always edited together.

2. **Simpler test setup.** Mox requires `Mox.defmock`, `expect`/`stub` calls, and `verify_on_exit!`. Process dictionary mocks require only `put_response/1`. For 7 clients, this simplicity compounds.

3. **async: true works naturally.** Process dictionary is per-process, so each test gets its own isolated mock state without Mox's allowance mechanism.

4. **Behaviours are still defined.** The `@behaviour` declaration on both real and mock modules provides the same compile-time callback checking that Mox would. If a callback signature changes, both implementations fail to compile.

**When to reconsider:**

Switch to Mox if:
- Multiple developers are contributing to the project and mock/behaviour drift becomes a real problem
- We need to verify that specific calls were made with specific arguments (Mox's `expect` is better than process dictionary for this)
- The number of clients exceeds ~10 and the boilerplate of process dictionary mocks becomes burdensome

---

## Consequences

**Positive:**
- Consistent pattern across 7 clients — new contributors can replicate mechanically.
- Tests are simple: `put_response` → exercise → assert. No Mox ceremony.
- `async: true` works everywhere without allowance plumbing.
- Behaviours provide compile-time callback verification on both real and mock implementations.

**Negative:**
- No automatic verification that mocks are called with expected arguments. Tests only assert on outcomes, not on the specific calls made. If a client is called with wrong arguments but happens to return a valid result, the test passes.
- Process dictionary mocks can only return one response per test. Tests that need different responses for sequential calls require more complex mock state (e.g., a list that pops).
- If a behaviour callback is added, the mock silently falls back to a default response instead of failing. Mox would catch this as "unexpected call."

**Relationship to ADR 001 (Modal over Together AI):**
The behaviour pattern enabled us to add the Together AI client alongside the existing Modal vision client without changing the testing infrastructure. Both use the same abstraction pattern, validating the decision to keep clients swappable.
