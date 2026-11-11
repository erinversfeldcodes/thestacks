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

# ⚠️ `scripts/` was outside this gate until 2026-10-20, and the reason it stayed
# outside is worth recording: the gap was known and deferred on the assumption
# that closing it would surface a pile of pre-existing findings. Measured when
# the assumption was finally tested — eleven files, **zero** ruff findings and
# **one** mypy error, a reused name whose two bindings disagreed. The deferral
# cost more than the work.
#
# ⛔ What was ungated is not incidental: the five proto generators, the
# billing-metrics push, the deploy's runtime-connection derivation, and the MCP
# server. The per-edit hook does run ruff on a file being changed, which is why
# this stayed invisible — a file is checked while somebody edits it and never
# again, so a regression arriving by a dependency bump, a formatter version
# change, or a file written by another script was ungated entirely.
(cd "$REPO_ROOT" && "$RUFF" check scripts --exclude '**/.venv')
(cd "$REPO_ROOT" && "$RUFF" format --check scripts --exclude '**/.venv')
(cd "$REPO_ROOT" && "$MYPY" scripts --exclude '.venv' --ignore-missing-imports)
