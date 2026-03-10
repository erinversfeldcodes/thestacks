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
#   GITHUB_HEAD_REF     — set automatically in GitHub Actions
#
# Usage:
#   scripts/cleanup-preview.sh
#   scripts/cleanup-preview.sh --branch my-feature-branch
#   scripts/cleanup-preview.sh --branch my-feature-branch --neon-branch-id br-xxxx

set -euo pipefail

# ── Parse args ────────────────────────────────────────────────────────────────
BRANCH=""
NEON_BRANCH_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch)          BRANCH="$2";          shift 2 ;;
        --neon-branch-id)  NEON_BRANCH_ID="$2";  shift 2 ;;
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
VISION_APP="stacks-vision-pr-${SANITISED}"

echo "==> Cleaning up preview resources for branch: ${BRANCH}"
echo "    Core app:   ${CORE_APP}"
echo "    Vision app: ${VISION_APP}"

# ── Fly apps ─────────────────────────────────────────────────────────────────
if command -v fly &>/dev/null && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    fly apps destroy "${CORE_APP}"   --yes 2>/dev/null && echo "    Destroyed ${CORE_APP}."   || echo "    ${CORE_APP} not found (already gone)."
    fly apps destroy "${VISION_APP}" --yes 2>/dev/null && echo "    Destroyed ${VISION_APP}." || echo "    ${VISION_APP} not found (already gone)."
else
    echo "    SKIP: flyctl not available or FLY_API_TOKEN not set — skipping Fly cleanup."
fi

# ── Neon branch ───────────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]] && [[ -n "${NEON_PROJECT_ID:-}" ]]; then
    if [[ -n "$NEON_BRANCH_ID" ]]; then
        # Branch ID provided explicitly — delete directly
        curl -s -X DELETE \
            -H "Authorization: Bearer ${NEON_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${NEON_BRANCH_ID}" \
            >/dev/null 2>&1 || true
        echo "    Neon branch ${NEON_BRANCH_ID} deleted."
    else
        # Look up branch by name (preview/<sanitised>)
        NEON_BRANCH_NAME="preview/${SANITISED}"
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
            echo "    Neon branch ${branch_id} (${NEON_BRANCH_NAME}) deleted."
        else
            echo "    Neon branch '${NEON_BRANCH_NAME}' not found (already gone)."
        fi
    fi
else
    echo "    SKIP: NEON_API_KEY or NEON_PROJECT_ID not set — skipping Neon cleanup."
fi

echo ""
echo "Cleanup complete."
