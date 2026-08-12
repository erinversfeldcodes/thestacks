#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

unset PYTHONPATH

RUFF=""
MYPY=""
if [[ -x "$VENV/ruff" ]]; then
    RUFF="$VENV/ruff"
elif command -v ruff &>/dev/null; then
    RUFF="$(command -v ruff)"
fi
if [[ -x "$VENV/mypy" ]]; then
    MYPY="$VENV/mypy"
elif command -v mypy &>/dev/null; then
    MYPY="$(command -v mypy)"
fi
if [[ -z "$RUFF" || -z "$MYPY" ]]; then
    echo "ERROR: ruff and/or mypy not found." >&2
    echo "    Local dev: run ./setup.sh to populate apps/vision/.venv" >&2
    echo "    CI: \`pip install ruff mypy\` before invoking this script" >&2
    exit 1
fi

(cd "$REPO_ROOT/apps/vision" && "$RUFF" check .)
(cd "$REPO_ROOT/apps/vision" && "$RUFF" format --check .)
(cd "$REPO_ROOT/apps/vision" && "$MYPY" app/)
