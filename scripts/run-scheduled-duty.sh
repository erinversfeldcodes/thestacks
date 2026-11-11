#!/usr/bin/env bash
# scripts/run-scheduled-duty.sh — run one scheduled duty on the deployed node
# and prove it did something.
#
# Usage: run-scheduled-duty.sh <release-function> <sentinel> <metric-prefix>
#
#   run-scheduled-duty.sh Stacks.Release.sweep_images IMAGE_RETENTION image_retention
#
# ⛔ WHY A SCRIPT AND NOT TEN COPIES OF A WORKFLOW STEP. Ten duties now run this
# way, and the verification each one needs is identical: check the exit code,
# check the sentinel, read the remaining count, record the metric. Written
# inline that is ten near-identical blocks of YAML, and the failure mode of
# duplicated verification is not verbosity — it is that one copy drifts. A
# missing sentinel check in the ninth block looks exactly like the other eight
# until the day that duty fails quietly.
#
# ⚠️ The duty NAMES stay in the workflow, not here. The pairing guard searches
# the workflow corpus for each release function it expects to be invoked, so a
# manifest hidden in this file would let a duty be dropped from its schedule
# while the guard still found one shared reference and reported every duty
# paired. The workflow names the function; this script only knows how to run
# whatever it is handed.
#
# ⚠️ BOTH the exit code and the sentinel are checked, and each catches something
# the other cannot. The exit code propagates a raise — measured against the
# deployed node: `rpc 'raise "..."'` returns exit 1 with the stacktrace. What it
# does not catch is a task that RETURNS a failure instead of raising, because
# `rpc` then exits 0. The sentinel is printed only on the success path, so its
# absence catches any route to a quiet failure — including one introduced later
# by someone making a release task "more forgiving".

set -uo pipefail

FUNCTION="${1:?usage: run-scheduled-duty.sh <release-function> <sentinel> <metric-prefix>}"
SENTINEL="${2:?missing sentinel}"
PREFIX="${3:?missing metric prefix}"

: "${CORE_APP:?CORE_APP must name the Fly app to run against}"
FLYCTL="${FLYCTL:-flyctl}"
METRICS_FILE="${DUTY_METRICS_FILE:-metrics.prom}"

echo "==> ${FUNCTION} on ${CORE_APP} (${DUTY_INVOCATION:-rpc})"

# ⛔ `rpc` or `eval`, and the difference is which ROLE the duty runs as.
#
# `rpc` lands in the running node, which connects as the least-privilege
# runtime role — right for almost everything, and the reason the 512MB preview
# does not OOM. But a duty needing the OWNER cannot use it: measured on a
# deployed stack, the audit-retention sweep came back
# `ERROR 42501 permission denied for table audit_log`, because the runtime role
# holds INSERT and nothing else there. That is the append-only guarantee
# working, not a misconfiguration.
#
# `eval` spawns its own BEAM where the repo is not yet started, which is the
# only state in which `Stacks.Release.with_owner_repo/2` can point it at the
# owner connection.
#
# ⚠️ `eval` is NOT the default. It costs a second BEAM, and on the preview's
# 512MB machine a heavy task that way OOMs with no stacktrace — this project
# has that on record. Opt in per duty, for the duties that need the owner.
MODE="${DUTY_INVOCATION:-rpc}"
case "$MODE" in
    rpc|eval) ;;
    *) echo "::error::DUTY_INVOCATION must be rpc or eval, got '${MODE}'"; exit 1 ;;
esac

T0=$(date +%s)
out="$("$FLYCTL" ssh console --app "$CORE_APP" \
    -C "/app/bin/core ${MODE} '${FUNCTION}()'" 2>&1)"
rc=$?
elapsed=$(( $(date +%s) - T0 ))

echo "$out"

if [[ $rc -ne 0 ]]; then
    echo "::error::${FUNCTION} failed (exit ${rc})"
    exit "$rc"
fi

# ⚠️ Redundant with the remaining= check below, deliberately — and recorded so
# nobody deletes it as dead. That check greps for "${SENTINEL} remaining=", so
# it already refuses output with no sentinel at all; what this adds is the
# message. "printed no IMAGE_RETENTION line" names a duty that never completed,
# where "printed it without a remaining= count" names one that completed and
# reported half. Removing this leaves the refusal intact and the diagnosis
# worse, which is the kind of saving that costs an hour later.
if ! grep -q "$SENTINEL" <<<"$out"; then
    echo "::error::${FUNCTION} printed no ${SENTINEL} line — the duty did not complete"
    exit 1
fi

# ⛔ The count of work REMAINING, read back from the far end after the sweep —
# not the count the job reports having done. Several of these duties drain under
# a time budget or a batch ceiling and return `:ok` with rows still past their
# window, so "the duty succeeded" and "the sweep is finished" are different
# facts. Production held 6,655 expired image rows behind a nightly success, the
# oldest 151 days past expiry, which is what conflating them costs.
remaining="$(grep -oE "${SENTINEL} remaining=[0-9]+" <<<"$out" | tail -1 | grep -oE '[0-9]+$')"

if [[ -z "${remaining}" ]]; then
    echo "::error::${FUNCTION} printed ${SENTINEL} without a remaining= count, so this run" \
         "cannot say whether the sweep finished or merely started"
    exit 1
fi

# ⚠️ NOT a failure. A backlog being worked down across runs is the designed
# behaviour of a budgeted sweep, and failing here would turn a correct run red
# and train somebody to ignore it. Surfaced as a warning and carried by the
# gauge, which is where a trend belongs.
if [[ "${remaining}" -gt 0 ]]; then
    echo "::warning::${FUNCTION} finished with ${remaining} item(s) still past their window —" \
         "the backlog is being worked down across runs, not cleared in this one"
fi

cat >> "$METRICS_FILE" <<METRICS
stacks_${PREFIX}_last_success_timestamp_seconds{app="${CORE_APP}"} $(date +%s)
stacks_${PREFIX}_duration_seconds{app="${CORE_APP}"} ${elapsed}
stacks_${PREFIX}_pending_items{app="${CORE_APP}"} ${remaining}
METRICS

echo "==> ${FUNCTION} ok (${elapsed}s, ${remaining} remaining)"
