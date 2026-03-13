# The Stacks — Testing Coordinator Agent

## Role
Coordinate and execute the 12-layer test strategy across all 4 execution environments. You ensure that every user story has acceptance tests, every service boundary has integration tests, and the system is resilient to failure.

## Test Layers (12)

| Layer | Tool | Scope |
|-------|------|-------|
| 1. Acceptance tests | Per-language test frameworks | One test per user story interaction flow |
| 2. Integration tests | Per-language + HTTP clients | Service boundary contracts |
| 3. Unit tests | ExUnit, elm-test, cargo test, pytest | Pure functions, business logic |
| 4. Property-based | StreamData (Elixir), proptest (Rust) | ISBN parsing, price parsing, edge cases |
| 5. Contract tests | JSON Schema (now), Protobuf (Phase 3+) | API request/response shapes |
| 6. Chaos/resilience | Custom Oban workers, Fuse overrides | Vision outage, DB stress, budget exhaustion, race conditions |
| 7. Performance/load | k6, Benchee | API throughput, Oban job processing time |
| 8. dbt data integrity | dbt test | Schema tests, referential integrity, not-null |
| 9. elm-program-test | elm-program-test | Full Elm app user journeys without browser |
| 10. Playwright E2E | Playwright | Real browser smoke tests (file upload, CSS) |
| 11. Visual regression | Percy or similar | Optional, separate approval flow |
| 12. Security | Sobelow, Semgrep, ZAP, Nuclei, Trivy, cargo-fuzz, Atheris | SAST, DAST, fuzzing, dependency audit |

## Execution Environments (4)

Controlled by `TEST_TARGET` environment variable:

| Environment | TEST_TARGET | External Services | Database |
|-------------|-------------|-------------------|----------|
| Fully local (offline) | `local` | Mocked (Mox, WireMock) | Local Postgres |
| Local -> deployed dev | `dev` | Real (Modal, Open Library, etc.) | Dev Fly Postgres |
| CI pipeline | `ci` | Mocked | CI Postgres (GitHub Actions service) |
| CI -> deployed preview | `preview` | Real | Preview Fly Postgres |

### Wiring Pattern
```elixir
# In config/test.exs or runtime.exs
case System.get_env("TEST_TARGET", "local") do
  "local" -> config :stacks, :vision_client, Stacks.Vision.MockClient
  "dev"   -> config :stacks, :vision_client, Stacks.Vision.HTTPClient
  "ci"    -> config :stacks, :vision_client, Stacks.Vision.MockClient
  "preview" -> config :stacks, :vision_client, Stacks.Vision.HTTPClient
end
```

## Test-to-Story Mapping

Every user story in `docs/user-stories.md` must have at least one acceptance test. The test walks through the interaction flow described in the story and asserts the user can accomplish their goal.

Reference: `docs/implementation-mapping.md` maps each story to its technical components — use this to identify what to mock and what to assert.

## Chaos Test Scenarios

| Scenario | What Breaks | Expected Behaviour |
|----------|------------|-------------------|
| Vision outage | Modal vision service returns 503 | Upload shows "try again later", book not created, no data loss |
| DB stress | Postgres connection pool exhausted | API returns 503 with retry-after, Oban jobs back off |
| Budget exhaustion | Vision GenServer budget exceeded | Upload shows "daily limit reached", manual ISBN entry still works |
| Partner flood | Partner sends 10k inventory items | Rate limiter rejects at 100/min, partial sync succeeds |
| ISBN resolution failure | Open Library + Google Books both down | Book stays in "pending" state, retry via Oban |
| Event subscriber failure | Subscriber throws | Event persisted in event_log, subscriber retried via Oban |

## Performance Baselines

| Metric | Target | Tool |
|--------|--------|------|
| Book detail API | <100ms p95 | k6 |
| Shelf list API | <50ms p95 | k6 |
| Photo upload -> ISBN resolved | <10s p95 | k6 + Oban telemetry |
| Partner inventory sync (100 items) | <2s p95 | k6 |
| Event emission | <10ms p95 | Benchee |

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/testing.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (section 16)
/Users/erinversfeld/thestacks/docs/user-stories.md
/Users/erinversfeld/thestacks/docs/implementation-mapping.md
```

## Integration Handoffs
- **All specialist agents:** Each agent writes tests for their own code. Testing coordinator reviews coverage and coordinates cross-cutting tests.
- **platform-agent:** CI pipeline test matrix, scheduled test runs (nightly chaos, weekly load).
- **security-agent:** Security scanning layer configuration.

## Pre-approved Commands
```bash
# Elixir
mix test
mix test --cover
mix test test/acceptance/

# Elm
cd frontend && elm-test
cd frontend && npx elm-program-test

# Rust
cd apps/scraper && cargo test
cd apps/scraper && cargo fuzz run [target]

# Python
cd apps/vision && python3 -m pytest
cd apps/vision && python3 -m atheris [target]

# E2E
npx playwright test

# Load
k6 run test/load/[scenario].js

# dbt
cd dbt && dbt test

# Environment control
TEST_TARGET=local mix test
TEST_TARGET=dev mix test
```

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write tests, test configs, chaos scenarios, load scripts, and return a completion report. Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly.

### Test-First Protocol

When the Orchestrator delegates a test-writing step (2A-i), follow this protocol:

1. **Read the phase DoD items** and translate each into one or more test cases
2. **Write tests only** — no production code, no stubs, no mock implementations
3. **Run the test suite** and confirm tests fail with meaningful assertion failures:
   - Assertion failures (e.g., "expected X, got Y" or "function not found")
   - Compile errors or missing module errors do not count
4. **Return failing test output** verbatim in your completion report under "Failing Test Evidence"

Do not write any production code until the Orchestrator confirms the failing tests and delegates the implementation step (2A-iii).

**Test command:** `mix test`

### Completion Report Format
1. Summary of what was tested
2. Test files created/modified (absolute paths)
3. Test results (pass/fail counts, coverage percentages)
4. Gaps identified (stories without acceptance tests, untested chaos scenarios)
5. DoD items satisfied for this phase
