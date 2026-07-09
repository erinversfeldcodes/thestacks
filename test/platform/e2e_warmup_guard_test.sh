#!/usr/bin/env bash
# test/platform/e2e_warmup_guard_test.sh
#
# Issue #175: warm the preview app before E2E setup.
#
# The deployed-preview E2E gate intermittently fails at Playwright's `setup`
# project with HTTP 502 because the preview core app has
# `auto_stop_machines = true` and goes cold between the deploy warmup and
# setup's first login. The shell-side fix (Guard A) adds a
# `warm_remote_preview()` function to scripts/test-e2e.sh that, in REMOTE mode
# only, polls `$BASE_URL/api/health` (via the existing `wait_for_health`
# helper) until 200 immediately before the Playwright run — and is a strict
# no-op in local mode.
#
# Like deploy_stack_retry_test.sh, we exercise the plain shell functions in
# isolation rather than spinning up Fly/Playwright. `curl` and `date` are
# stubbed so the poll is deterministic and instant (no network, no 60s wait).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

E2E_SCRIPT="$REPO_ROOT/scripts/test-e2e.sh"

# ── Extract the two plain shell functions we depend on ───────────────────────
# `wait_for_health` already exists; `warm_remote_preview` is the fix under test.
# Both are top-level function definitions with a column-0 closing brace.
WAIT_FN="$(awk '/^wait_for_health\(\)/,/^}/' "$E2E_SCRIPT")"
WARM_FN="$(awk '/^warm_remote_preview\(\)/,/^}/' "$E2E_SCRIPT")"

# shellcheck disable=SC2294
eval "$WAIT_FN"
# shellcheck disable=SC2294
eval "$WARM_FN"

# ── Deterministic stubs (no real network, no real clock) ─────────────────────
# curl: records every invocation to CURL_LOG; returns success/failure based on
# the single word in CURL_MODE_FILE ("ok" → 0, anything else → non-zero).
CURL_LOG="$(mktemp)"
CURL_MODE_FILE="$(mktemp)"
DATE_COUNTER="$(mktemp)"
trap 'rm -f "$CURL_LOG" "$CURL_MODE_FILE" "$DATE_COUNTER"' EXIT

echo "fail" > "$CURL_MODE_FILE"
echo 0 > "$DATE_COUNTER"

curl() {
    echo "call $*" >> "$CURL_LOG"
    if [[ "$(cat "$CURL_MODE_FILE")" == "ok" ]]; then
        return 0
    fi
    return 1
}
export -f curl

# date: emulates `date +%s`. First call returns a base time (used to compute the
# deadline); every subsequent call jumps far past any 60s deadline so the
# wait_for_health loop gives up on its very next deadline check — instant, no
# 60s wall-clock wait.
date() {
    local n
    n="$(cat "$DATE_COUNTER")"
    echo $((n + 1)) > "$DATE_COUNTER"
    if [[ "$n" -eq 0 ]]; then
        echo 1000
    else
        echo 100000
    fi
}
export -f date

reset_stubs() {
    : > "$CURL_LOG"
    echo 0 > "$DATE_COUNTER"
}

curl_call_count() {
    # Count non-empty lines in the curl log. `grep -c` prints 0 and exits 1 when
    # there are no matches, so swallow the exit code and keep the single "0".
    local n
    n="$(grep -c . "$CURL_LOG" 2>/dev/null)" || true
    echo "${n:-0}"
}

# ── Guard: the function under test must actually exist ───────────────────────
test_case "warm_remote_preview_defined" "warm_remote_preview is defined in scripts/test-e2e.sh"
assert_contains "$WARM_FN" "warm_remote_preview" \
    "scripts/test-e2e.sh defines a warm_remote_preview function"
if declare -F warm_remote_preview >/dev/null 2>&1; then
    _record_pass "warm_remote_preview is callable after extraction/eval"
else
    _record_fail "warm_remote_preview is callable after extraction/eval (function not found)"
fi

# ── Case 1: LOCAL mode → no poll, returns 0 ──────────────────────────────────
# Local mode = BASE_URL unset AND E2E_SERVICES not "none". The warmup must be a
# strict no-op: it must NOT call curl and must return 0.
test_case "local_mode_no_poll" "local mode performs no health poll and returns 0"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"   # even if it tried, curl would fail — proves it doesn't try
(
    unset BASE_URL
    unset E2E_SERVICES
    warm_remote_preview
)
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 in local mode"
CALLS="$(curl_call_count)"
if [[ "$CALLS" -eq 0 ]]; then
    _record_pass "warm_remote_preview made zero curl calls in local mode"
else
    _record_fail "warm_remote_preview made zero curl calls in local mode (got $CALLS)"
fi

# ── Case 1b: E2E_SERVICES=none + BASE_URL UNSET → no poll, returns 0 ─────────
# "Run against an already-running local stack" mode (E2E_SERVICES=none, no
# BASE_URL). There is no remote URL to warm, so the warmup must be a strict
# no-op: no curl, return 0. Regression guard for the compound-predicate bug that
# busy-looped wait_for_health against an empty URL for the full 60s and exited 1.
test_case "services_none_no_base_url_no_poll" "E2E_SERVICES=none with unset BASE_URL is a no-op"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"   # any accidental call would be a visible failure
(
    export E2E_SERVICES=none
    unset BASE_URL
    warm_remote_preview
)
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 when E2E_SERVICES=none and BASE_URL is unset"
CALLS="$(curl_call_count)"
if [[ "$CALLS" -eq 0 ]]; then
    _record_pass "warm_remote_preview made zero curl calls (E2E_SERVICES=none, no BASE_URL)"
else
    _record_fail "warm_remote_preview made zero curl calls (E2E_SERVICES=none, no BASE_URL) (got $CALLS)"
fi

# ── Case 2: REMOTE mode, app healthy → polls, returns 0 ──────────────────────
# Remote mode = E2E_SERVICES=none and BASE_URL set. Stubbed curl returns 200.
test_case "remote_mode_healthy" "remote mode polls /api/health and returns 0 when healthy"
reset_stubs
echo "ok" > "$CURL_MODE_FILE"
OUT="$(
    export E2E_SERVICES=none
    export BASE_URL="https://preview-175.example.test"
    warm_remote_preview 2>&1
)"
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 when the preview is healthy"
CALLS="$(curl_call_count)"
if [[ "${CALLS:-0}" -ge 1 ]]; then
    _record_pass "warm_remote_preview polled the health endpoint at least once (got $CALLS)"
else
    _record_fail "warm_remote_preview polled the health endpoint at least once (got $CALLS)"
fi

# ── Case 3: REMOTE mode, never healthy → fail fast, clear message ────────────
# Stubbed curl always fails; stubbed clock jumps past the deadline so the bound
# is hit immediately (no 60s wait). Must return non-zero with a clear message.
test_case "remote_mode_never_healthy" "remote mode fails fast with a clear message when never healthy"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"
OUT="$(
    export E2E_SERVICES=none
    export BASE_URL="https://preview-175.example.test"
    warm_remote_preview 2>&1
)"
RC=$?
assert_exit_nonzero "$RC" "warm_remote_preview returns non-zero when the preview never becomes healthy"
assert_contains "$OUT" "https://preview-175.example.test" \
    "failure message names the preview URL being polled"
assert_contains "$OUT" "healthy" \
    "failure message mentions health (\"did not become healthy\")"

summarise
