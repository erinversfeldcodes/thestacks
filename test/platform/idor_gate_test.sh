#!/usr/bin/env bash
#
# Proves the live IDOR gate can fail.
#
# The check it guards compared the observed status against the literal "200",
# while the placement controller answers 204 on a successful delete. So a real
# cross-user deletion returned 204, missed the comparison, and was reported as
# "PASS: IDOR cross-user DELETE blocked" — the gate was structurally unable to
# fire from the day it was written, and a security review's CRITICAL finding
# sat open behind a green check.
#
# Every case below is a planted violation: the first two are the breach the
# gate exists to catch, the last two are a probe that never reached the
# authorization check and must not be mistaken for a refusal.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-idor-response.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

run_gate() {
    GATE_OUT="$(bash "$GATE" "$1" 2>&1)"
    GATE_RC=$?
}

test_case "gate_script_exists" "the decision script the CI step calls is present"
assert_path_exists "$GATE" "scripts/check-idor-response.sh exists"

test_case "breach_204" "a successful cross-user delete (204) FAILS the gate"
run_gate 204
assert_exit_nonzero "$GATE_RC" "204 is a breach and must fail the gate"
assert_contains "$GATE_OUT" "FAIL: IDOR" "it says why"
assert_contains "$GATE_OUT" "204" "it names the status it saw"

test_case "breach_200" "a 200 cross-user delete also FAILS"
run_gate 200
assert_exit_nonzero "$GATE_RC" "200 is a breach and must fail the gate"
# Without this, a MISSING script also satisfies the assertion above: bash exits
# 127 on a file that is not there, and 127 is non-zero.
assert_contains "$GATE_OUT" "FAIL: IDOR" "it failed for the right reason"

test_case "refusal_403" "a forbidden response PASSES"
run_gate 403
assert_exit_zero "$GATE_RC" "403 is a correct refusal"
assert_contains "$GATE_OUT" "PASS: IDOR" "it reports the pass"

test_case "refusal_404" "a not-found response PASSES"
run_gate 404
assert_exit_zero "$GATE_RC" "404 is a correct refusal"

test_case "unreached_000" "a connection failure FAILS rather than passing quietly"
run_gate 000
assert_exit_nonzero "$GATE_RC" "000 means the probe never reached the check"
assert_contains "$GATE_OUT" "proves nothing" "it says the run was uninformative"

test_case "unreached_500" "a server error FAILS rather than passing quietly"
run_gate 500
assert_exit_nonzero "$GATE_RC" "500 means the probe never reached the check"
assert_contains "$GATE_OUT" "FAIL: IDOR" "it failed for the right reason, not because the script is missing"

test_case "missing_argument" "no status code is a usage error, not a pass"
run_gate ""
assert_exit_nonzero "$GATE_RC" "an empty status must not pass"
assert_contains "$GATE_OUT" "usage:" "it failed as a usage error, not because the script is missing"

test_case "ci_calls_the_gate" "the IDOR step itself invokes the script"
if [[ -f "$CI_YML" ]]; then
    # Scoped to the step, not the whole file. Grepping all of ci.yml would be
    # satisfied by the script path appearing in any job — or in a comment — and
    # on failure it printed the YAML header, which tells the reader nothing.
    # A `/start/,/end/` range will NOT do: the step's own `- name:` line matches
    # both patterns, so awk opens and closes the range on that one line and the
    # body never appears. Flag, then stop at the NEXT step's name.
    STEP_TXT="$(awk '
        /- name: Security live . IDOR cross-user check/ { in_step = 1; print; next }
        in_step && /^      - name:/ { exit }
        in_step { print }
    ' "$CI_YML")"

    if [[ -z "$STEP_TXT" ]]; then
        _record_fail "the 'Security live — IDOR cross-user check' step is gone from ci.yml"
    else
        assert_contains "$STEP_TXT" "scripts/check-idor-response.sh" \
            "the IDOR step calls the gate (a runner nothing invokes is not a gate)"
        assert_not_contains "$STEP_TXT" '"${IDOR_CODE}" == "200"' \
            "the literal-200 comparison is gone from the step"
    fi
else
    _record_fail "ci.yml not found at $CI_YML"
fi

summarise
exit $?
