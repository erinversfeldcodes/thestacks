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

#### Vacuous assertion guards (banned — Issue #275)
Never wrap an E2E assertion in a presence guard on its own target:

```ts
// ✗ BANNED — passes when the element is ABSENT, so it can never fail
if ((await locator.count()) > 0) {
  await expect(locator).toBeVisible();
}
test.skip((await addButton.count()) === 0, "no button"); // a skip is not a pass
test.skip(status === 502, "preview OOM");                 // fail-open on a server error
```

The `status === 5xx` variant is the same defect: a skip that fires on a server
error makes the test unable to fail. Never swallow a 5xx — assert the real
expectation, and where the server documents back-pressure (Issue #166: the
Argon2 path returns **503 + Retry-After**), honour that contract with a bounded
retry (`retryOn503` in `settings.spec.ts`), then assert. Prefer `assertSeedOrSkip`
(`helpers.ts`) over a bare `test.skip` for seed-data preconditions: it hard-fails
under `E2E_EXPECT_FULL_SEEDS=1` (preview/CI) while still skipping loudly on
prod-shaped targets.

Such a guard reports green when a regression removes the element entirely, and
can even conceal a wrong selector (a test that was never correct). Instead:

- **Vestigial guard** (the element is always there given deterministic seed
  data) → delete the guard and assert unconditionally. Make the data
  deterministic with a seed/setup helper (`ensureBookOnShelf`, `mintSession`,
  `assertSeedOrSkip`) if it is not.
- **Genuine either/or** (mutually-exclusive terminal states where *every* branch
  still asserts something) → keep the conditional, but add a marker comment on
  the guard line or the line directly above it, stating why it is optional:

```ts
// vacuous-guard-check: allow — genuine either/or; the else branch asserts the verify view.
if ((await identified.count()) > 0) { /* … */ } else { /* … asserts … */ }
```

Enforced mechanically by `scripts/check-e2e-vacuous-guards.sh`, wired into
`scripts/lint-elm.sh` (the `just ci` elm group and the CI lint-elm job) and as a
pre-flight in `scripts/test-e2e.sh`. Every de-guarded assertion must be proven
non-vacuous — demonstrate it FAILS when its target selector is broken.

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

| Environment | Selected by | Mocks | Use When |
|-------------|-------------|-------|----------|
| Fully local (offline) | `MIX_ENV=test`, no `BASE_URL` | All external services mocked | Day-to-day development, offline |
| Local -> deployed | `BASE_URL=…` (+ `DATABASE_URL`) | None — hits a deployed dev stack | Validating real integrations |
| CI | `MIX_ENV=test`, no `BASE_URL` | All external services mocked | Pull request checks |
| CI -> preview | `BASE_URL=…` + `E2E_EXPECT_*=1` | None — hits the preview deployment | Pre-production validation |

There is no single "which environment am I in" variable, and no test-harness
module that reads one. Mock-vs-real is decided at config load by `MIX_ENV`;
local-vs-deployed is decided per runner by whether `BASE_URL` is set.

### Mock Wiring
`MIX_ENV=test` loads `apps/core/config/test.exs`, and that file *is* the mock
roster — every external seam is swapped there, not selected at runtime:

```elixir
# apps/core/config/test.exs
config :core, :vision_client, Stacks.AI.MockClient
config :core, :isbn_http_client, Stacks.Books.MockHttpClient
config :core, :scraper_client, Stacks.Enrichment.MockScraperClient
config :core, :storage, Stacks.Storage.Mock
config :core, :geocoder, Stacks.Geocoding.Mock
# …plus Brave/SearXNG/Together, the RSS fetcher, the dbt runner, and the
# Prometheus client. `scripts/check-outbound-test-default.sh` gates the set.
```

Nothing un-mocks these in-process. A run that must hit real infrastructure
targets a *deployed* stack instead, which is what `BASE_URL` selects.

### Deployed Targeting
`BASE_URL` is read in two places, and in both it is the real switch:

- `e2e/playwright.config.ts` — `baseURL` falls back to `http://localhost:4000`;
  when `BASE_URL` is set the browser drives the deployed stack and the per-step
  timeout goes to 90 s for cold-start tolerance.
- The `@moduletag :deployed_only` ExUnit modules — excluded by default in
  `test_helper.exs`, and each guards on `System.get_env("BASE_URL")`, skipping
  itself when unset. `scripts/test-deployed.sh` therefore *requires* both
  `BASE_URL` and `DATABASE_URL`: without them the live-API modules skip and the
  run still reports green.

### Hardening Conditionals in CI
Specs that legitimately skip on a missing precondition locally must not stay
skippable where the precondition is guaranteed. The `E2E_EXPECT_*` flags flip
those skips into hard failures, and CI sets them:

| Flag | Turns into a failure |
|------|----------------------|
| `E2E_EXPECT_FULL_SEEDS=1` | `assertSeedOrSkip` skipping for insufficient seed data |
| `E2E_EXPECT_LIVE_METRICS=1` | the transparency spec skipping its frontend-render guarantee |
| `E2E_EXPECT_RATE_LIMITING=1` | the rate-limit spec skipping when limiting looks disabled |

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
just test-deployed     # scripts/test-deployed.sh — requires DATABASE_URL + BASE_URL

# Deployed targeting (preview/dev stack)
DATABASE_URL=postgres://… BASE_URL=https://stacks-core-preview-…fly.dev just test-deployed
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

## Negative Assertions — Anchor on `data-testid`, Never on Prose

An assertion that something is **absent** is the easiest kind to write and the easiest kind to get
silently wrong. `Selector.text` matches on a **substring**, which gives two failure modes:

| Shape | What happens | Example that shipped |
|---|---|---|
| The text appears **nowhere** in `frontend/src/` | The assertion can **never fail** — it matches nothing, forever | `hasNot [ Selector.text "Add shelf" ]` while the button says **"Add a shelf"**. A read-only-view SECURITY guarantee, disarmed by a one-word copy edit, passing for months |
| The text is a **strict substring** of other rendered copy | The selector binds to the **wrong element**, so the assertion tests something else | `hasNot [ Selector.text "Approve" ]` also matched the **"Approved"** filter tab |

Both were found the hard way, and neither was catchable by reading the test — they read perfectly.

**The rule:**

- **Guarding an affordance** (a button, a link, a panel is absent) → anchor on `data-testid` via
  `Util.TestId.testId`. Copy changes; testids do not, and that is the whole point.
- **Asserting specific copy** (an error message must not appear) → prose is legitimate, but pair it
  with a **positive** assertion elsewhere that the same literal *does* render in the sibling state. A
  literal asserted only negatively is a literal nobody notices going stale.
- **Deliberately asserting text stays deleted** → fine, and it *will* match nothing by design. Record
  it in the allowlist so the intent is explicit rather than inferred.

**Enforced by** `scripts/check-prose-assertions.sh`, which runs inside `just lint-elm` (and therefore
`just ci`). It flags both shapes above and carries a reason-bearing allowlist keyed on **file + text**
— not `file:line`, which rots the moment anyone adds a comment.

⚠️ **The check has no view scope, and says so.** It compares against every literal in
`frontend/src/`, but a collision only bites when both strings can render in the *view under test* —
`MainNavTest` renders `Main.viewNav` alone, so a clash with a different page's copy is inert. It
deliberately over-reports; the allowlist is where the judgement lives. Treat a finding as a prompt to
look, not a proof of a bug.

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
