#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
fi

bash "$REPO_ROOT/scripts/check-e2e-vacuous-guards.sh"

bash "$REPO_ROOT/scripts/check-prose-assertions.sh"

bash "$REPO_ROOT/scripts/check-orphan-classes.sh"

bash "$REPO_ROOT/scripts/check-admin-token-routing.sh"

bash "$REPO_ROOT/scripts/check-session-expiry-coverage.sh"

bash "$REPO_ROOT/scripts/check-ports-wired.sh"

bash "$REPO_ROOT/scripts/check-css.sh"

bash "$REPO_ROOT/scripts/check-css-values.sh"

(cd frontend && npx elm-format --validate src/)
(cd frontend && npm audit)

if command -v npx &>/dev/null && (cd "$REPO_ROOT/frontend" && npx --yes elm-review --version &>/dev/null 2>&1); then
    (cd "$REPO_ROOT/frontend" && npx elm-review --config elm-review src/ tests/)
else
    echo "SKIP: elm-review not installed (npm install -g elm-review)"
fi
