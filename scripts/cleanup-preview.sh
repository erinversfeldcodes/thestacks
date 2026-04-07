#!/usr/bin/env bash
# scripts/cleanup-preview.sh — destroy ephemeral preview resources for a branch.
#
# Deletes the two Fly apps and the Neon DB branch created by deploy-preview.sh.
# Safe to run multiple times; missing resources are silently skipped.
#
# Required env vars:
#   FLY_API_TOKEN   — Fly.io API token
#
# Optional env vars:
#   NEON_API_KEY        — Neon API key (required to delete Neon branch)
#   NEON_PROJECT_ID     — Neon project ID (required to delete Neon branch)
#   MODAL_TOKEN_ID      — Modal API token ID (required to delete Modal app)
#   MODAL_TOKEN_SECRET  — Modal API token secret
#   GITHUB_HEAD_REF     — set automatically in GitHub Actions
#
# Usage:
#   scripts/cleanup-preview.sh
#   scripts/cleanup-preview.sh --branch my-feature-branch
#   scripts/cleanup-preview.sh --branch my-feature-branch --neon-branch-name preview/my-feature-branch

set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

# ── Parse args ────────────────────────────────────────────────────────────────
BRANCH=""
NEON_BRANCH_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)           BRANCH="$2";           shift 2 ;;
        --neon-branch-name) NEON_BRANCH_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$BRANCH" ]]; then
    BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
fi

# Sanitise branch name the same way deploy-preview.sh does
SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"

CORE_APP="stacks-core-pr-${SANITISED}"
SCRAPER_APP="stacks-scraper-pr-${SANITISED}"
SEARXNG_APP="stacks-searxng-pr-${SANITISED}"
MODAL_APP="thestacks-vision-${SANITISED}"

echo "==> Cleaning up preview resources for branch: ${BRANCH}"
echo "    Core app:    ${CORE_APP}"
echo "    Scraper app: ${SCRAPER_APP}"
echo "    SearXNG app: ${SEARXNG_APP}"
echo "    Modal app:   ${MODAL_APP}"

# ── Fly apps ─────────────────────────────────────────────────────────────────
if command -v fly &>/dev/null && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    # IMPORTANT: do NOT destroy CORE_APP.
    # fly apps destroy removes the DNS record and causes macOS mDNSResponder to
    # cache a NXDOMAIN that can persist for 10-50+ minutes. The next CI run's
    # Node.js/Playwright calls (which use the system resolver) all fail with
    # ENOTFOUND even after the app is redeployed, because the OS still serves
    # the cached NXDOMAIN and flushing it requires root.
    #
    # Instead, we rely on auto_stop_machines = true in fly.core.toml to stop
    # idle machines (no running-machine cost). The app DNS record stays live.
    # The next ci.sh run re-deploys to the same app via `fly apps create || true`.
    echo "    Keeping ${CORE_APP} (auto_stop_machines handles idle cost, preserves DNS)."
    fly apps destroy "${SCRAPER_APP}" --yes 2>/dev/null && echo "    Destroyed ${SCRAPER_APP}." || echo "    ${SCRAPER_APP} not found (already gone)."
    fly apps destroy "${SEARXNG_APP}" --yes 2>/dev/null && echo "    Destroyed ${SEARXNG_APP}." || echo "    ${SEARXNG_APP} not found (already gone)."
else
    echo "    SKIP: flyctl not available or FLY_API_TOKEN not set — skipping Fly cleanup."
fi

# ── Modal app ────────────────────────────────────────────────────────────────
if [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]] && command -v python3 &>/dev/null; then
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal app stop "${MODAL_APP}" 2>/dev/null \
        && echo "    Modal app ${MODAL_APP} stopped." \
        || echo "    Modal app ${MODAL_APP} not found (already gone)."
else
    echo "    SKIP: MODAL_TOKEN_ID not set — skipping Modal cleanup."
fi

# ── Neon branch ───────────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]] && [[ -n "${NEON_PROJECT_ID:-}" ]]; then
    # Use the name passed from deploy-preview.sh, or derive it from the branch.
    [[ -z "$NEON_BRANCH_NAME" ]] && NEON_BRANCH_NAME="preview/${SANITISED}"
    echo "    Looking up Neon branch '${NEON_BRANCH_NAME}'..."
    branch_id="$(curl -sL \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches" \
        | python3 -c "
import json, sys
branches = json.load(sys.stdin).get('branches', [])
match = next((b['id'] for b in branches if b['name'] == '${NEON_BRANCH_NAME}'), '')
print(match)
" 2>/dev/null || true)"
    if [[ -n "$branch_id" ]]; then
        curl -s -X DELETE \
            -H "Authorization: Bearer ${NEON_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${branch_id}" \
            >/dev/null 2>&1 || true
        echo "    Neon branch ${NEON_BRANCH_NAME} deleted."
    else
        echo "    Neon branch '${NEON_BRANCH_NAME}' not found (already gone)."
    fi
else
    echo "    SKIP: NEON_API_KEY or NEON_PROJECT_ID not set — skipping Neon cleanup."
fi

echo ""
echo "Cleanup complete."
