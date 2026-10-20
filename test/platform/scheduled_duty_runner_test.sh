#!/usr/bin/env bash
# test/platform/scheduled_duty_runner_test.sh
#
# `scripts/run-scheduled-duty.sh` is the shared verification for every duty that
# moved off the Oban crontab onto a workflow. Ten duties route through it, so a
# hole in it is a hole in all ten at once — which is the reason it exists as one
# script instead of ten copied YAML blocks, and the reason its failure paths are
# driven here rather than trusted.
#
# ⛔ What this suite is really guarding. The defect the whole migration answers
# is a scheduled duty that reports success having done nothing: Oban's cron
# plugin fired entries only when something else woke the machine, and the
# evidence was a job row frozen at attempt 1. Replacing that with a workflow
# step that cannot distinguish "swept" from "returned :ok" would reproduce the
# same defect in a new place. So every refusal below is driven with a stub
# flyctl, including the two that matter most: a task that exits 0 without its
# sentinel, and one that prints its sentinel with no remaining= count.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

RUNNER="$REPO_ROOT/scripts/run-scheduled-duty.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stub standing in for `flyctl ssh console`, printing whatever the case under
# test needs and exiting with whatever code it needs.
write_flyctl_stub() {
    local output="$1" exit_code="$2"
    cat > "$WORK/flyctl" <<STUB
#!/usr/bin/env bash
cat <<'OUTPUT'
${output}
OUTPUT
exit ${exit_code}
STUB
    chmod +x "$WORK/flyctl"
}

run_duty() {
    (
        cd "$REPO_ROOT" || exit 1
        CORE_APP=stub-app \
        FLYCTL="$WORK/flyctl" \
        DUTY_METRICS_FILE="$WORK/metrics.prom" \
            bash "$RUNNER" "$@" 2>&1
    )
}

test_case "inputs_exist" "the runner and its caller"
assert_path_exists "$RUNNER" "scripts/run-scheduled-duty.sh exists"
if bash -n "$RUNNER" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so every case below tests nothing"
fi

test_case "a_successful_duty_passes_and_records_its_metrics" "the happy path"
: > "$WORK/metrics.prom"
write_flyctl_stub "IMAGE_RETENTION remaining=0" 0
OUT_OK="$(run_duty Stacks.Release.sweep_images IMAGE_RETENTION image_retention)"
RC_OK=$?
if [[ $RC_OK -eq 0 ]]; then
    _record_pass "a duty printing its sentinel and a count succeeds"
else
    _record_fail "a correct duty was rejected (exit $RC_OK): $OUT_OK"
fi
METRICS="$(cat "$WORK/metrics.prom")"
assert_contains "$METRICS" "stacks_image_retention_last_success_timestamp_seconds" \
    "it records a freshness gauge"
assert_contains "$METRICS" "stacks_image_retention_pending_items{app=\"stub-app\"} 0" \
    "it records the REMAINING count, which is what says whether the sweep finished"
assert_contains "$METRICS" "stacks_image_retention_duration_seconds" \
    "it records how long the duty took"

test_case "a_nonzero_exit_is_a_FAILURE" "a raising task"
write_flyctl_stub "** (RuntimeError) boom" 1
OUT_RAISE="$(run_duty Stacks.Release.sweep_images IMAGE_RETENTION image_retention)"
RC_RAISE=$?
if [[ $RC_RAISE -ne 0 ]]; then
    _record_pass "a raising duty fails the step (exit $RC_RAISE)"
else
    _record_fail "a duty that raised was reported as success: $OUT_RAISE"
fi

test_case "a_MISSING_SENTINEL_is_a_FAILURE" "the quiet-failure path"
# ⛔ The case the exit code cannot catch. A release task that RETURNS a failure
# instead of raising leaves `rpc` exiting 0, so without this check the step
# would be green for a duty that did nothing at all.
: > "$WORK/metrics.prom"
write_flyctl_stub "some unrelated chatter and no sentinel at all" 0
OUT_NOSENT="$(run_duty Stacks.Release.sweep_images IMAGE_RETENTION image_retention)"
RC_NOSENT=$?
if [[ $RC_NOSENT -ne 0 ]]; then
    _record_pass "exit 0 with no sentinel still fails (exit $RC_NOSENT)"
else
    _record_fail "a duty that exited 0 without completing was reported as success — this is the original defect"
fi
assert_contains "$OUT_NOSENT" "printed no IMAGE_RETENTION line" \
    "and the error names what was missing"
if [[ ! -s "$WORK/metrics.prom" ]]; then
    _record_pass "and it wrote NO metrics, so the gauge cannot stamp a success it did not have"
else
    _record_fail "it recorded a freshness metric for a run that failed: $(cat "$WORK/metrics.prom")"
fi

test_case "a_sentinel_with_NO_COUNT_is_a_FAILURE" "half-evidence is not evidence"
# ⚠️ A sentinel on its own says the task reached its final line. It does not say
# whether the sweep finished, which for a budgeted drain is the whole question.
write_flyctl_stub "IMAGE_RETENTION ok" 0
OUT_NOCOUNT="$(run_duty Stacks.Release.sweep_images IMAGE_RETENTION image_retention)"
RC_NOCOUNT=$?
if [[ $RC_NOCOUNT -ne 0 ]]; then
    _record_pass "a sentinel without remaining= is refused (exit $RC_NOCOUNT)"
else
    _record_fail "a duty reporting no remaining count passed, so a budgeted sweep that stopped early would read as complete: $OUT_NOCOUNT"
fi

test_case "a_REMAINING_BACKLOG_warns_but_does_NOT_fail" "a budgeted sweep is allowed to be behind"
# ⚠️ The inverse case, and it matters as much as the refusals. A drain that
# worked its budget and left rows is behaving correctly; failing it would make a
# correct run red and teach somebody to ignore the signal that carries the real
# trend.
: > "$WORK/metrics.prom"
write_flyctl_stub "IMAGE_RETENTION remaining=4213" 0
OUT_BACKLOG="$(run_duty Stacks.Release.sweep_images IMAGE_RETENTION image_retention)"
RC_BACKLOG=$?
if [[ $RC_BACKLOG -eq 0 ]]; then
    _record_pass "a run with a remaining backlog still succeeds"
else
    _record_fail "a correctly-budgeted sweep was failed for being behind (exit $RC_BACKLOG)"
fi
assert_contains "$OUT_BACKLOG" "::warning::" "it warns rather than passing silently"
assert_contains "$OUT_BACKLOG" "4213" "and the warning carries the size of the backlog"
assert_contains "$(cat "$WORK/metrics.prom")" \
    "stacks_image_retention_pending_items{app=\"stub-app\"} 4213" \
    "and the gauge carries it too, which is where a trend belongs"

test_case "the_sentinel_is_not_hardcoded" "the runner is shared by ten duties"
# A runner that only ever worked for one duty's sentinel would pass every case
# above while being useless for the other nine.
: > "$WORK/metrics.prom"
write_flyctl_stub "AUDIT_RETENTION remaining=7" 0
OUT_OTHER="$(run_duty Stacks.Release.sweep_audit_log AUDIT_RETENTION audit_retention)"
if [[ $? -eq 0 ]]; then
    _record_pass "a different duty's sentinel and prefix work too"
else
    _record_fail "the runner handles only one duty: $OUT_OTHER"
fi
assert_contains "$(cat "$WORK/metrics.prom")" \
    "stacks_audit_retention_pending_items{app=\"stub-app\"} 7" \
    "and the metric prefix follows the duty rather than being fixed"

test_case "the_workflow_actually_calls_it" "a runner nothing invokes proves nothing"
# ⛔ The complement every gate in this repository owes: this suite proves the
# runner refuses correctly, and that is worth nothing if no workflow runs it.
WF="$(cat "$REPO_ROOT/.github/workflows/scheduled-core-jobs.yml" 2>/dev/null)"
assert_contains "$WF" "run-scheduled-duty.sh" \
    "scheduled-core-jobs.yml invokes the runner"

summarise
