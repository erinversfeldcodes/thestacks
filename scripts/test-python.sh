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

(cd "$REPO_ROOT/apps/vision" && VISION_ENVIRONMENT=test "$VENV/pytest" --cov=app --cov-fail-under=80)
