#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(cd frontend && npx elm-format --validate src/)
(cd frontend && npm audit)

# elm-review: NoUnused rules
if command -v npx &>/dev/null && (cd "$REPO_ROOT/frontend" && npx --yes elm-review --version &>/dev/null 2>&1); then
    (cd "$REPO_ROOT/frontend" && npx elm-review --config elm-review src/ tests/)
else
    echo "SKIP: elm-review not installed (npm install -g elm-review)"
fi
