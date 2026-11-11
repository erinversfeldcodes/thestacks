#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILED=0

# ⚠️ How many legs actually RAN, because all three can skip.
#
# Each of the three checks below skips when its tool or lockfile is absent —
# deliberately, so a developer without `licensir` is not blocked. But the three
# skips compose: with licensir absent and both lockfiles missing, every leg
# skipped, nothing was inspected, and this script printed "All licence checks
# passed." and exited 0. A clean exit for zero checks is the same claim as a
# clean exit for three, and a caller cannot tell them apart.
#
# The convention this follows is already in the tree: `scripts/security-squawk.sh`
# prints "This is a SKIP, not a pass — nothing was checked." and exits non-zero
# when it inspects no files. Same reasoning, same remedy.
#
# Only the all-skipped case refuses. One leg skipping while others run is still
# a real check, and failing that would block the ordinary local case this
# tolerance exists for.
RAN=0

echo "==> Checking Elixir dependency licences..."
if mix help licenses &>/dev/null 2>&1; then
    RAN=$((RAN + 1))
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
    RAN=$((RAN + 1))
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
    RAN=$((RAN + 1))
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

if [[ $RAN -eq 0 ]]; then
    echo ""
    echo "SKIP: all three licence checks skipped — licensir absent and no lockfiles found." >&2
    echo "      0 of 3 dependency trees inspected. This is a SKIP, not a pass." >&2
    exit 2
fi

echo ""
echo "All licence checks passed (${RAN} of 3 dependency trees inspected)."
