#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

BRANCH_ARG=""
REUSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH_ARG="--branch $2"; shift 2 ;;
        --reuse)  REUSE=1; shift ;;
        *) shift ;;
    esac
done

BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"
derive_preview_names "$BRANCH"
CORE_APP="${PREVIEW_CORE_APP}"
CORE_URL="https://${CORE_APP}.fly.dev"

if [[ "$REUSE" -eq 1 ]]; then
    echo "==> --reuse: skipping teardown, redeploying onto the existing stack."
    echo "    (If this deploy behaves strangely, tear down and retry before debugging the app.)"
else
    echo "==> Tearing down any existing preview stack first (use --reuse to skip)..."
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" ${BRANCH_ARG} || {
        echo "FAIL deploy: teardown failed; not deploying onto an unknown stack state" >&2
        exit 1
    }
fi

bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}
