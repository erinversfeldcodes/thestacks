# Phase 3 Complete: Composite action + parser

**Issue**: #137
**Phase**: 3 of 7
**Agent**: platform-agent
**Reviewer**: platform-reviewer
**Verdict**: APPROVED (revision cycle 1: parser extraction)
**Completed**: 2026-04-30
**Commit**: `c79b192`

## Deliverables

- `.github/actions/rollback-production/action.yml` — 17 inputs (13 contract + `failed-sha` + `triggered-by` + `database-url` + `cloak-key`), 3 outputs, 4 steps with locked IDs (`validate-inputs`, `run-rollback`, `log-audit`, `emit-outputs`)
- `scripts/parse-rollback-output.sh` — extracted parser, 75 LOC, exact-string `grep -F` matching, always exits 0
- `test/platform/rollback_action_composite_test.sh` — 81 contract assertions
- `test/platform/parse_rollback_output_test.sh` — 45 assertions across 15 cases including the **live-marker-check** sentinel
- `test/platform/lib/assert.sh` — `assert_path_exists` helper

**README intentionally not committed** — operator preference. Phase 6 (runbook documentation) may revisit.

## Behaviour locked

- **Composite action** wraps `scripts/rollback-production.sh` with declarative inputs (no env-inheritance from caller).
- **`validate-inputs` step** mirrors the script's fast-fail logic in YAML for clearer error messages: asserts `core-prev-image` set, conditional Modal token + Neon var validation.
- **`run-rollback` step** shells to the script with all 13 env vars wired from inputs; captures stdout via `tee /tmp/rollback-output.log`.
- **`log-audit` step** gated `if: steps.run-rollback.outcome == 'success'`. Runs `mix run -e 'Stacks.Audit.log_rollback(...)'` from `apps/core`. Empty-string-to-`nil` sanitisation for the optional `modal_prev_commit` field.
- **`emit-outputs` step** uses `if: always()`. Invokes `scripts/parse-rollback-output.sh` against the captured log; outputs `core-rolled-back`, `modal-rolled-back`, `db-rolled-back` as `true`/`false`/`error`.
- **Parser** uses fixed-string `grep -F` against the script's `PASS`/`WARN`/`FAIL` markers. Marker-drift sentinel locks the parser/script contract.

## Gate Results

- 2A-iv Reception Gate: PASS (DoD evidence + testing-coordinator both clean)
- 2B-i Regression Gate: PASS — 170 assertions across 3 bash test suites (45 + 81 + 44), all green
- 2B-ii Spec Coverage Gate: PASS — all section-1 + section-5 Technical Requirements satisfied
- 2B-iia Fresh DB Gate: SKIPPED — no migrations / schema / dbt / persisted.exs changes
- 2B-iii Deploy Preview + E2E: SKIPPED — composite action validated via Phase 7 live runs against prod

## Reviewer Notes (carry forward)

1. **Phase 4 watch-item: `setup-beam` + `mix deps.get` must run before invoking the composite action.** The deploy-production job already does this for the deploy path. The `manual_rollback` short-circuit branch (added in Phase 4) must also include these steps before invoking the action — otherwise the `log-audit` step fails opaquely.
2. **Phase 4 must populate `failed-sha` and `triggered-by` inputs.** Likely values:
   - `failed-sha`: `${{ github.sha }}` (the commit that just failed deploy)
   - `triggered-by`: branched on whether `inputs.manual_rollback == true` (`"manual"`) vs the SLO-gate / step-failure paths (`"slo-gate"` / `"step-failure"` / `"migration-failure"`)
3. **Phase 4 must forward `database-url` and `cloak-key` from secrets** to the composite action via `with:`.

## Forward Compatibility

Phase 4 wires this action into `deploy-production.yml`:
- `Capture pre-migrate Neon LSN (prod)` step produces `steps.capture-lsn.outputs.lsn` + `steps.capture-lsn.outputs.branch-id` → fed to the action's `pre-migrate-lsn` + `neon-branch-id` inputs.
- `Run prod migrations (before image cutover)` step replaces in-container migrate as the primary path.
- `manual_rollback` workflow_dispatch input + job-level `if:` short-circuit routes operator-initiated rollback through the same action.

Phase 5 (actionlint adoption) will lint this action.yml as part of the backfill.
