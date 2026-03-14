# The Stacks — Testing Standards

## Philosophy

Tests validate that users can accomplish their goals. Every test traces back to a user story or a system resilience requirement. We test through the stack, not around it.

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

| Environment | `TEST_TARGET` | Mocks | Use When |
|-------------|---------------|-------|----------|
| Fully local | `local` | All external services mocked | Day-to-day development, offline |
| Local -> dev | `dev` | None — hits real services | Validating real integrations |
| CI | `ci` | All external services mocked | Pull request checks |
| CI -> preview | `preview` | None — hits real services | Pre-production validation |

### Mock Wiring
```elixir
# config/test.exs
config :stacks, :vision_client,
  if(System.get_env("TEST_TARGET") in ["dev", "preview"],
    do: Stacks.Vision.HTTPClient,
    else: Stacks.Vision.MockClient
  )
```

---

## Test Commands (just)

```bash
just test              # All local tests
just test-elixir       # mix test
just test-elm          # elm-test + elm-program-test
just test-rust         # cargo test
just test-python       # pytest
just test-e2e          # playwright
just test-load         # k6
just test-dbt          # dbt test
just test-security     # all security scans
just test-chaos        # chaos scenarios

# With environment targeting
TEST_TARGET=dev just test
TEST_TARGET=preview just test
```

---

## Coverage Requirements

| Layer | Minimum | Notes |
|-------|---------|-------|
| Acceptance | 100% of user stories | Every US-X.Y.Z has a test |
| Unit | 80% line coverage | Focus on business logic, not boilerplate |
| Integration | Every service boundary | Phoenix <-> Vision, Phoenix <-> Scraper, Phoenix <-> Open Library |
| Contract | Every API endpoint | Request + response shape validation |
| Property-based | Every parser, validator, codec, and invariant | Untrusted input never crashes. Round-trips hold. |
| dbt | Every table and column in the warehouse | Schema tests for all staging models. Relationship tests for all FKs. |
| elm-program-test | Every page with user interactions | New page = new program test. New Msg variant = new test case. |
| Playwright E2E | Flows requiring real browser | File uploads, CSS rendering, animations only |
| Chaos | Every scenario in the resilience matrix | See technical-architecture.md section 18 |

---

## Test Naming Convention

```
test/
├── acceptance/           # US-X.Y.Z tests
│   ├── us_1_1_1_upload_book_test.exs
│   └── us_9_2_1_push_inventory_test.exs
├── integration/          # Service boundary tests
│   ├── vision_client_test.exs
│   └── partner_api_test.exs
├── unit/                 # Pure function tests
│   ├── isbn_test.exs
│   └── price_parser_test.exs
├── chaos/                # Resilience scenarios
│   ├── vision_outage_test.exs
│   └── db_stress_test.exs
├── load/                 # k6 scripts
│   └── book_detail.js
└── e2e/                  # Playwright
    └── upload_flow.spec.ts
```

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
