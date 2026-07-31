# Phase 2 Complete: Extend rollback-production.sh + test harness

**Issue**: #137
**Phase**: 2 of 7
**Agent**: platform-agent
**Reviewer**: platform-reviewer
**Verdict**: APPROVED
**Completed**: 2026-04-30
**Commit**: `0304db2`

## Deliverables

- `scripts/rollback-production.sh` — header rewrite (`:30-63`) + fast-fail Neon-vars validation (`:85-94`) + migration-failure detection (`:103-118`) + Neon LSN restore block (`:144-179`)
- `test/platform/rollback_production_test.sh` — extended `fly` stub to handle `image show` sub-command, new `curl` stub capturing `-d` body, 5 new test cases (Cases 5-9)

## Behaviour locked

- **Neon restore call:** `POST https://console.neon.tech/api/v2/projects/{pid}/branches/{bid}/restore` with self-restore body `{source_branch_id, source_lsn, preserve_under_name}`. Authorization via `Bearer` header. `preserve_under_name` format: `pre-rollback-${GITHUB_SHA:0:7}-<UTC ts>`.
- **Empty PRE_MIGRATE_LSN:** logs `WARN rollback: PRE_MIGRATE_LSN unset` and continues to Modal step.
- **Non-2xx Neon HTTP:** logs `FAIL rollback: Neon restore` and `exit 1` BEFORE Modal block (vision wire format depends on schema state).
- **Migration-failure detection:** `fly image show --json` parsed via `jq -r '.reference // empty'`; if equal to `CORE_PREV_IMAGE`, skip the `fly deploy --image` cutover and log `core rollback skipped`. LSN reset still fires.
- **Fast-fail validation:** when `PRE_MIGRATE_LSN` is set, all three of `NEON_PROJECT_ID`, `NEON_API_KEY`, `NEON_BRANCH_ID` must be set; missing → `exit 1` BEFORE any `fly`/`curl`/`modal` invocation.
- **Header:** old "Issue #137 follow-up" stub removed; replaced with structured Neon LSN-restore env contract + updated exit-code semantics.

## Gate Results

- 2A-iv Reception Gate: PASS (DoD evidence + testing-coordinator both clean)
- 2B-i Regression Gate: PASS — `bash test/platform/rollback_production_test.sh` 44 assertions pass / 0 fail; `shellcheck` clean
- 2B-ii Spec Coverage Gate: PASS — all section-4 Technical Requirements satisfied
- 2B-iia Fresh DB Gate: SKIPPED — no migrations or schema changes
- 2B-iii Deploy Preview + E2E: SKIPPED — bash script change verified via Phase 7 live runs against prod

## Reviewer Notes (carried forward)

1. **Phase 3 watch-item:** mirror the script's fast-fail Neon-vars validation in the composite action's `Validate inputs` step for better error ergonomics (script will catch it, but YAML-side validation gives a clearer error message).
2. **Image-equality on tags-vs-digests:** today's contract is consistent (`record-prev-state` and `fly image show` both return Fly's standard ref shape), but a future caller feeding short-tag refs while Fly returns digests would silently miss the migration-failure path and fire a harmless no-op cutover. Worth a one-line comment near `:108` if scope expands.
3. **`/tmp/neon-restore.json` collision risk:** `mktemp` would be more robust; not realistic in GHA single-runner jobs so deferred.

## Forward Compatibility

Phase 3 (composite action) wraps this script — env contract is now: `CORE_PREV_IMAGE` (required), `MODAL_PREV_COMMIT` (optional), `PRE_MIGRATE_LSN` (optional, gates Neon restore), three Neon vars (required-conditional), plus pre-existing Modal/Fly tokens. Phase 3's `action.yml` `inputs:` map 1:1.

Phase 4 wiring passes outputs from `Capture pre-migrate Neon LSN (prod)` step (`steps.capture-lsn.outputs.lsn`, `steps.capture-lsn.outputs.branch-id`) plus repo secrets. Compatible.
