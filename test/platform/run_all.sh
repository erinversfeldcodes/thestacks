#!/usr/bin/env bash
# test/platform/run_all.sh — top-level runner for Phase 2 platform tests.
#
# Each child test script prints TAP-ish output and exits 0 if all its
# assertions passed. This runner invokes them in sequence and aggregates
# exit codes so a single failing assertion anywhere fails the whole suite.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SUITES=(
    "$HERE/squawk_destructive_test.sh"
    "$HERE/lint_migrations_test.sh"
    "$HERE/migration_gate_syntax_test.sh"
    "$HERE/squawk_worktree_selection_test.sh"
    "$HERE/schema_diff_test.sh"
    "$HERE/ci_migration_safety_job_test.sh"
    "$HERE/probe_production_test.sh"
    "$HERE/check_slo_gate_test.sh"
    "$HERE/rollback_production_test.sh"
    "$HERE/deploy_production_workflow_test.sh"
    "$HERE/deploy_stack_retry_test.sh"
    "$HERE/deploy_stack_neon_lookup_test.sh"
    "$HERE/preview_names_test.sh"
    "$HERE/runtime_comment_freshness_test.sh"
    "$HERE/e2e_warmup_guard_test.sh"
    "$HERE/e2e_global_setup_guard_test.sh"
    "$HERE/e2e_global_setup_behavior_test.sh"
)

# Defensive per-suite wall-clock bound. These suites stub `curl`/`date` to keep
# polling loops instant, and a stub defect can make one of those loops
# unbounded — e2e_warmup_guard_test.sh did exactly that (Issue #358) and this
# runner hung for ever on suite 15 of 17 with no output. A bound turns that into
# a loud failure. `timeout` is GNU coreutils; if it isn't on PATH, run bare
# rather than skip the suite.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

OVERALL=0
for s in "${SUITES[@]}"; do
    printf '\n######## %s ########\n' "$(basename "$s")"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        # Capture the status with `|| rc=$?`, NOT `if ! cmd; then rc=$?`: inside
        # an `if !` the status has already been negated to 0, so the 124 branch
        # would never fire.
        rc=0
        "$TIMEOUT_BIN" "$SUITE_TIMEOUT" bash "$s" || rc=$?
        if [[ $rc -eq 124 ]]; then
            printf '# TIMED OUT after %ss — %s\n' "$SUITE_TIMEOUT" "$(basename "$s")"
        fi
        [[ $rc -eq 0 ]] || OVERALL=1
    elif ! bash "$s"; then
        OVERALL=1
    fi
done

printf '\n########################\n'
if [[ $OVERALL -eq 0 ]]; then
    printf '# all platform suites PASSED\n'
else
    printf '# at least one platform suite FAILED\n'
fi
exit "$OVERALL"
