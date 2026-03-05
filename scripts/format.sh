#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO_ROOT/apps/vision/.venv/bin"

# Ensure pip-installed tools (sqlfluff) are on PATH
for pybin in "$HOME"/Library/Python/*/bin "$HOME/.local/bin"; do
    [[ -d "$pybin" ]] && export PATH="$pybin:$PATH"
done

mix format
(cd "$REPO_ROOT/frontend" && npx elm-format --yes src/)
(cd "$REPO_ROOT/apps/scraper" && cargo fmt)
# ruff check --fix handles auto-fixable lint violations; ruff format handles style
(cd "$REPO_ROOT/apps/vision" && "$VENV/ruff" check --fix . && "$VENV/ruff" format .)
# sqlfluff fix auto-corrects SQL style violations
(cd "$REPO_ROOT/dbt" && sqlfluff fix models/ --templater jinja)
