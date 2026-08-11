#!/usr/bin/env bash

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
node --disable-warning=ExperimentalWarning "$BEHAVIOR"
RC=$?

if [[ "$RC" -eq 0 ]]; then
    echo "# behavioural test PASSED"
else
    echo "# behavioural test FAILED (exit $RC)"
fi
exit "$RC"
