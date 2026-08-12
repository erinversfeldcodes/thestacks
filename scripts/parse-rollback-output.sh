#!/usr/bin/env bash

set -uo pipefail

log="${1:-}"

if [[ -z "$log" || ! -f "$log" ]]; then
    echo "core-rolled-back=error"
    echo "modal-rolled-back=error"
    echo "db-rolled-back=error"
    exit 0
fi

if grep -q -F -- "FAIL rollback: fly deploy (core) failed" "$log"; then
    core_status=error
elif grep -q -F -- "core rollback skipped" "$log"; then
    core_status=false
elif grep -q -F -- "PASS rollback: core rolled back" "$log"; then
    core_status=true
else
    core_status=error
fi

if grep -q -F -- "FAIL rollback: Neon" "$log"; then
    db_status=error
elif grep -q -F -- "WARN rollback: PRE_MIGRATE_LSN unset" "$log"; then
    db_status=false
elif grep -q -F -- "PASS rollback: Neon prod branch restored" "$log"; then
    db_status=true
else
    db_status=error
fi

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
