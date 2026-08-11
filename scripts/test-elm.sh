#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
fi

output="$(cd frontend && npx elm-test 2>&1)" && exit_code=0 || exit_code=$?

echo "$output"

if [[ $exit_code -ne 0 ]]; then
    if echo "$output" | grep -qE "No \.elm files found|There are no tests"; then
        echo "No Elm tests found — skipping (add tests to frontend/tests/)."
        exit 0
    fi
    exit "$exit_code"
fi
