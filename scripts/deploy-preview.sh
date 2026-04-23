#!/usr/bin/env bash
# scripts/deploy-preview.sh — deploy a preview stack and warm the vision pipeline.
#
# Does NOT run tests or clean up — that is ci.sh's responsibility.
# Use this script directly for manual inspection of a deployed preview stack.
# To deploy WITH tests and cleanup, run scripts/ci.sh (which calls this script).
#
# Usage:
#   scripts/deploy-preview.sh
#   scripts/deploy-preview.sh --branch my-feature-branch

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ── Parse args ────────────────────────────────────────────────────────────────
BRANCH_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH_ARG="--branch $2"; shift 2 ;;
        *) shift ;;
    esac
done

BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"
CORE_APP="stacks-core-pr-${SANITISED}"
CORE_URL="https://${CORE_APP}.fly.dev"

# ── Deploy ────────────────────────────────────────────────────────────────────
# deploy-stack.sh now owns the Modal vision warmup at the end of its run
# (6 parallel canary uploads matching the gate/E2E burst pattern). This
# script is a thin PR-scoped wrapper — no additional warmup needed here.
# If you're looking for the warmup logic, it lives in scripts/deploy-stack.sh
# under the "Vision pipeline warmup" section.
bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}
