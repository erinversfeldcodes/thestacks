#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

EXTRACTED="$(awk '/^neon_branch_id_by_name\(\)/,/^}/' "$REPO_ROOT/scripts/deploy-stack.sh")"

test_case "function_extractable" "neon_branch_id_by_name is defined at top-level in deploy-stack.sh"
if [[ -n "$EXTRACTED" ]]; then
    _record_pass "extracted neon_branch_id_by_name from deploy-stack.sh"
else
    _record_fail "neon_branch_id_by_name not found in scripts/deploy-stack.sh (not yet implemented)"
fi

# eval'ing an empty string is a harmless no-op; the function simply stays
# undefined and the calls below fail with a meaningful command-not-found RED.
# shellcheck disable=SC2294
eval "$EXTRACTED"

sleep() { :; }

CURL_CALLS="$(mktemp)"
ERRFILE="$(mktemp)"
trap 'rm -f "$CURL_CALLS" "$ERRFILE"' EXIT

reset_calls() { echo 0 > "$CURL_CALLS"; }
call_count()  { cat "$CURL_CALLS"; }
bump()        { local n; n="$(cat "$CURL_CALLS")"; echo $((n + 1)) > "$CURL_CALLS"; }

export NEON_STAGING_API_KEY="test-key-not-real"
PROJECT_ID="royal-boat-46711655"

test_case "transient_api_error" "HTTP 429 every attempt → non-zero, distinct 'Neon API' error, bounded retry"
curl() {
    bump
    printf '%s\n%s' '{"message":"rate limited"}' '429'
    return 0   # curl transport succeeded; the API returned 429
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "staging" 2>"$ERRFILE")"
RC=$?
ERR="$(cat "$ERRFILE")"
assert_exit_nonzero "$RC" "persistent 429 → non-zero exit"
assert_contains "$ERR" "Neon API" "stderr names the Neon API (not a phantom missing branch)"
assert_not_contains "$ERR" "not found" "transient failure is NOT misreported as 'not found'"
CALLS="$(call_count)"
if [[ "$CALLS" -eq 3 ]]; then
    _record_pass "curl retried up to the bound (called $CALLS times) before giving up"
else
    _record_fail "expected exactly 3 curl calls (max_attempts=3), got $CALLS"
fi

test_case "success_branch_absent" "200 body without the target branch → empty stdout, exit 0"
curl() {
    bump
    printf '%s\n%s' \
        '{"branches":[{"id":"br-other-111","name":"main"},{"id":"br-other-222","name":"dev"}]}' \
        '200'
    return 0
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "staging" 2>"$ERRFILE")"
RC=$?
assert_exit_zero "$RC" "successful lookup of an absent branch returns 0"
if [[ -z "$OUT" ]]; then
    _record_pass "prints empty string for a genuinely-absent branch"
else
    _record_fail "expected empty stdout for absent branch, got '$OUT'"
fi

test_case "success_branch_present" "200 body containing the target branch → prints its id, exit 0"
curl() {
    bump
    printf '%s\n%s' \
        '{"branches":[{"id":"br-icy-boat-anxeoufm","name":"staging"},{"id":"br-other","name":"main"}]}' \
        '200'
    return 0
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "staging" 2>"$ERRFILE")"
RC=$?
assert_exit_zero "$RC" "successful lookup of a present branch returns 0"
assert_contains "$OUT" "br-icy-boat-anxeoufm" "prints the matching branch id"
assert_not_contains "$OUT" "br-other" "prints only the matched id, not sibling ids"

test_case "non_transient_4xx" "HTTP 401 (bad key) → non-zero, 'Neon API' error, NOT retried (exactly 1 call)"
curl() {
    bump
    printf '%s\n%s' '{"message":"unauthorized"}' '401'
    return 0   # curl transport succeeded; the API rejected auth
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "staging" 2>"$ERRFILE")"
RC=$?
ERR="$(cat "$ERRFILE")"
assert_exit_nonzero "$RC" "non-transient 401 → non-zero exit"
assert_contains "$ERR" "Neon API" "stderr names the Neon API (auth failure, not a phantom missing branch)"
assert_not_contains "$ERR" "not found" "auth failure is NOT misreported as 'not found'"
CALLS="$(call_count)"
if [[ "$CALLS" -eq 1 ]]; then
    _record_pass "curl called exactly once — a non-transient 4xx is not retried"
else
    _record_fail "expected exactly 1 curl call (no retry on 401), got $CALLS"
fi

test_case "branch_name_with_quote" "200 body with a single-quoted branch name → resolves the id (no injection)"
curl() {
    bump
    printf '%s\n%s' \
        '{"branches":[{"id":"br-other","name":"main"},{"id":"br-quote-999","name":"preview/foo'\''bar"}]}' \
        '200'
    return 0
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "preview/foo'bar" 2>"$ERRFILE")"
RC=$?
assert_exit_zero "$RC" "lookup of a single-quoted branch name returns 0"
assert_contains "$OUT" "br-quote-999" "resolves the id for a name containing a single quote"

test_case "transient_then_success" "network error then 200 → retry recovers, prints id, exit 0"
curl() {
    bump
    local n; n="$(call_count)"
    if [[ "$n" -eq 1 ]]; then
        return 7   # curl "couldn't connect" class transport error; no usable body
    fi
    printf '%s\n%s' \
        '{"branches":[{"id":"br-icy-boat-anxeoufm","name":"staging"}]}' \
        '200'
    return 0
}
reset_calls
: > "$ERRFILE"
OUT="$(neon_branch_id_by_name "$PROJECT_ID" "staging" 2>"$ERRFILE")"
RC=$?
assert_exit_zero "$RC" "retry after a transient network error succeeds (exit 0)"
assert_contains "$OUT" "br-icy-boat-anxeoufm" "recovered lookup prints the branch id"
CALLS="$(call_count)"
if [[ "$CALLS" -eq 2 ]]; then
    _record_pass "curl called exactly twice (one failure, one success)"
else
    _record_fail "expected exactly 2 curl calls (fail then succeed), got $CALLS"
fi

summarise
