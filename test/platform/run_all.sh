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
    "$HERE/schema_diff_test.sh"
    "$HERE/ci_migration_safety_job_test.sh"
)

OVERALL=0
for s in "${SUITES[@]}"; do
    printf '\n######## %s ########\n' "$(basename "$s")"
    if ! bash "$s"; then
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
