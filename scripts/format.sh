#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

for pybin in "$HOME"/Library/Python/*/bin "$HOME/.local/bin"; do
    [[ -d "$pybin" ]] && export PATH="$pybin:$PATH"
done

mix format
(cd "$REPO_ROOT/frontend" && npx elm-format --yes src/)
(cd "$REPO_ROOT/apps/scraper" && cargo fmt)
(cd "$REPO_ROOT/apps/vision" && "$VENV/ruff" check --fix . && "$VENV/ruff" format .)
(cd "$REPO_ROOT/dbt" && sqlfluff fix models/ --templater jinja)
