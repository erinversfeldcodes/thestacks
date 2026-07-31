# Plan: Rollback automation — composite action + migrate-before-image-cutover
**Issue**: #137
**Created**: 2026-04-29
**Status**: Approved

## Context
Two structural changes to the production deploy / rollback path, bundled because both modify the same `deploy-production.yml` surface: (1) a composite action wrapping `scripts/rollback-production.sh` so its secret dependencies are declarative, with a manual-trigger entry point; (2) `mix ecto.migrate` runs from the runner *before* the image cutover. Adds Neon LSN-based DB rollback so image and schema revert together. Audit + telemetry on every rollback.

## Research Summary
- Issue's line-number references mostly drift; corrected:
  - Inline rollback invocation: `deploy-production.yml:252-262`
  - `record-prev-state` step: lines 194-229 (picks the *second*-most-recent `main-*` tag because `tag-main.yml` stamps the current SHA before deploy)
  - Test harness: `test/platform/rollback_production_test.sh` (not `test/scripts/`)
- All referenced helpers exist: `Stacks.Audit.log/1`, `Stacks.Vault` (Cloak), `Stacks.Release.migrate/0`, `tag-main.yml`, `scripts/lint-migrations.sh`.
- `audit_log` schema fields are sufficient: `id`, `user_id`, `action`, `resource_type`, `resource_id`, `metadata` (encrypted), `ip_address`, `occurred_at`.
- Telemetry naming convention `[:stacks, :*, :*]` confirmed by existing `[:stacks, :fuse, :melt]` etc.
- `actionlint` is **not** yet in CI — Phase 5 adds it.
- `docs/runbooks/manual-rollback.md` and `migration-recovery.md` do not exist — Phase 6 creates them.
- `docs/runbooks/vision-service-rollback.md` already documents the "core first, then vision" ordering.

## Approach Options
- **Option A (chosen):** Six implementation phases (audit helper → script extension → composite action → workflow wiring → actionlint → runbooks) + Phase 7 live validation cycle. Each phase independently revertible and reviewable.
- **Option B:** Single mega-phase. Easier to schedule but harder to bisect a 250-LOC multi-domain PR. Not recommended.
- **Option C:** Defer DB rollback to a follow-up. Breaks the "image and DB go back together" contract — LSN reset is load-bearing. Not recommended.
- **Option D:** Audit helper as a separate workflow step (not inside the composite action). Cleaner separation but loses atomicity. Not recommended; issue explicitly puts it inside the action.

## Phases

### Phase 1: Audit + telemetry helper
**Objective**: Add `Stacks.Audit.log_rollback/1` (~30 LOC) emitting `[:stacks, :system, :rollback]` telemetry alongside the audit row insert. No callers yet.
**Agent(s)**: elixir-agent
**Reviewer(s)**: elixir-reviewer
**Steps**:
1. Add `log_rollback/1` to `apps/core/lib/stacks/audit.ex`. Wraps the existing `Stacks.Audit.log/1` insert with `action: "system.rollback"`, `resource_type: "deploy"`, `resource_id: <sha being rolled back>`, `metadata: %{target_image, modal_prev_commit, reason, triggered_by}`.
2. Emit `[:stacks, :system, :rollback]` telemetry event with same metadata after the audit insert succeeds.
3. Document the helper's contract (acceptable `triggered_by:` values: `"slo-gate"`, `"manual"`, `"step-failure"`, `"migration-failure"`).
4. Unit tests: insert path (Cloak-encrypted metadata round-trips), telemetry attach + event fire, error path (DB write fails → telemetry still emits or doesn't, document the choice).
**Test Command**: `cd apps/core && mix test test/stacks/audit_test.exs`
**DoD Items** (from issue):
- [ ] `Stacks.Audit.log_rollback/1` helper added (~30 LOC).
- [ ] `[:stacks, :system, :rollback]` telemetry event verified (unit test).
- [ ] Unit test for `Stacks.Audit.log_rollback/1` (insert + telemetry event).

### Phase 2: Extend rollback-production.sh + test harness
**Objective**: Add Neon LSN-restore block to `scripts/rollback-production.sh`. Add migration-failure detection (skip core rollback when `CORE_PREV_IMAGE == currently-serving image`). Extend test harness to mock the Neon `curl` and assert API call shape + ordering.
**Agent(s)**: platform-agent
**Reviewer(s)**: platform-reviewer
**Steps**:
1. Add env-var inputs to the script header: `NEON_PROJECT_ID`, `NEON_API_KEY`, `NEON_BRANCH_ID`, `PRE_MIGRATE_LSN`.
2. Add the Neon-restore block between core image rollback and Modal rollback (per issue section 4 verified shape):
   - `POST /projects/{pid}/branches/{bid}/restore` with `{source_branch_id: <self>, source_lsn: $PRE_MIGRATE_LSN, preserve_under_name: pre-rollback-<sha>-<timestamp>}`
   - Skip when `PRE_MIGRATE_LSN` is empty (log WARN, continue).
   - Wrap in `INVOCATION_LOG` short-circuit so the test harness can mock the `curl` call.
3. Add migration-failure detection: query the currently-serving Fly image SHA before running `fly deploy --image`. If it already matches `CORE_PREV_IMAGE`, log "core rollback skipped (image unchanged — migration failure path)" and proceed to DB restore.
4. Extend `test/platform/rollback_production_test.sh`:
   - Mock `curl` to Neon → assert endpoint, body fields, `preserve_under_name` format.
   - Assert ordering: core rollback log line precedes Neon restore log line.
   - Migration-failure case: when stub for `fly image show` returns `CORE_PREV_IMAGE`, assert core rollback is skipped but Neon restore still fires.
   - Cover empty-LSN path (skip with WARN).
5. Update script header comment to remove the "Issue #137 follow-up" stub line (was added when the script was first scaffolded).
**Test Command**: `bash test/platform/rollback_production_test.sh`
**DoD Items**:
- [ ] Existing test harness extended for the Neon-restore path (mocks curl, asserts API shape).
- [ ] Test harness covers ordering: core image rollback runs BEFORE Neon restore.
- [ ] Test harness covers migration-failure path: when `CORE_PREV_IMAGE` matches currently-serving, core rollback skipped, Neon restore fires.
- [ ] Composite action handles bootstrap edge case (empty `pre-migrate-lsn`) — at script level (script logs WARN, continues).
- [ ] `scripts/rollback-production.sh` header updated to remove "Issue #137 follow-up" stub.

### Phase 3: Composite action
**Objective**: Create `.github/actions/rollback-production/` (`action.yml` + `README.md`). Action declares all inputs explicitly, shells out to the (now-extended) `scripts/rollback-production.sh`, and invokes `mix run -e 'Stacks.Audit.log_rollback(%{...})'` after rollback success.
**Agent(s)**: platform-agent
**Reviewer(s)**: platform-reviewer
**Steps**:
1. Create `.github/actions/rollback-production/action.yml` per issue section 1. Inputs: `core-app`, `core-prev-image` (required), `modal-app`, `modal-prev-commit`, `modal-token-id`, `modal-token-secret`, `fly-api-token` (required), `rollback-reason` (required), `origin-remote`, `neon-project-id`, `neon-api-key`, `neon-branch-id`, `pre-migrate-lsn`. Outputs: `core-rolled-back`, `modal-rolled-back`, `db-rolled-back`.
2. Validate inputs step (composite action's first step): asserts `core-prev-image` set; if `modal-prev-commit` set, both Modal token inputs must also be set.
3. Run rollback script step: shells to `${{ github.action_path }}/../../../scripts/rollback-production.sh` with all env vars wired from inputs.
4. Audit + telemetry step: runs `cd apps/core && mix run -e 'Stacks.Audit.log_rollback(...)'` against prod `DATABASE_URL` + `CLOAK_KEY`. Inputs flow in via env. (`triggered_by` derived from input metadata or always `"step-failure"` for the composite-fired path; manual gets overridden via `rollback-reason` — see Phase 4 wiring.)
5. Outputs step: parse the script's exit codes / stdout markers (PASS/FAIL/SKIP per service) and write `core-rolled-back`, `modal-rolled-back`, `db-rolled-back` to `$GITHUB_OUTPUT`.
6. Create `.github/actions/rollback-production/README.md` per issue section 1 (operator-oriented: what it does, ordering invariant, all inputs, bootstrap edge case, failure modes, manual invocation, links to runbooks created in Phase 6).
**Test Command**: `actionlint .github/actions/rollback-production/action.yml` + dry-run via `act` if feasible; full validation happens in Phase 7.
**DoD Items**:
- [ ] `.github/actions/rollback-production/action.yml` created with the input/output schema.
- [ ] `.github/actions/rollback-production/README.md` covers all required sections.
- [ ] Composite action accepts `neon-project-id`, `neon-api-key`, `neon-branch-id`, `pre-migrate-lsn` inputs.
- [ ] Composite action invokes the audit helper on rollback success.

### Phase 4: Wire up `deploy-production.yml`
**Objective**: Add LSN capture, runner-side migration, manual-rollback dispatch input, and switch the rollback step from inline bash to the composite action.
**Agent(s)**: platform-agent
**Reviewer(s)**: platform-reviewer
**Steps**:
1. Add `manual_rollback: { type: boolean, default: false }` to the `workflow_dispatch.inputs:` block.
2. Add `Capture pre-migrate Neon LSN (prod)` step BEFORE migrations (after `Compose DATABASE_URL`):
   - Run `psql "$DATABASE_URL" -t -A -c "SELECT pg_current_wal_lsn();"`, capture as step output `lsn`.
   - Resolve prod branch ID via `GET /branches` filtered on `default: true`, capture as step output `branch-id`.
   - Both outputs flow into the rollback action.
3. Add `Run prod migrations (before image cutover)` step between LSN capture and `deploy-stack.sh`:
   - `cd apps/core && mix deps.get --only prod && mix compile && mix ecto.migrate` with `MIX_ENV=prod`, `DATABASE_URL`, `CLOAK_KEY` env.
4. Replace inline `bash scripts/rollback-production.sh` step (`deploy-production.yml:252-262`) with `uses: ./.github/actions/rollback-production` per issue section 6. Wire all inputs from secrets + step outputs. `if:` covers both `failure()` and `inputs.manual_rollback`.
5. Add job-level `if:` short-circuit so when `manual_rollback == true`, deploy-stack + gate steps are skipped (only LSN capture, migrate, and rollback run).
6. Update the comment at `scripts/deploy-stack.sh:722` documenting the in-container migrate is now a no-op safety net (runner is the primary path).
**Test Command**: `actionlint .github/workflows/deploy-production.yml` + Phase 7 live validation.
**DoD Items**:
- [ ] `deploy-production.yml` uses the composite action via `uses:` syntax.
- [ ] `manual_rollback` workflow_dispatch input added; gates a branch that skips deploy + gate.
- [ ] `Capture pre-migrate Neon LSN (prod)` step lands BEFORE migrate step.
- [ ] `Run prod migrations (before image cutover)` step lands between `Compose DATABASE_URL` and `deploy-stack.sh`.
- [ ] `scripts/deploy-stack.sh:722` retained as no-op safety net with updated comment.
- [ ] Preview deploy path (`deploy-preview` job) unchanged.
- [ ] `NEON_PROJECT_ID` + `NEON_API_KEY` confirmed available as GH repo secrets (operator action; verify before merge).

### Phase 5: actionlint adoption + backfill
**Objective**: Add `actionlint` to CI's lint job. Triage existing workflow warnings: hard errors fixed in this PR, style warnings ignored with follow-up.
**Agent(s)**: platform-agent
**Reviewer(s)**: platform-reviewer
**Steps**:
1. Add `actionlint` step to `.github/workflows/ci.yml`'s lint job (run `rhysd/actionlint@v1` or install via `go install`).
2. Run `actionlint` locally; classify warnings into hard errors vs. style warnings.
3. Fix hard errors in this PR (typos, malformed expressions, missing keys).
4. For style warnings: either fix trivially or `actionlint -ignore '<pattern>'` with a TODO link to a follow-up issue.
5. Verify the new composite action + `deploy-production.yml` from Phase 4 are lint-clean.
**Test Command**: `actionlint`
**DoD Items**:
- [ ] `actionlint` step added to `ci.yml`'s lint job.
- [ ] Existing workflows + composite action all lint-clean (or hard errors fixed; style warnings ignored with follow-up issue link).
- [ ] New composite action lands with zero actionlint warnings.

### Phase 6: Runbooks + follow-ups
**Objective**: Write the two operator-facing runbooks. File two follow-up issues for out-of-scope items.
**Agent(s)**: platform-agent
**Reviewer(s)**: platform-reviewer
**Steps**:
1. Write `docs/runbooks/manual-rollback.md`:
   - Opens with the data-loss contract (≤17 min worst case).
   - How to invoke: `gh workflow run deploy-production.yml -f manual_rollback=true`.
   - What to expect: which services revert, audit row written, telemetry event fires.
   - Pre-rollback Neon branch (`pre-rollback-*`) inspection + promotion procedure.
2. Write `docs/runbooks/migration-recovery.md`:
   - Decision tree: forward-fix vs. down-migrate vs. rely on auto-rollback.
   - Cross-references `migration-safety` lint and the expand-contract invariant.
   - When to use `mix ecto.rollback` (local dev only) vs. Neon LSN reset (prod).
3. File follow-up issue: scheduled cleanup of stale `pre-rollback-*` Neon branches (>30d old).
4. File follow-up issue: `docs/runbooks/bootstrap-prod-environment.md` for fresh prod-stack setup (one-time `git tag main-bootstrap` procedure).
**Test Command**: N/A (docs).
**DoD Items**:
- [ ] `docs/runbooks/manual-rollback.md` (new): data-loss contract + invocation.
- [ ] `docs/runbooks/migration-recovery.md` (new): forward-fix vs. down-migrate decision tree.
- [ ] Two follow-up issues filed.

### Phase 7: Live validation on PR204 (operator-driven)
**Objective**: Validate the rollback path against real Fly + Neon + Modal infrastructure by riding PR204's existing `pull_request:` trigger as a deploy-production firing mechanism. Each push triggers a real prod deploy → Modal SLO breach → rollback observation.
**Agent(s)**: n/a — operator orchestrates; orchestrator records observations.
**Reviewer(s)**: n/a — observed live in production.
**Steps**:
1. Push fixes from Phases 1-6 to PR204; first push fires a real deploy → expected SLO breach → rollback.
2. Capture observations per the issue's Phase 3 checklist (gate-observations.json artifact, audit row, Axiom telemetry, Fly serving image, Neon LSN reset, composite action outputs, health check post-rollback).
3. Diagnose any edge case from the workflow logs + artifact; patch composite action / script / capture step; re-push.
4. Repeat until two consecutive clean rollback observations end-to-end.
5. Lock down the workflow: remove the `pull_request:` clause from `deploy-production.yml:50-55`'s `if:` expression. Verify in last PR204 push that deploy-production is skipped.
6. Merge PR204 — post-merge `tag-main.yml` stamps a new tag, then `workflow_run` fires the production deploy.
7. Post-merge: operator bumps Modal workspace spend cap. Next deploy clears the gate.
8. Final validation: deliberate manual-rollback test on a no-op commit (`gh workflow run` with `manual_rollback: true`); audit row records `triggered_by: "manual"`.
**Test Command**: real prod observation per push.
**DoD Items**:
- [ ] At least two consecutive PR204 pushes produce clean rollback observations end-to-end.
- [ ] Phase 3 observations recorded in issue Progress Notes for each iteration.
- [ ] Edge cases surfaced during Phase 2 patched and re-verified.
- [ ] `pull_request:` clause removed from `deploy-production.yml`'s `if:` expression.
- [ ] Modal budget bumped post-merge; subsequent deploy passes the gate.
- [ ] Deliberate manual-rollback exercised; audit row tagged `triggered_by: "manual"`.
- [ ] `pre-rollback-*` preserved branches confirmed in Neon console after a rollback.
- [ ] `[:stacks, :system, :rollback]` telemetry visible in Axiom.

### Parallel Execution
None. Phases are sequential — Phase N+1 depends on Phase N's artifacts (Phase 3's composite action depends on Phase 2's script extension; Phase 4 wiring depends on Phase 3's action; etc.). Phase 5 (actionlint) is technically parallelisable with Phase 4 but kept sequential per operator preference.

## Open Questions
None. All open triage items resolved per issue Progress Notes (2026-04-29 "open questions resolved").

## Integration Handoffs
- **Phase 1 → Phase 3:** Phase 3 invokes `Stacks.Audit.log_rollback/1` from inside the composite action via `mix run -e`. Phase 1 must produce a helper with a stable arity-1 signature taking a map of `target_image`, `modal_prev_commit`, `reason`, `triggered_by`, and `failed_sha` (for `resource_id`).
- **Phase 2 → Phase 3:** The composite action's "Run rollback script" step shells to the script Phase 2 extended. Phase 2 must produce a script that's callable purely via env vars (no positional args), with `INVOCATION_LOG` short-circuit covering all new external calls (Neon `curl`, `fly image show` for currently-serving detection).
- **Phase 3 → Phase 4:** Phase 4's wiring step depends on Phase 3's `inputs:` schema being final. If Phase 3's input names change during review, Phase 4's `with:` block must be updated in the same PR.
- **Phase 4 → Phase 5:** Phase 5's actionlint backfill must include the new `deploy-production.yml` shape from Phase 4. Run actionlint on the *final* state, not an intermediate.
- **Phase 6 → Phase 7:** Manual-rollback runbook (Phase 6) is referenced by Phase 7's deliberate manual-rollback test step. Order doesn't strictly enforce this (test can run before docs), but the runbook is what makes the workflow_dispatch input help-text useful.
