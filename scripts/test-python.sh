#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

(cd "$REPO_ROOT/apps/vision" && VISION_ENVIRONMENT=test "$VENV/pytest" --cov=app --cov-fail-under=80)
