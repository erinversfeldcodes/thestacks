#!/usr/bin/env bash
set -euo pipefail

mix format
(cd frontend && npx elm-format --yes src/)
(cd apps/scraper && cargo fmt)
# ruff check --fix handles auto-fixable lint violations; ruff format handles style
(cd apps/vision && ruff check --fix . && ruff format .)
# sqlfluff fix auto-corrects SQL style violations
(cd dbt && sqlfluff fix models/ --templater jinja)
