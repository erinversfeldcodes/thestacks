# Plan: Release-to-main workflow with SLO gate + auto-rollback
**Issue**: #136
**Created**: 2026-04-18
**Status**: Approved

## Context
Merge-to-main needs to deploy core+vision+scraper to prod Fly apps and Modal prod against the existing prod DB, run migrations, then gate release health on SLIs pulled from prom_ex and synthetic probes. On SLI breach within a 10-min window, auto-rollback core (prev Fly image) and vision (prev Modal commit) — core first, per the wire-format ordering documented in `docs/runbooks/vision-service-rollback.md`. Expand–contract migrations are enforced in CI so rollback never requires DB surgery.

## Research Summary
- PromEx already instruments Phoenix, Ecto, Oban, BEAM. Custom metrics exist for vision request duration, fuse melt/blown counters, budget, and platform cost (`apps/core/lib/core_web/telemetry.ex`, `apps/core/lib/core/prom_ex.ex`).
- `/internal/metrics` is exposed but unauthenticated.
- `deploy-stack.sh` (built for Issue #004) handles the mechanics of deploying core + Modal + scraper + SearXNG; this issue builds a production-mode wrapper and adds the gate.
- Squawk runs in CI via `scripts/security-squawk.sh` with `--exclude=require-timeout-settings`; destructive-op rules are currently all permitted.
- Neon PITR (7-day WAL) remains the data-rollback tool. Image + schema rollback is what this workflow handles.

## Approach Options
- **Option A (chosen):** Pull-based SLO gate — CI scrapes `/internal/metrics` + runs synthetic probes in a 10-min loop, computes absolute-threshold SLIs locally, rolls back on breach. Gate emits a JSON artifact summarising observations. — Simpler, no external alerting backend, no schema commitment. Recommended.
- **Option B:** Push to Grafana Cloud with alert-webhook-triggered rollback. — Adds an external hosted dependency; overkill for current scale. Migration is cheap later (estimated 1–2 days) because PromEx output is already Prometheus-native. Deferred.
- **Option C:** Manual gate — deploy, post dashboard links to PR, wait for operator thumbs-up. — Removes the auto-rollback value; not recommended.

## Phases

### Phase 1: Metrics Instrumentation
**Objective**: Add the metrics the SLO gate will read. Lock down the scrape endpoint.
**Agent(s)**: elixir-agent
**Steps**:
1. Add a Phoenix plug that assigns `telemetry_metadata[:route_group]` based on path prefix (auth, catalogue, bookshelves, upload, gdpr, settings, health, metrics). Plug is inserted into the endpoint before Phoenix's dispatcher.
2. Update `CoreWeb.Telemetry` to tag `phoenix.router_dispatch.stop.duration` by `:route_group`.
3. Add `telemetry_poller` periodic measurement that reads `:fuse.ask/2` state for each registered fuse and emits `[:stacks, :fuse, :state]` with `%{state: 0 | 1}` tagged by `:fuse_name`. Define `last_value` metric.
4. Emit `[:stacks, :upload, :terminal]` at every `uploaded_image` status transition to a terminal state (`resolved`, `rejected`, `timeout`). Define counter metric tagged by `:outcome`.
5. Lock down `/internal/metrics` with an authentication plug: accept requests from Fly's private 6PN (`fd00::/8`) OR a `METRICS_SCRAPE_TOKEN` bearer. Reject others with 401. Add the token to `fly secrets set`.
**Test Command**: `mix test apps/core/test/core_web/plugs/ apps/core/test/core_web/telemetry_test.exs apps/core/test/stacks/uploads/`
**DoD Items**:
- [ ] Route-grouping plug emits `:route_group` in telemetry metadata for all API routes, tested per group
- [ ] Fuse state gauge exports a `last_value` series per registered fuse
- [ ] Upload terminal counter increments on `resolved` / `rejected` / `timeout` transitions, tested for each outcome
- [ ] `/internal/metrics` rejects unauthenticated external requests with 401, accepts Fly 6PN + bearer-token requests

### Phase 2: Expand–Contract CI Enforcement
**Objective**: Make breaking schema changes fail CI unless explicitly annotated.
**Agent(s)**: platform-agent (squawk rules, migration linter, schema diff wiring) in parallel with database-agent (migration linter semantics, schema diff generator)
**Steps**:
1. Update `scripts/security-squawk.sh` to enable `ban-drop-column`, `renaming-column`, `renaming-table`, `adding-required-field`. Keep `--exclude=require-timeout-settings` if still needed. (Note: `adding-field-with-default` dropped from scope — false positive on Postgres 11+ where `ADD COLUMN ... DEFAULT` is metadata-only; Neon is PG 15.)
2. Create `scripts/lint-migrations.sh`: parse each migration file in the PR diff for destructive operations (`drop_column`, `drop_table`, `rename`, `modify ... null: false`). If found, require a `@breaking_ok "<reason>"` moduledoc annotation. Exit non-zero if destructive + unannotated.
3. Create a CI step that dumps `structure.sql` before and after running the PR's migrations on a fresh disposable DB, then greps the diff for `DROP`, `ALTER TYPE`, `RENAME`. If any match, require PR label `db-breaking`; exit non-zero otherwise.
4. Wire all three into `ci.yml` under a new `migration-safety` job.
**Test Command**: `scripts/lint-migrations.sh <fixture-dir>` + `scripts/security-squawk.sh origin/main` against a fixture migration directory.
**DoD Items**:
- [ ] Destructive squawk rules enabled; fixture destructive migration causes squawk to fail
- [ ] `scripts/lint-migrations.sh` exits non-zero on `drop_column` without `@breaking_ok`, zero with it, tested with fixtures
- [ ] Schema diff step fails on DROP/ALTER TYPE/RENAME without `db-breaking` PR label; passes with it
- [ ] `migration-safety` job added to `ci.yml` and runs on all PRs that touch `apps/core/priv/repo/migrations/`

### Phase 3: Release Workflow + SLO Gate + Rollback
**Objective**: End-to-end production deploy with auto-rollback and observation propagation.
**Agent(s)**: platform-agent
**Steps**:
1. `scripts/probe-production.sh`: 10-min loop, every 30s hit `/api/health`, `GET /api/catalogue`, `POST /api/auth/login`, canary `POST /api/upload`. Record samples (status code, duration) to a temp file. Exit summary prints availability, p95 per probe, upload outcome.
2. `scripts/check-slo-gate.sh`: orchestrates the 10-min window. Every minute, scrape `/internal/metrics` via `fly proxy` on each core machine and aggregate (sum counters, max gauges). Invoke `probe-production.sh` in parallel. At end of window, compute SLI values vs thresholds (see Issue #136 Technical Requirements table). Emit the gate-outcome JSON blob. Exit 0 on pass, non-zero on breach.
3. Rollback helper: on gate failure, record rollback reason, then `fly deploy --image <prev-sha>` for core first, wait for health, then `modal deploy` on prev Modal commit for vision. Ordering per `docs/runbooks/vision-service-rollback.md`.
4. `.github/workflows/deploy-production.yml`: triggers on `workflow_run` completion (type=completed, conclusion=success) of `ci.yml`, INITIALLY on any branch for iteration. Steps: record prev image digest + prev Modal commit, deploy via `deploy-stack.sh` in prod mode (no Neon branch, prod app names), invoke `check-slo-gate.sh`, on non-zero exit invoke rollback helper, always upload the gate-outcome JSON via `actions/upload-artifact`, print summary to `$GITHUB_STEP_SUMMARY`.
5. Before merging this issue: switch the trigger from `workflow_run` (any branch) to `push.main`.
**Test Command**: Dry-run against current branch's preview app; verify probe/gate math; trigger a forced-rollback by setting an absurdly tight threshold and confirm the rollback helper fires.
**DoD Items**:
- [ ] `scripts/probe-production.sh` runs against a URL, prints structured summary, exits 0/non-zero
- [ ] `scripts/check-slo-gate.sh` scrapes `/internal/metrics`, aggregates across machines, runs probes, computes SLIs vs thresholds, emits JSON blob
- [ ] Rollback helper executes core-before-vision, verified against a forced-rollback fixture
- [ ] `deploy-production.yml` deploys core+vision+scraper, runs gate, rolls back on breach, uploads JSON artifact, prints summary
- [ ] Gate-observations JSON matches the schema in the issue description
- [ ] Workflow triggered on an intentionally broken build rolls back automatically and exits non-zero
- [ ] Workflow switched from `workflow_run` (any branch) to `push.main` before merge

### Parallel Execution
**Independent phases**: 1 and 2 can run in parallel worktrees.
**Merge order**: Phase 1 → Phase 2 → Phase 3 (Phase 3 depends on Phase 1 metrics).

## Open Questions
- Fly proxy vs direct scrape: Phase 3 uses `fly proxy` to scrape each core machine's `localhost:4000/internal/metrics`. Need to verify the proxy can reach both machines (not just one), else fall back to publicly-scraped endpoint with bearer token. Defer decision to platform-agent during implementation.
- DORA metrics schema: explicitly deferred to a follow-up issue within this branch. Gate-observations JSON is forward-compatible with any schema we pick later.

## Integration Handoffs
- Phase 1 → Phase 3: metric names and tag keys must be stable across the boundary. Phase 1 specialist records the exact event names in progress notes; Phase 3 specialist reads them before writing the scraper.
- Phase 2 → Phase 3: `migration-safety` job is independent from the deploy workflow; no runtime coupling.
