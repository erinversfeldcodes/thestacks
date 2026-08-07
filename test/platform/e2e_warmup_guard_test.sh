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
# the single word in CURL_MODE_FILE ("ok" → 0, anything else → non-zero), and
# prints the status code in CURL_CODE_FILE when asked for one via `-w`.
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
    # Honour `-w "%{http_code}"`. The login-POST warm loop reads the status off
    # curl's stdout (`code="$(curl … -w "%{http_code}" …)"`) and returns as soon
    # as it sees a non-502. A stub that wrote nothing to stdout left `code`
    # permanently empty, which made that success branch unreachable — and, with
    # a non-monotonic clock, the loop unable to exit at all (Issue #358).
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

# sleep: the login-POST warm loop backs off 3s between attempts. Record the
# calls (so the retry path can be asserted) but never actually wait — the clock
# stub below is what bounds the loop, and a real 3s backoff would only make the
# suite slow. NOTE: anything that needs a genuine wall-clock wait (the watchdog
# below) must use `command sleep` to bypass this.
sleep() {
    echo "sleep $*" >> "$SLEEP_LOG"
}
export -f sleep

# date: emulates `date +%s` with a MONOTONIC clock — call n returns
# DATE_BASE + n*DATE_STEP. It used to be a two-value step (base, then a fixed
# far-future value forever), which broke any deadline computed after the first
# call: `deadline = now + 60` was computed from the far-future value, so
# `while now < deadline` compared that same frozen value and stayed true
# forever. warm_remote_preview's login-POST loop then span for ever and the
# whole suite hung with no output (Issue #358). A monotonic clock makes an
# early-computed deadline trip fast AND a later-computed one actually arrive.
# DATE_STEP is a third of the 60s bounds under test, so each loop terminates in
# a few iterations while still going round more than once.
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
    # Count non-empty lines in the curl log. `grep -c` prints 0 and exits 1 when
    # there are no matches, so swallow the exit code and keep the single "0".
    local n
    n="$(grep -c . "$CURL_LOG" 2>/dev/null)" || true
    echo "${n:-0}"
}

sleep_call_count() {
    local n
    n="$(grep -c . "$SLEEP_LOG" 2>/dev/null)" || true
    echo "${n:-0}"
}

# ── Hard wall-clock bound on every call into the code under test ─────────────
# The Issue #358 failure mode was silence: a stub defect made a poll loop
# unbounded, so this suite (number 15 of 17 in run_all.sh) hung for ever and
# printed nothing at all. Every invocation now runs under a watchdog, so the
# next stub defect fails LOUDLY instead of hanging the runner.
CASE_TIMEOUT="${CASE_TIMEOUT:-15}"

with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local job=$!
    # The watchdog's own output goes to /dev/null: as a background child it
    # inherits the write end of any enclosing command substitution's pipe, and
    # holding that open would block the capture for the full timeout even when
    # the job succeeds. `command sleep` bypasses the no-op sleep stub above.
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

# A watchdog kill also produces a non-zero exit, which would let a
# "fails fast" assertion pass for the wrong reason. Assert the flag explicitly.
assert_no_timeout() {
    local msg="${1:-did not hang (no watchdog kill)}"
    if [[ -s "$TIMEOUT_FLAG" ]]; then
        _record_fail "$msg — HUNG: $(cat "$TIMEOUT_FLAG")"
    else
        _record_pass "$msg"
    fi
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

# ── Case 2: REMOTE mode, app healthy → polls, returns 0 ──────────────────────
# Remote mode = E2E_SERVICES=none and BASE_URL set. Stubbed curl returns 200.
# Returning 0 is not enough on its own: the warmup has TWO stages (GET
# /api/health, then the login POST path), and the whole point of the second is
# that it confirms the POST path served a request. So assert the function
# reached that SUCCESS branch — its "Login POST path warm (HTTP …)" line — and
# that it really did POST to /api/auth/login.
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

# ── Case 3: REMOTE mode, never healthy → fail fast, clear message ────────────
# Stubbed curl always fails; stubbed clock jumps past the deadline so the bound
# is hit immediately (no 60s wait). Must return non-zero with a clear message.
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

# ── Case 4: REMOTE mode, health 200 but login POST always 502 ────────────────
# The cold-start case Issue #269 finding #2 is actually about: GET /api/health
# answers while the login POST still 502s. The loop must exhaust its 60s bound,
# warn, and then PROCEED (return 0) — Playwright's setup project retries — and
# above all it must terminate. This is the branch the old two-value clock stub
# could never leave.
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
