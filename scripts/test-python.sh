#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

unset PYTHONPATH

PYTEST=""
if [[ -x "$VENV/pytest" ]]; then
    PYTEST="$VENV/pytest"
elif command -v pytest &>/dev/null; then
    PYTEST="$(command -v pytest)"
fi
if [[ -z "$PYTEST" ]]; then
    echo "ERROR: pytest not found." >&2
    echo "    Local dev: run ./setup.sh to populate apps/vision/.venv" >&2
    echo "    CI: \`pip install -r apps/vision/requirements-dev.txt\` before invoking" >&2
    exit 1
fi

(cd "$REPO_ROOT/apps/vision" && VISION_ENVIRONMENT=test "$PYTEST" --cov=app --cov-fail-under=80)
