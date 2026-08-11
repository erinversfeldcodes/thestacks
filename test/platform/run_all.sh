#!/usr/bin/env bash

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

SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

OVERALL=0
for s in "${SUITES[@]}"; do
    printf '\n######## %s ########\n' "$(basename "$s")"
    if [[ -n "$TIMEOUT_BIN" ]]; then
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
