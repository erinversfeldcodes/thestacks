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
# ⛔ `modal_app.py` IS IN SCOPE NOW. It was outside this gate — `app/` only —
# while holding the GPU cold-start reading the whole idle-GPU cost is derived
# from. Two unused-ignore errors sat in it unseen by CI, and a probe that
# hard-coded the cold flag passed 119 tests. The money measurement moved into
# that file, so the gate follows it.
(cd "$REPO_ROOT/apps/vision" && "$MYPY" app/ modal_app.py)

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
