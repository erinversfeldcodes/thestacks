#!/usr/bin/env bash
# scripts/deploy-preview.sh — deploy a preview stack and warm the vision pipeline.
#
# Does NOT run tests or clean up — that is ci.sh's responsibility.
# Use this script directly for manual inspection of a deployed preview stack.
# To deploy WITH tests and cleanup, run scripts/ci.sh (which calls this script).
#
# Usage:
#   scripts/deploy-preview.sh                      # tears down first (recommended)
#   scripts/deploy-preview.sh --branch my-feature-branch
#   scripts/deploy-preview.sh --reuse              # incremental redeploy; faster, flakier (#305)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ── Parse args ────────────────────────────────────────────────────────────────
BRANCH_ARG=""
REUSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH_ARG="--branch $2"; shift 2 ;;
        --reuse)  REUSE=1; shift ;;
        *) shift ;;
    esac
done

# Shared derivation (honours optional PREVIEW_SUFFIX — see the lib header).
BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"
derive_preview_names "$BRANCH"
CORE_APP="${PREVIEW_CORE_APP}"
CORE_URL="https://${CORE_APP}.fly.dev"

# ── Tear down first, unless told otherwise (Issue #305) ──────────────────────
#
# ⛔ **Redeploying onto a live preview stack is the unreliable path, measured.** On 2026-07-29 three
# consecutive redeploys onto a running stack failed in three different ways — died mid image-push, the
# release command raced a cold Neon branch, and worst of all one **half-succeeded**: it created the
# branch, deployed the app, served `200`s, and never ran migrations or the seed. That last one worked
# only because a preview branch is copy-on-write from `staging`, so the schema and staging's users
# were already present. A stack missing every fixture answered requests perfectly, and the failure
# read as an application bug.
#
# Every deploy that began with a full teardown passed first time (3 for 3).
#
# So teardown is the DEFAULT and reuse is opt-in. `--reuse` skips it when you genuinely want an
# incremental redeploy and accept the flakiness — the fast path for iterating on app code where the
# DB and fixtures are already known-good.
if [[ "$REUSE" -eq 1 ]]; then
    echo "==> --reuse: skipping teardown, redeploying onto the existing stack."
    echo "    (If this deploy behaves strangely, tear down and retry before debugging the app.)"
else
    echo "==> Tearing down any existing preview stack first (Issue #305; use --reuse to skip)..."
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" ${BRANCH_ARG} || {
        echo "FAIL deploy: teardown failed; not deploying onto an unknown stack state" >&2
        exit 1
    }
fi

# ── Deploy ────────────────────────────────────────────────────────────────────
# deploy-stack.sh now owns the Modal vision warmup at the end of its run
# (6 parallel canary uploads matching the gate/E2E burst pattern). This
# script is a thin PR-scoped wrapper — no additional warmup needed here.
# If you're looking for the warmup logic, it lives in scripts/deploy-stack.sh
# under the "Vision pipeline warmup" section.
bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}
