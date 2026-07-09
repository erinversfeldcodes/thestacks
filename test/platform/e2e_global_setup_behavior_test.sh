#!/usr/bin/env bash
# test/platform/e2e_global_setup_behavior_test.sh
#
# Issue #175 — Guard B BEHAVIOURAL test wrapper.
#
# The static grep test (e2e_global_setup_guard_test.sh) only proves the
# globalSetup wiring; it cannot catch logic bugs (inverted guard, wrong URL, a
# loop that never really waits). This wrapper runs the executable behavioural
# test in e2e/global-setup.behavior.mjs, which EXECUTES the real default export
# with a stubbed global fetch (offline, instant) and asserts the actual
# behaviour, then propagates its pass/fail exit code into the platform suite.
#
# The .mjs test loads global-setup.ts via node's built-in TS type-stripping and
# a data: URL, so no standalone TS runner / transpiler is required. Node v18+
# ships global fetch; v22.13+/v23+ ship module.stripTypeScriptTypes (present on
# the repo's Node v26).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
BEHAVIOR="$REPO_ROOT/e2e/global-setup.behavior.mjs"

if ! command -v node >/dev/null 2>&1; then
    echo "FAIL: node not found on PATH — cannot run Guard B behavioural test" >&2
    exit 1
fi

if [[ ! -f "$BEHAVIOR" ]]; then
    echo "FAIL: behavioural test not found at $BEHAVIOR" >&2
    exit 1
fi

echo "# === e2e_global_setup_behavior (node) ==="
# --disable-warning silences the ExperimentalWarning from stripTypeScriptTypes so
# the output stays clean; the exit code is what gates the suite.
node --disable-warning=ExperimentalWarning "$BEHAVIOR"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    echo "# behavioural test PASSED"
else
    echo "# behavioural test FAILED (exit $RC)"
fi
exit "$RC"
