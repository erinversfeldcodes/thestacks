# Issue #128: Deployed-Only Test Infrastructure

## Summary
Create infrastructure for running `@tag :deployed_only` tests against deployed stacks, covering dbt mart verification, real HTTP to vision sidecar, R2 storage latency, and Neon query latency.

## User Stories
Cross-cutting — supports all Phase 1 stories that have deployed-only test gaps (US-1.1.1 through US-1.1.8, plus dbt-dependent stories).

## Goal
Tests tagged `@tag :deployed_only` can run against a deployed preview stack via `mix test --only deployed_only`, with `TEST_TARGET=deployed` controlling mock vs real service wiring. CI runs these after successful preview deploy.

## Scope Check
- Does this issue touch more than 3 controllers? No (test infrastructure only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No (test config + CI script changes).
- Does this issue combine unrelated concerns? No (all test infrastructure).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #004 (CI pipeline).

## Technical Requirements

### ExUnit configuration
- Add `ExUnit.configure(exclude: [:deployed_only])` to `test_helper.exs` so deployed-only tests are excluded by default
- `mix test --only deployed_only` includes them explicitly
- `TEST_TARGET=deployed` env var switches mock modules to real clients

### CI integration
- Add a `test-deployed.sh` script that runs `mix test --only deployed_only` against a preview stack
- Runs after `deploy-preview.sh` succeeds in CI
- Requires `DATABASE_URL`, `VISION_SERVICE_URL`, `R2_*` env vars pointing to preview

### Existing deployed-only tests
- 5 tests in `upload_dbt_test.exs` querying `wh.stg_*` views (currently degrade gracefully)
- These should fail properly when `TEST_TARGET=deployed` is set but `dbt run` hasn't been executed

### dbt run in deploy pipeline
- After preview deploy, run `dbt run --target preview` to materialise staging/intermediate/mart views
- Then run `dbt test --target preview` for schema-level assertions
- Then run `mix test --only deployed_only` for Elixir-side mart verification

## Reviewer Context
- `TEST_TARGET` env var is already documented in `docs/technical-architecture.md` section 16 (12-layer test strategy)
- Existing mock/real switching pattern: `Application.get_env(:core, :vision_client)` returns `MockClient` or `Client`
- The `wh` schema only exists after `dbt run` — raw `op.*` tables are always available

## Definition of Done
- [ ] `ExUnit.configure(exclude: [:deployed_only])` in `test_helper.exs`
- [ ] `scripts/test-deployed.sh` runs deployed-only tests against preview
- [ ] CI pipeline runs deployed-only tests after successful preview deploy
- [ ] Existing 5 `@tag :deployed_only` tests in `upload_dbt_test.exs` pass against deployed stack
- [ ] `just verify` passes

## Dependencies
- #004 (CI pipeline — already complete)
- Preview deploy infrastructure (already working)

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
