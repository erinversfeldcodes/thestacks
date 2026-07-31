# Phase 4 Complete: Wire deploy-production.yml to rollback composite action

**Issue**: #137
**Phase**: 4 of 7
**Agent**: platform-agent
**Reviewer**: platform-reviewer
**Verdict**: APPROVED
**Completed**: 2026-05-01
**Commit**: `9ca438b` (also includes Phase 3's README.md, originally deferred)

## Deliverables

- `.github/workflows/deploy-production.yml` — `manual_rollback` workflow_dispatch input, `Install postgresql-client` step, `Capture pre-migrate Neon LSN (prod)` step (id `capture-lsn`), `Run prod migrations (before image cutover)` step (id `migrate-prod`), gated `deploy-stack` + `gate` steps on `!inputs.manual_rollback`, replaced inline rollback bash with `uses: ./.github/actions/rollback-production` invocation
- `scripts/deploy-stack.sh:716-724` — defense-in-depth comment update for the in-container `Stacks.Release.migrate()` call
- `test/platform/deploy_production_workflow_test.sh` — 7 new contract test cases (M1-M7) covering input declaration, step presence + ordering, `with:` wiring, short-circuit gating; pre-existing regex tightened from `rollback` to `\brollback\b`

## Behaviour locked

- **Capture-LSN step:** uses `psql + SELECT pg_current_wal_lsn()` to capture LSN; resolves prod branch ID via `GET /branches` filtered on `default: true`. Both written to `$GITHUB_OUTPUT` (`lsn`, `branch-id`). Gated on `!inputs.manual_rollback`.
- **Migrate-prod step:** runs `mix deps.get --only prod && mix compile && mix ecto.migrate` from `apps/core` with `MIX_ENV=prod`. Gated on `!inputs.manual_rollback`. Defense-in-depth: in-container `Stacks.Release.migrate()` (`scripts/deploy-stack.sh:722`) remains a no-op safety net.
- **Rollback step:** `uses: ./.github/actions/rollback-production` with 16 of 17 inputs wired (`origin-remote` uses the action's default). `if: ${{ failure() || inputs.manual_rollback }}`. The `triggered-by` input is a 3-arm ternary: `manual_rollback && 'manual' || (steps.migrate-prod.conclusion == 'failure' && 'migration-failure' || 'step-failure')`. Verified end-to-end:
  - `manual_rollback == true` → `'manual'`
  - `manual_rollback == false`, migrate failed → `'migration-failure'`
  - `manual_rollback == false`, migrate succeeded/skipped → `'step-failure'`
- **Manual-rollback short-circuit:** when `manual_rollback == true`, capture-lsn / migrate-prod / deploy-stack / gate all skip; setup steps + record-prev-state + proto-gen + Compose-DATABASE_URL + Install-postgresql-client all run unconditionally so the action has Elixir + DB context available; rollback step's `pre-migrate-lsn` evaluates to empty → composite action's script-level skip kicks in (no DB rollback attempted, which is correct because no migration ran).

## Gate Results

- 2A-iv Reception Gate: PASS (DoD evidence + testing-coordinator clean — implicit through reviewer's independent audit)
- 2B-i Regression Gate: PASS — 4 bash test suites: 80 + 81 + 44 + 45 = 250 assertions, 0 failures
- 2B-ii Spec Coverage Gate: PASS — all section-2/3/6 Technical Requirements satisfied (note: 16 of 17 action inputs wired; `origin-remote` uses action default)
- 2B-iia Fresh DB Gate: SKIPPED — no migrations / schema / dbt / persisted.exs changes in this phase
- 2B-iii Deploy Preview + E2E: SKIPPED — workflow validated via Phase 7 live runs against prod

## Pre-merge cleanup applied

The initial implementation used a YAML line-continuation workaround (splitting `manual_rollback` across `\<NL>` so the file-text wouldn't contain the substring `rollback` until the gate step) to satisfy a buggy file-text regex in the pre-existing Phase 3 ordering test. Before commit, the orchestrator + operator chose to fix the underlying regex instead:

- `test/platform/deploy_production_workflow_test.sh:113,129` — third regex alternative `rollback` changed to `\brollback\b` (word boundary). `_` is a word char so `manual_rollback` no longer matches; `rollback-production` still does (because `-` is non-word so `\b` exists at the boundary).
- 3 line-continuation `if:` clauses in the workflow restored to standard `if: ${{ !inputs.manual_rollback }}` form.
- Gate step's awkward key ordering (which placed `if:` and `env:` after `run:` to dodge the same regex bug) normalized — `if:` and `env:` now precede `run:` like every other step.

11 lines of explanatory comments removed from the workflow as a result.

## Reviewer Notes (carry-forward)

1. **`mix compile` cost in `migrate-prod`:** ~30s on cached runners, up to 2-3min cold. Acceptable for now (workflow budget is 45min, healthy deploy is 10-15min). Optimisation candidate via `actions/cache` keyed on `mix.lock` hash — file as a follow-up if cold-compile time becomes a bottleneck.
2. **PyYAML in `flake.nix`** — Phase 3 reviewer flag, still open. Phase 5 is a clean place to address it but not strictly in scope.
3. **`origin-remote` not wired in workflow's `with:` block** — intentional; the action defaults it. Worth a one-line comment near the `with:` block in case a future maintainer wonders why it's absent.

## Forward Compatibility

- Phase 5 (actionlint adoption) lints this workflow alongside the rest.
- Phase 6 (runbooks) — `manual-rollback.md` is referenced from this workflow's top comment + the `manual_rollback` input description.
- Phase 7 (live validation) — exercises this workflow on every PR204 push; removes the temporary `pull_request:` trigger before merge.
