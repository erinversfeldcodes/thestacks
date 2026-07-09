#!/usr/bin/env bash
# test/platform/deploy_stack_neon_lookup_test.sh
#
# Covers Issue #177: deploy-stack.sh masks transient Neon API failures as
# "parent branch not found". The inline `curl … | python3 … 2>/dev/null || true`
# pipelines (parent-branch lookup ~L263-271, sibling stale-branch lookup ~L279-287)
# collapse ANY failure — network blip, HTTP 5xx/429, bad body — into an empty id,
# which the caller then misreports as "branch not found".
#
# The fix introduces a top-level shell function:
#
#     neon_branch_id_by_name <project_id> <branch_name>
#
# Contract this suite pins down:
#   - SUCCESS (2xx + parseable {"branches":[...]}): prints the matching branch's
#     `id` to stdout, or an EMPTY string if the name is genuinely absent from a
#     non-empty list; returns 0. (Empty + exit 0 == "genuinely absent".)
#   - PERSISTENT API FAILURE (curl network error, or HTTP 5xx/429 after a bounded
#     number of retries): prints a distinct message containing "Neon API" (NOT
#     "not found") to STDERR and returns NON-ZERO. Must retry a bounded number of
#     times with backoff before giving up.
#   - Reads the API key from the environment (NEON_STAGING_API_KEY).
#
# Style mirrors deploy_stack_retry_test.sh: awk-extract the top-level function,
# eval it, stub `curl`/`sleep` so nothing hits the network or really sleeps, and
# drive behaviour deterministically via a call-counter file.
#
# ─────────────────────────────────────────────────────────────────────────────
# ASSUMED curl INVOCATION SHAPE (the implementer MUST match this so the
# extract-and-eval stub stays compatible):
#
#   response="$(curl -sS … -w '\n%{http_code}' \
#       -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
#       "https://console.neon.tech/api/v2/projects/${project_id}/branches")"
#   curl_rc=$?
#
#   * curl's stdout is:  <json-body>\n<http_status>
#     i.e. the JSON body followed by a newline and the numeric HTTP status as
#     the FINAL line (from `-w '\n%{http_code}'`).
#   * The function inspects BOTH:
#       - curl's exit status ($?) → non-zero means a network/transport error.
#       - the final-line HTTP code → non-2xx (esp. 5xx/429) means an API error.
#   * On transient failure it retries a BOUNDED number of times (> 1 attempt),
#     with `sleep` between attempts, before giving up non-zero.
#
# The stub below emits exactly `printf '%s\n%s' "<body>" "<code>"` and returns a
# chosen exit code, so it is compatible with the `-w '\n%{http_code}'` form.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

# ── Extract the (not-yet-existing) top-level `neon_branch_id_by_name` function ──
# from `neon_branch_id_by_name()` at column 0 down to the closing `}` at column 0,
# exactly like deploy_stack_retry_test.sh does for deploy_with_retry.
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

# ── Deterministic, offline stubs ──────────────────────────────────────────────
# No real backoff — `sleep` becomes a no-op so bounded retries run instantly.
sleep() { :; }

# Shared call-counter file so `curl` invocations inside command-substitution
# subshells are observable from the parent test process.
CURL_CALLS="$(mktemp)"
ERRFILE="$(mktemp)"
trap 'rm -f "$CURL_CALLS" "$ERRFILE"' EXIT

reset_calls() { echo 0 > "$CURL_CALLS"; }
call_count()  { cat "$CURL_CALLS"; }
bump()        { local n; n="$(cat "$CURL_CALLS")"; echo $((n + 1)) > "$CURL_CALLS"; }

export NEON_STAGING_API_KEY="test-key-not-real"
PROJECT_ID="royal-boat-46711655"

# ── Case 1: transient API error on EVERY attempt (HTTP 429) ───────────────────
# → non-zero exit, stderr mentions "Neon API" and NOT "not found", curl retried.
test_case "transient_api_error" "HTTP 429 every attempt → non-zero, distinct 'Neon API' error, bounded retry"
curl() {
    bump
    # Body + newline + HTTP status, per the assumed `-w '\n%{http_code}'` shape.
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
# Pin the exact bound (implementation's max_attempts=3) so silently shrinking
# the retry budget is caught, not just "retried at least once".
if [[ "$CALLS" -eq 3 ]]; then
    _record_pass "curl retried up to the bound (called $CALLS times) before giving up"
else
    _record_fail "expected exactly 3 curl calls (max_attempts=3), got $CALLS"
fi

# ── Case 2: success + branch genuinely ABSENT ─────────────────────────────────
# → prints EMPTY string, returns 0 (caller emits its own 'not found').
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

# ── Case 3: success + branch PRESENT ──────────────────────────────────────────
# → prints the matching branch id, returns 0.
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

# ── Case 3b: NON-transient 4xx (auth) → fail fast, no retry ───────────────────
# A bad/expired NEON_STAGING_API_KEY (HTTP 401/403) is the issue's OWN motivating
# scenario. It is an API failure, NOT a missing branch, and — unlike 429/5xx — it
# must NOT be retried (a bad key won't fix itself). Pins the non-transient guard.
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

# ── Case 3c: branch name containing a single quote → no injection breakage ────
# A git ref / branch name with a single quote (e.g. preview/foo'bar) must not
# break the success-parse step. If the name is interpolated into the python
# source it produces a SyntaxError → empty stdout → the branch is silently
# misclassified as absent. The name must be passed OUT-OF-BAND (argv), not
# baked into the python literal.
test_case "branch_name_with_quote" "200 body with a single-quoted branch name → resolves the id (no injection)"
curl() {
    bump
    # Branch literally named  preview/foo'bar  (the ' is the danger char).
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

# ── Case 4 (nice-to-have): transient network error THEN success ───────────────
# First attempt: curl transport error (non-zero exit). Second: 200 with branch.
# → retry recovers, prints the id, returns 0, curl called exactly twice.
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
