#!/usr/bin/env bash
#
# Decides whether a cross-user DELETE was correctly refused, given the HTTP
# status the probe observed.
#
# Called by the "Security live — IDOR cross-user check" step of the
# `deploy-preview` job in .github/workflows/ci.yml. It lives here rather than
# inline in the YAML so the decision can be exercised directly — see
# test/platform/idor_gate_test.sh, which feeds it a breach and asserts it fails.
#
# Three outcomes, and the third is the one that matters:
#
#   2xx            -> FAIL. The delete succeeded, so one user removed another
#                    user's placement. Note that success here is 204, not 200:
#                    the check this replaced compared against the literal "200"
#                    while the controller answers 204, so a real breach scored
#                    as a pass and the gate could never fire.
#   403 | 404      -> PASS. The authorization check refused it. Either is
#                    correct; 404 additionally declines to confirm the row
#                    exists.
#   anything else  -> FAIL. A 000 (connection refused), a 5xx, or a redirect
#                    means the request never reached the authorization check,
#                    so the gate learned nothing. Reporting that as a pass is
#                    how a probe that silently stopped working goes unnoticed.

set -uo pipefail

CODE="${1:-}"

if [[ -z "$CODE" ]]; then
    echo "usage: $(basename "$0") <http-status-code>" >&2
    exit 2
fi

case "$CODE" in
    2[0-9][0-9])
        echo "FAIL: IDOR — user2 deleted user1's placement (HTTP ${CODE})"
        exit 1
        ;;
    403 | 404)
        echo "PASS: IDOR cross-user DELETE blocked (HTTP ${CODE})"
        exit 0
        ;;
    *)
        echo "FAIL: IDOR — unexpected response (HTTP ${CODE}); the probe did not reach the authorization check, so this run proves nothing"
        exit 1
        ;;
esac
