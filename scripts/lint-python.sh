#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

# Unset PYTHONPATH — see scripts/test-python.sh for the rationale.
unset PYTHONPATH

(cd "$REPO_ROOT/apps/vision" && "$VENV/ruff" check .)
(cd "$REPO_ROOT/apps/vision" && "$VENV/ruff" format --check .)
(cd "$REPO_ROOT/apps/vision" && "$VENV/mypy" app/)
