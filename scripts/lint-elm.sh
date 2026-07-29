#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Generate proto Elm decoders (required before elm-review can compile)
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh"
fi

# E2E test-suite integrity: no vacuous `if ((await …count()) > 0)` assertion
# guards (Issue #275). Cheap static grep; runs here so `just ci` (elm group) and
# the CI lint-elm job both enforce it.
bash "$REPO_ROOT/scripts/check-e2e-vacuous-guards.sh"

# Negative Elm assertions that cannot do their job (Issue #302). Sibling of the E2E guard check
# above: that one catches `if (count > 0)` wrappers in Playwright specs, this one catches
# `hasNot [ Selector.text "..." ]` that either matches nothing (can never fail) or is a strict
# substring of other rendered copy (can bind to the wrong element). Two real instances motivated it,
# including a SECURITY assertion disarmed by a one-word copy edit.
bash "$REPO_ROOT/scripts/check-prose-assertions.sh"

(cd frontend && npx elm-format --validate src/)
(cd frontend && npm audit)

# elm-review: NoUnused rules
if command -v npx &>/dev/null && (cd "$REPO_ROOT/frontend" && npx --yes elm-review --version &>/dev/null 2>&1); then
    (cd "$REPO_ROOT/frontend" && npx elm-review --config elm-review src/ tests/)
else
    echo "SKIP: elm-review not installed (npm install -g elm-review)"
fi
