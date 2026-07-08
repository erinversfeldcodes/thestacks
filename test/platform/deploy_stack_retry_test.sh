#!/usr/bin/env bash
# test/platform/deploy_stack_retry_test.sh
#
# Covers reviewer P1 #1: deploy-stack.sh in prod mode must retry-once on
# component deploy failures, and hard-exit on the second attempt's failure.
#
# Rather than stubbing fly's full surface (which would be fragile and
# orthogonal to this fix), we exercise the retry helper itself — it is a
# plain shell function sourced from the script's top-level that the fix
# relies on. That gives us a deterministic test without spinning up Fly.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

# Extract the `deploy_with_retry` function body from deploy-stack.sh and
# eval it so we can call it in isolation. Anything above `# ── Preflight`
# is safe to evaluate (no side effects — just function + var definitions
# before any real work). We cap the extraction at that sentinel.
EXTRACTED="$(awk '
    /^# ── Preflight/ { exit }
    /^deploy_with_retry\(\)/,/^}/ { print }
' "$REPO_ROOT/scripts/deploy-stack.sh")"

if [[ -z "$EXTRACTED" ]]; then
    echo "FAIL: could not extract deploy_with_retry from deploy-stack.sh" >&2
    exit 1
fi

# shellcheck disable=SC2294
eval "$EXTRACTED"

# ── Case 1: command succeeds first try → retry helper returns 0 ──────────────
test_case "retry_first_try_succeeds" "command that succeeds on first call → exit 0"
deploy_with_retry "phony" true
RC=$?
assert_exit_zero "$RC" "deploy_with_retry returns 0 when the command succeeds immediately"

# ── Case 2: command fails once, succeeds on retry → helper returns 0 ─────────
test_case "retry_second_try_succeeds" "command fails once then succeeds → exit 0"
# A tiny stateful command: first call fails, second call succeeds. We model
# this with a counter file so a pipe-free `bash -c` can track state.
COUNTER="$(mktemp)"
echo 0 > "$COUNTER"
trap 'rm -f "$COUNTER"' EXIT

flaky_cmd() {
    local n
    n=$(< "$COUNTER")
    echo $((n + 1)) > "$COUNTER"
    if [[ "$n" -eq 0 ]]; then
        return 1
    fi
    return 0
}
export -f flaky_cmd
OUT="$(deploy_with_retry "flaky" flaky_cmd 2>&1)"
RC=$?
assert_exit_zero "$RC" "deploy_with_retry returns 0 after one retry"
assert_contains "$OUT" "retry" "output announces the retry"

# ── Case 3: command fails twice → helper returns non-zero ────────────────────
test_case "retry_twice_fails" "command fails both attempts → exit non-zero with clear error"
OUT="$(deploy_with_retry "always-fails" false 2>&1)"
RC=$?
assert_exit_nonzero "$RC" "deploy_with_retry returns non-zero after two failed attempts"
assert_contains "$OUT" "failed twice" "error message mentions the twice-failure"
assert_contains "$OUT" "always-fails" "error names the failed component"

summarise
