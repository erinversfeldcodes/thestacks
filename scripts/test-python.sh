#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

# Unset PYTHONPATH so the venv is the sole source of packages.
# flake.nix already does this in its shellHook, but the script may be
# run from a shell that was loaded before the fix landed (or from a
# different environment manager). Belt-and-suspenders. See
# flake.nix's shellHook comment for the full rationale.
unset PYTHONPATH

# Local dev: pytest lives in apps/vision/.venv (created by setup.sh).
# CI: no setup.sh; pytest is pip-installed into actions/setup-python's
# runtime via requirements-dev.txt → resolves on PATH.
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
