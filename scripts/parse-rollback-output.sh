#!/usr/bin/env bash
# scripts/parse-rollback-output.sh — classify a rollback log into per-leg
# status outputs.
#
# Reads its single positional arg as a path to the stdout/stderr log of
# `scripts/rollback-production.sh` (typically `/tmp/rollback-output.log` as
# `tee`'d by the composite action's `run-rollback` step) and writes three
# `key=value` lines to stdout:
#
#   core-rolled-back=<true|false|error>
#   modal-rolled-back=<true|false|error>
#   db-rolled-back=<true|false|error>
#
# Output value semantics (per leg):
#   true   – leg ran and succeeded (corresponding `PASS rollback: …` marker
#            present)
#   false  – leg was deliberately skipped by the script (`==> core rollback
#            skipped`, `WARN rollback: PRE_MIGRATE_LSN unset`, `WARN rollback:
#            MODAL_PREV_COMMIT is unset`)
#   error  – leg failed (`FAIL rollback: …` marker present), or the parser
#            could not classify the log at all
#
# Always exits 0 — parsing failure is signalled via the `error` value, not
# via a non-zero exit code. The composite action's `emit-outputs` step
# needs the outputs to land regardless of upstream-step status, so a
# parse-time crash here would lose the per-leg signal.
#
# Marker matching is exact-string only (`grep -F`). Keep the marker list in
# this script in lockstep with `scripts/rollback-production.sh` —
# `test/platform/parse_rollback_output_test.sh`'s `live_marker_check` case
# fails immediately when a marker drifts.

set -uo pipefail

log="${1:-}"

if [[ -z "$log" || ! -f "$log" ]]; then
    # No log produced (e.g. validate-inputs failed before run-rollback could
    # run). Emit `error` for every leg so consumers don't mistake silence
    # for success.
    echo "core-rolled-back=error"
    echo "modal-rolled-back=error"
    echo "db-rolled-back=error"
    exit 0
fi

# core leg
if grep -q -F -- "FAIL rollback: fly deploy (core) failed" "$log"; then
    core_status=error
elif grep -q -F -- "core rollback skipped" "$log"; then
    core_status=false
elif grep -q -F -- "PASS rollback: core rolled back" "$log"; then
    core_status=true
else
    core_status=error
fi

# db (Neon) leg
if grep -q -F -- "FAIL rollback: Neon" "$log"; then
    db_status=error
elif grep -q -F -- "WARN rollback: PRE_MIGRATE_LSN unset" "$log"; then
    db_status=false
elif grep -q -F -- "PASS rollback: Neon prod branch restored" "$log"; then
    db_status=true
else
    db_status=error
fi

# modal/vision leg
if grep -q -F -- "FAIL rollback: modal deploy" "$log" \
    || grep -q -F -- "FAIL rollback: could not check out" "$log" \
    || grep -q -F -- "FAIL rollback: modal deploy stub" "$log"; then
    modal_status=error
elif grep -q -F -- "WARN rollback: MODAL_PREV_COMMIT is unset" "$log"; then
    modal_status=false
elif grep -q -F -- "PASS rollback: vision rolled back" "$log"; then
    modal_status=true
else
    modal_status=error
fi

echo "core-rolled-back=${core_status}"
echo "modal-rolled-back=${modal_status}"
echo "db-rolled-back=${db_status}"
exit 0
