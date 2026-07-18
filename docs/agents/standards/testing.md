# The Stacks — Testing Standards

> Companion to `docs/agents/standards/code-quality.md`. The full execution-environment matrix and rationale live in `docs/technical-architecture.md` Section 16 — Testing Strategy. Agent-specific testing expectations (Elixir, Elm, Rust, Python, dbt, security) live in each agent spec under `docs/agents/`.

## Philosophy

Tests validate that users can accomplish their goals. Every test traces back to a user story or a system resilience requirement. We test through the stack, not around it.

The lint suite — including format checks for every changed file — runs automatically via the `Stop` Claude Code hook (`.claude/settings.json`), so a passing test run isn't enough on its own: the hook must also exit cleanly before a session can finish.

**A structure-only gate is never completion proof.** A gate that runs on *synthetic, mock, or existence* data — one that seeds its own series (`dashboard-render-gate`), asserts `≥1 series`, checks `displayed ⊆ measured` drift, or confirms "the test exists / the route is wired" — proves the artifact is *well-formed*, never that it *works with real data*. Declaring a deliverable done requires **at least one gate that exercises the real path with real data end-to-end** (a real request through the running stack; a real metric emitted → landed in the store → queried back → rendered). Where a check uses synthetic data, say so and name the companion real-path gate. This is why #248 shipped blank behind a green render-gate: it proved the PromQL parsed, never that a sample arrived. See `docs/agents/standards/completion-bar.md` §1/§8.

---

## The 12 Layers

### 1. Acceptance Tests (per user story)
One test per user story interaction flow. The test walks through the steps described in `docs/user-stories.md` and asserts the user can accomplish their goal.

```elixir
# test/acceptance/us_1_1_1_upload_book_test.exs
describe "US-1.1.1: Upload Photos to Add a Book" do
  test "user uploads a photo and the book appears on the chosen shelf" do
    # 1. Upload 1-3 images
    # 2. Assert vision service is called
    # 3. Assert ISBN is resolved
    # 4. Assert book is created with correct metadata
    # 5. Assert book appears on the chosen shelf
  end
end
```

### 2. Integration Tests (service boundaries)
Test the contract between services. Mock the remote end, assert the local end sends/receives correctly.

### 3. Unit Tests (pure functions)
Test business logic in isolation. No database, no HTTP. Focus on:
- ISBN validation
- Price parsing
- BISAC classification rules
- Event upcasting
- Rate limiter calculations

### 4. Property-Based Tests
```elixir
# Elixir: StreamData
property "ISBN-13 checksum always validates" do
  check all isbn <- isbn13_generator() do
    assert Stacks.Books.ISBN.valid?(isbn)
  end
end
```
```rust
// Rust: proptest
proptest! {
    #[test]
    fn price_parsing_never_panics(s in ".*") {
        let _ = parse_price(&s);  // Should never panic
    }
}
```

**Required when:**
- A function parses, validates, or transforms untrusted input (user input, API payloads, scraped data) → property test that the function never crashes on arbitrary input
- A function has a mathematical invariant (checksum, rounding, conversion) → property test that the invariant holds for all generated inputs
- A codec (encoder/decoder pair) exists → round-trip property test (`decode(encode(x)) == x`)
- A sorting, filtering, or ranking function exists → property test that output satisfies the ordering/filtering contract

**Not required for:**
- CRUD operations with no transformation logic
- Simple pass-through functions or delegations
- View rendering (elm-program-test covers this)

### 5. Contract Tests
Validate API request/response shapes against the Protobuf-generated JSON schemas. Ensures frontend and backend agree on data shapes.

### 6. Chaos / Resilience Tests
Simulate failure conditions:
- Vision service down -> graceful degradation
- Database connection pool exhausted -> 503 with retry-after
- Budget exceeded -> user-friendly message, manual ISBN entry still works
- Partner flood -> rate limiter kicks in
- Event subscriber failure -> event persisted, subscriber retried

### 7. Performance / Load Tests
```javascript
// k6 script
import http from 'k6/http';
export const options = { vus: 50, duration: '30s' };
export default function () {
  http.get('http://localhost:4000/api/books');
}
```

### 8. dbt Data Integrity
```yaml
# dbt schema test
models:
  - name: stg_books
    columns:
      - name: isbn
        tests: [not_null, unique]
      - name: title
        tests: [not_null]
```

**Required when:**
- A new Ecto migration adds or modifies a table → corresponding dbt staging model (`stg_*`) must be created or updated with schema tests (not_null, unique, accepted_values, relationships)
- A new column is added to an existing table → dbt schema test for the column's constraints (nullability, type, valid values)
- A foreign key relationship is added → dbt relationship test (`relationships: {to: ref('stg_other'), field: id}`)
- A new dbt model (staging, intermediate, or mart) is added → schema tests for all columns, plus a `dbt test` run confirming they pass
- An enum or constrained-value column is added → `accepted_values` test matching the Ecto/Protobuf enum definition

**Not required for:**
- Code-only changes with no schema impact
- Changes to indexes or constraints that don't affect column semantics (dbt doesn't test these)

### 9. elm-program-test (Primary frontend testing)
Tests the full Elm app (Model-Update-View) without a browser. Simulates user interactions and asserts on rendered output.

**Required when any of these change:**
- A new page or route is added → program test covering the page's happy path and error states
- An existing page's `update` function gains new `Msg` variants → tests for the new user interactions
- A new API call is introduced → test covering all `RemoteData` states (Loading, Success, Failure)
- Navigation logic changes → test that route transitions work correctly
- A user story interaction flow is implemented → program test simulating the full flow from the user's perspective

**Not required for:**
- Pure CSS/aesthetic changes with no logic impact
- Changes only to shared types or decoders (unit tests cover those)
- Changes to components that are already covered by an existing page-level program test

### 10. Playwright E2E
Real browser tests for concerns elm-program-test can't cover: file uploads, CSS rendering, animations. Minimal — only what requires a real browser.

### 11. Visual Regression (Optional)
Screenshot comparisons for shelf rendering, spine sizing, cork board layout. Separate approval flow. Not blocking CI.

### 12. Security Testing
- SAST: Sobelow, Semgrep (with custom AI safety rules), CodeQL
- DAST: OWASP ZAP, Nuclei
- Dependency: mix deps.audit, npm audit, cargo audit
- Container: Trivy
- Secrets: Gitleaks
- IaC: Checkov, Hadolint
- Fuzzing: cargo-fuzz, Atheris

---

## Execution Environments

The 12 layers run across four execution contexts (see `docs/technical-architecture.md` Section 16 — Testing Strategy). The same test code targets all four; what changes is which services are real and which are mocked.

| Environment | `TEST_TARGET` | Mocks | Use When |
|-------------|---------------|-------|----------|
| Fully local (offline) | `local` (default) | All external services mocked | Day-to-day development, offline |
| Local -> deployed | `deployed` + `BASE_URL=…` | None — hits a deployed dev stack | Validating real integrations |
| CI | `local` (default) | All external services mocked | Pull request checks |
| CI -> preview | `deployed` + `BASE_URL=…` | None — hits the preview deployment | Pre-production validation |

### Mock Wiring
The default `MIX_ENV=test` configuration wires the mock client; deployed runs are driven by the `TEST_TARGET=deployed` / `BASE_URL` envelope checked in `scripts/test-deployed.sh`.
```elixir
# apps/core/config/test.exs
config :core, :vision_client, Stacks.AI.MockClient
```

Playwright reads `BASE_URL` directly in `e2e/playwright.config.ts` — when set, it points the browser at the deployed stack and bumps the per-step timeout to 90 s for cold-start tolerance.

---

## Test Commands (just)

```bash
just test              # All local tests (test-elixir + test-elm + test-rust + test-python + test-dbt)
just test-elixir       # scripts/test-elixir.sh — runs `mix coveralls` from apps/core/
just test-elm          # scripts/test-elm.sh — elm-test (uses avh4/elm-program-test)
just test-rust         # scripts/test-rust.sh — cargo test
just test-python       # scripts/test-python.sh — pytest
just test-e2e          # Playwright against a local `just dev` stack
just test-e2e-ci       # scripts/test-e2e.sh — Playwright with service lifecycle management
just test-dbt          # scripts/test-dbt.sh — dbt run + test (staging layer)
just test-security     # all security scans
just test-deployed     # scripts/test-deployed.sh — requires TEST_TARGET=deployed

# Deployed targeting (preview/dev stack)
TEST_TARGET=deployed BASE_URL=https://stacks-core-preview-…fly.dev just test-deployed
E2E_SERVICES=none BASE_URL=https://stacks-core-preview-…fly.dev just test-e2e-ci
```

---

## Coverage Requirements

Line coverage is enforced by `excoveralls` — `test_coverage: [tool: ExCoveralls, minimum_coverage: 80]` is set in `apps/core/mix.exs`, and `mix coveralls` must be run from `apps/core/` (excoveralls is only declared in that mix.exs, not at the umbrella root). The threshold is configuration, not a CLI flag.

| Layer | Minimum | Notes |
|-------|---------|-------|
| Acceptance | 100% of user stories | Every US-X.Y.Z has a test under `apps/core/test/acceptance/` |
| Unit | 80% line coverage | Enforced by `mix coveralls` (`apps/core/mix.exs`); focus on business logic, not boilerplate |
| Integration | Every service boundary | Phoenix <-> Vision, Phoenix <-> Scraper, Phoenix <-> Open Library |
| Contract | Every API endpoint | Request + response shape validation |
| Property-based | Every parser, validator, codec, and invariant | Untrusted input never crashes. Round-trips hold. |
| dbt | Every table and column in the warehouse | Schema tests for all staging models. Relationship tests for all FKs. |
| elm-program-test | Every page with user interactions | New page = new program test. New Msg variant = new test case. |
| Playwright E2E | Flows requiring real browser | File uploads, CSS rendering, animations only |
| Chaos | Every scenario in the resilience matrix | See technical-architecture.md section 18 |

---

## Test Naming Convention

Elixir tests live under `apps/core/test/` mirroring the context tree (`stacks/`, `stacks_web/`); Playwright specs live at the repo-top `e2e/tests/`; load scripts live alongside the suites that drive them.

```
apps/core/test/
├── acceptance/                       # US-X.Y.Z tests
│   └── us_1_1_1_upload_book_test.exs
├── stacks/                           # Context unit + integration tests
│   ├── books_test.exs
│   ├── accounts_property_test.exs    # property-based tests live next to the module
│   └── …
├── stacks_web/                       # Controller / Phoenix-layer tests
├── support/                          # ConnCase, DataCase, Factory, fakes
│   ├── conn_case.ex
│   ├── data_case.ex
│   └── factory.ex
└── test_helper.exs

e2e/                                  # Playwright (repo-top, not under test/)
├── playwright.config.ts
└── tests/
    ├── upload.spec.ts
    ├── upload-pipeline.spec.ts
    └── …
```

### Image Fixtures
End-to-end and vision tests share image fixtures at the repo-top `images/` directory: `barcode_isbn_clean.jpg`, `not_a_book.jpg`, `screenshot_mildly_obscured.jpg`, `screenshot_mixed_text.jpg`, `screenshot_image_reversed.jpg`, `screenshot_image_reversed_and_cut_off.jpg`. Reuse these — do not commit new sample photos without first checking they aren't already represented.

### Factories
`Stacks.Factory` (`apps/core/test/support/factory.ex`, built on `ExMachina.Ecto`) is the single source of test data. Use `insert(:bookshelf, …)` — **never** `:shelf` — and place books with `insert(:placement, bookshelf: bookshelf, …)`, not `shelf:`. A "bookshelf" is a named virtual collection (library, antilibrary, wishlist, reading_pile, looking_for_home); a "shelf" is a physical horizontal row within one and is a distinct schema.

---

## Mandatory Testing Protocol

**Every code change MUST be accompanied by tests.**

1. New feature -> acceptance test + unit tests for new logic
2. Bug fix -> regression test that reproduces the bug first
3. Refactor -> existing tests must still pass (no new tests needed unless behaviour changed)
4. New API endpoint -> contract test + integration test
5. New Oban worker -> unit test for the worker + chaos test for failure mode
6. New proto schema -> contract test for generated types
7. New or modified Elm page/route -> elm-program-test covering user interaction flows (see Layer 9)
8. New Msg variant or API call in Elm -> program test case for the new interaction path
9. New parser, validator, or codec -> property-based test proving it handles arbitrary input (see Layer 4)
10. New or modified Ecto migration -> dbt staging model + schema tests for affected tables/columns (see Layer 8)
