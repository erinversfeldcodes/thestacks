#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILED=0

echo "==> Checking Elixir dependency licences..."
if mix help licenses &>/dev/null 2>&1; then
    if mix licenses 2>/dev/null | grep -E '\b(GPL|AGPL)\b'; then
        echo "ERROR: GPL or AGPL licence found in Elixir dependencies." >&2
        FAILED=1
    else
        echo "  Elixir: no GPL/AGPL licences found."
    fi
else
    echo "SKIP: licensir not installed."
    echo "  Add to mix.exs: {:licensir, \"~> 0.7\", only: :dev, runtime: false}"
fi

if [[ -f "$REPO_ROOT/e2e/package-lock.json" ]]; then
    echo ""
    echo "==> Checking e2e Node dependency licences..."
    if ! (cd "$REPO_ROOT/e2e" && npx --yes license-checker --failOn 'GPL;AGPL' 2>/dev/null); then
        echo "ERROR: GPL or AGPL licence found in e2e Node dependencies." >&2
        FAILED=1
    else
        echo "  e2e Node: no GPL/AGPL licences found."
    fi
else
    echo ""
    echo "SKIP: e2e/package-lock.json not found — skipping e2e Node licence check."
fi

if [[ -f "$REPO_ROOT/frontend/package-lock.json" ]]; then
    echo ""
    echo "==> Checking frontend Node dependency licences..."
    if ! (cd "$REPO_ROOT/frontend" && npx --yes license-checker --failOn 'GPL;AGPL' 2>/dev/null); then
        echo "ERROR: GPL or AGPL licence found in frontend Node dependencies." >&2
        FAILED=1
    else
        echo "  Frontend Node: no GPL/AGPL licences found."
    fi
else
    echo ""
    echo "SKIP: frontend/package-lock.json not found — skipping frontend Node licence check."
fi

if [[ $FAILED -ne 0 ]]; then
    exit 1
fi

echo ""
echo "All licence checks passed."
