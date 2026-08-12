#!/usr/bin/env bash
# test/platform/e2e_warmup_guard_test.sh
#
# warm the preview app before E2E setup.
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

WAIT_FN="$(awk '/^wait_for_health\(\)/,/^}/' "$E2E_SCRIPT")"
WARM_FN="$(awk '/^warm_remote_preview\(\)/,/^}/' "$E2E_SCRIPT")"

# shellcheck disable=SC2294
eval "$WAIT_FN"
# shellcheck disable=SC2294
eval "$WARM_FN"

CURL_LOG="$(mktemp)"
CURL_MODE_FILE="$(mktemp)"
CURL_CODE_FILE="$(mktemp)"
SLEEP_LOG="$(mktemp)"
DATE_COUNTER="$(mktemp)"
TIMEOUT_FLAG="$(mktemp)"
trap 'rm -f "$CURL_LOG" "$CURL_MODE_FILE" "$CURL_CODE_FILE" "$SLEEP_LOG" "$DATE_COUNTER" "$TIMEOUT_FLAG"' EXIT

echo "fail" > "$CURL_MODE_FILE"
echo "200" > "$CURL_CODE_FILE"
echo 0 > "$DATE_COUNTER"

curl() {
    echo "call $*" >> "$CURL_LOG"
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "-w" ]]; then
            cat "$CURL_CODE_FILE"
            break
        fi
    done
    if [[ "$(cat "$CURL_MODE_FILE")" == "ok" ]]; then
        return 0
    fi
    return 1
}
export -f curl

sleep() {
    echo "sleep $*" >> "$SLEEP_LOG"
}
export -f sleep

export DATE_BASE=1000
export DATE_STEP=20
date() {
    local n
    n="$(cat "$DATE_COUNTER")"
    echo $((n + 1)) > "$DATE_COUNTER"
    echo $((DATE_BASE + n * DATE_STEP))
}
export -f date

reset_stubs() {
    : > "$CURL_LOG"
    : > "$SLEEP_LOG"
    : > "$TIMEOUT_FLAG"
    echo 0 > "$DATE_COUNTER"
}

curl_call_count() {
    local n
    n="$(grep -c . "$CURL_LOG" 2>/dev/null)" || true
    echo "${n:-0}"
}

sleep_call_count() {
    local n
    n="$(grep -c . "$SLEEP_LOG" 2>/dev/null)" || true
    echo "${n:-0}"
}

CASE_TIMEOUT="${CASE_TIMEOUT:-15}"

with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local job=$!
    (
        command sleep "$secs"
        kill -9 "$job" 2>/dev/null && echo "killed after ${secs}s" > "$TIMEOUT_FLAG"
    ) >/dev/null 2>&1 &
    local watchdog=$!
    local rc=0
    wait "$job" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    return "$rc"
}

assert_no_timeout() {
    local msg="${1:-did not hang (no watchdog kill)}"
    if [[ -s "$TIMEOUT_FLAG" ]]; then
        _record_fail "$msg — HUNG: $(cat "$TIMEOUT_FLAG")"
    else
        _record_pass "$msg"
    fi
}

test_case "warm_remote_preview_defined" "warm_remote_preview is defined in scripts/test-e2e.sh"
assert_contains "$WARM_FN" "warm_remote_preview" \
    "scripts/test-e2e.sh defines a warm_remote_preview function"
if declare -F warm_remote_preview >/dev/null 2>&1; then
    _record_pass "warm_remote_preview is callable after extraction/eval"
else
    _record_fail "warm_remote_preview is callable after extraction/eval (function not found)"
fi

test_case "local_mode_no_poll" "local mode performs no health poll and returns 0"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"   # even if it tried, curl would fail — proves it doesn't try
(
    unset BASE_URL
    unset E2E_SERVICES
    with_timeout "$CASE_TIMEOUT" warm_remote_preview
)
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 in local mode"
assert_no_timeout "warm_remote_preview terminated in local mode"
CALLS="$(curl_call_count)"
if [[ "$CALLS" -eq 0 ]]; then
    _record_pass "warm_remote_preview made zero curl calls in local mode"
else
    _record_fail "warm_remote_preview made zero curl calls in local mode (got $CALLS)"
fi

test_case "services_none_no_base_url_no_poll" "E2E_SERVICES=none with unset BASE_URL is a no-op"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"   # any accidental call would be a visible failure
(
    export E2E_SERVICES=none
    unset BASE_URL
    with_timeout "$CASE_TIMEOUT" warm_remote_preview
)
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 when E2E_SERVICES=none and BASE_URL is unset"
assert_no_timeout "warm_remote_preview terminated with E2E_SERVICES=none and no BASE_URL"
CALLS="$(curl_call_count)"
if [[ "$CALLS" -eq 0 ]]; then
    _record_pass "warm_remote_preview made zero curl calls (E2E_SERVICES=none, no BASE_URL)"
else
    _record_fail "warm_remote_preview made zero curl calls (E2E_SERVICES=none, no BASE_URL) (got $CALLS)"
fi

test_case "remote_mode_healthy" "remote mode polls /api/health and returns 0 when healthy"
reset_stubs
echo "ok" > "$CURL_MODE_FILE"
echo "200" > "$CURL_CODE_FILE"
OUT="$(
    export E2E_SERVICES=none
    export BASE_URL="https://preview-175.example.test"
    with_timeout "$CASE_TIMEOUT" warm_remote_preview 2>&1
)"
RC=$?
assert_exit_zero "$RC" "warm_remote_preview returns 0 when the preview is healthy"
assert_no_timeout "warm_remote_preview terminated when the preview is healthy"
CALLS="$(curl_call_count)"
if [[ "${CALLS:-0}" -ge 1 ]]; then
    _record_pass "warm_remote_preview polled the health endpoint at least once (got $CALLS)"
else
    _record_fail "warm_remote_preview polled the health endpoint at least once (got $CALLS)"
fi
assert_contains "$OUT" "Login POST path warm (HTTP 200)" \
    "warm_remote_preview reaches the login-POST success branch and reports the status"
CURL_ARGS="$(cat "$CURL_LOG")"
assert_contains "$CURL_ARGS" "https://preview-175.example.test/api/health" \
    "stage 1 polled the preview health endpoint"
assert_contains "$CURL_ARGS" "-X POST https://preview-175.example.test/api/auth/login" \
    "stage 2 warmed the login POST path (not just health)"
assert_not_contains "$OUT" "not warm yet" \
    "a 200 on the first login POST attempt needs no retry"

test_case "remote_mode_never_healthy" "remote mode fails fast with a clear message when never healthy"
reset_stubs
echo "fail" > "$CURL_MODE_FILE"
OUT="$(
    export E2E_SERVICES=none
    export BASE_URL="https://preview-175.example.test"
    with_timeout "$CASE_TIMEOUT" warm_remote_preview 2>&1
)"
RC=$?
assert_exit_nonzero "$RC" "warm_remote_preview returns non-zero when the preview never becomes healthy"
assert_no_timeout "warm_remote_preview gave up on its own deadline (not killed by the watchdog)"
assert_contains "$OUT" "https://preview-175.example.test" \
    "failure message names the preview URL being polled"
assert_contains "$OUT" "healthy" \
    "failure message mentions health (\"did not become healthy\")"

test_case "remote_mode_login_never_warm" \
    "health 200 + login POST 502 forever → retries, warns, proceeds, terminates"
reset_stubs
echo "ok" > "$CURL_MODE_FILE"     # GET /api/health succeeds
echo "502" > "$CURL_CODE_FILE"    # every login POST comes back 502
OUT="$(
    export E2E_SERVICES=none
    export BASE_URL="https://preview-175.example.test"
    with_timeout "$CASE_TIMEOUT" warm_remote_preview 2>&1
)"
RC=$?
assert_no_timeout "the login-POST warm loop honours its own 60s bound"
assert_exit_zero "$RC" "warm_remote_preview proceeds (returns 0) after warning"
assert_contains "$OUT" "Login POST not warm yet (HTTP 502)" \
    "each failed attempt reports the status it saw"
assert_contains "$OUT" "WARNING: login POST path still returning 502" \
    "gives up with a warning that names the status"
assert_not_contains "$OUT" "Login POST path warm" \
    "does not claim the POST path is warm when it never was"
SLEEPS="$(sleep_call_count)"
if [[ "${SLEEPS:-0}" -ge 1 ]]; then
    _record_pass "backed off between login POST attempts (got $SLEEPS sleeps)"
else
    _record_fail "backed off between login POST attempts (got $SLEEPS sleeps)"
fi

summarise
