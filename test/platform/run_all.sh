#!/usr/bin/env bash
#
# Runs every shell suite under test/platform — the ones covering migration
# safety, squawk, the rollback path, the SLO gate, and deploy-stack retry.
#
# Called by `scripts/ci.sh` as the `platform` group, so `just ci platform`
# (or a bare `just ci`) is what runs these in anger. It stays directly
# runnable too: `bash test/platform/run_all.sh`.
#
# Every suite in this directory belongs in SUITES below. A suite that is
# present on disk but absent from the list is a suite nothing runs — which
# is how the three at the end of the list spent their first months.

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
    "$HERE/parse_rollback_output_test.sh"
    "$HERE/rollback_action_composite_test.sh"
    "$HERE/deploy_production_workflow_test.sh"
    "$HERE/deploy_stack_retry_test.sh"
    "$HERE/deploy_stack_neon_lookup_test.sh"
    "$HERE/log_shipper_config_test.sh"
    "$HERE/preview_names_test.sh"
    "$HERE/runtime_comment_freshness_test.sh"
    "$HERE/e2e_warmup_guard_test.sh"
    "$HERE/e2e_global_setup_guard_test.sh"
    "$HERE/e2e_global_setup_behavior_test.sh"
)

# Fail loudly if a suite lands on disk without joining SUITES — otherwise the
# only symptom is a file nobody runs, and the whole point of this runner is
# that there is no such thing.
UNLISTED=""
for f in "$HERE"/*_test.sh; do
    [[ -e "$f" ]] || continue
    listed=0
    for s in "${SUITES[@]}"; do
        [[ "$s" == "$f" ]] && listed=1 && break
    done
    [[ $listed -eq 1 ]] || UNLISTED="${UNLISTED} $(basename "$f")"
done
if [[ -n "$UNLISTED" ]]; then
    printf '# UNLISTED SUITES (present in test/platform, absent from run_all.sh):%s\n' "$UNLISTED"
    printf '# Add them to SUITES, or delete them. A suite nothing runs is not a test.\n'
    exit 1
fi

SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$TIMEOUT_BIN" ]]; then
    # macOS ships neither; only the pinned nix shell puts coreutils on PATH.
    # Say so rather than degrade in silence — without it a wedged suite hangs
    # the gate with nothing on stdout to explain why.
    printf '# NOTE: no timeout/gtimeout on PATH — per-suite watchdog disabled.\n'
    printf '#       Run via the pinned shell (just run just ci platform) to keep it.\n'
fi

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
