#!/usr/bin/env bash
# scripts/cleanup-preview.sh — destroy EVERYTHING deploy-preview.sh creates
# for a branch: all five Fly apps (core included — a kept core app is how
# suspended husks accumulated), the Modal preview app, and the Neon preview
# branch. Safe to run multiple times; missing resources are silently skipped.
#
# Teardown ORDER matters: the Fly apps (and with them every pooled Postgrex
# connection) are destroyed BEFORE the Neon preview branch, so no client is
# still pointing at the endpoint when it disappears.
#
# The scheduled orphan sweep (scripts/sweep-preview-orphans.sh) is the
# backstop for previews this script never ran against (manual deploys,
# crashed CI runs).
#
# Required env vars:
#   FLY_API_TOKEN   — Fly.io API token
#
# Optional env vars:
#   NEON_STAGING_API_KEY    — Neon API key scoped to the staging project
#                             (required to delete the preview Neon branch)
#   NEON_STAGING_PROJECT_ID — Neon project ID for `thestacks-staging`
#                             (required to delete the preview Neon branch)
#   MODAL_TOKEN_ID          — Modal API token ID (required to delete Modal app)
#   MODAL_TOKEN_SECRET      — Modal API token secret
#   GITHUB_HEAD_REF         — set automatically in GitHub Actions
#   PREVIEW_SUFFIX          — optional uniqueness component; MUST match the
#                             value the deploy ran with so the same suffixed
#                             names are derived (C). CI sets it;
#                             local runs leave it unset.
#
# Usage:
#   scripts/cleanup-preview.sh
#   scripts/cleanup-preview.sh --branch my-feature-branch
#   scripts/cleanup-preview.sh --branch my-feature-branch --neon-branch-name preview/my-feature-branch

set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"
derive_preview_names "$BRANCH"

CORE_APP="${PREVIEW_CORE_APP}"
SCRAPER_APP="${PREVIEW_SCRAPER_APP}"
SEARXNG_APP="${PREVIEW_SEARXNG_APP}"
MODAL_APP="${PREVIEW_MODAL_APP}"
VM_APP="${PREVIEW_VM_APP}"
GRAFANA_APP="${PREVIEW_GRAFANA_APP}"

echo "==> Cleaning up preview resources for branch: ${BRANCH}"
echo "    Core app:    ${CORE_APP}"
echo "    Scraper app: ${SCRAPER_APP}"
echo "    SearXNG app: ${SEARXNG_APP}"
echo "    Metrics app: ${VM_APP}"
echo "    Grafana app: ${GRAFANA_APP}"
echo "    Modal app:   ${MODAL_APP}"

if command -v fly &>/dev/null && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    fly apps destroy "${CORE_APP}" --yes 2>/dev/null && echo "    Destroyed ${CORE_APP}." || echo "    ${CORE_APP} not found (already gone)."
    fly apps destroy "${SCRAPER_APP}" --yes 2>/dev/null && echo "    Destroyed ${SCRAPER_APP}." || echo "    ${SCRAPER_APP} not found (already gone)."
    fly apps destroy "${SEARXNG_APP}" --yes 2>/dev/null && echo "    Destroyed ${SEARXNG_APP}." || echo "    ${SEARXNG_APP} not found (already gone)."
    fly apps destroy "${VM_APP}" --yes 2>/dev/null && echo "    Destroyed ${VM_APP}." || echo "    ${VM_APP} not found (already gone)."
    fly apps destroy "${GRAFANA_APP}" --yes 2>/dev/null && echo "    Destroyed ${GRAFANA_APP}." || echo "    ${GRAFANA_APP} not found (already gone)."
else
    echo "    SKIP: flyctl not available or FLY_API_TOKEN not set — skipping Fly cleanup."
fi

if [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]] && command -v python3 &>/dev/null; then
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal app stop "${MODAL_APP}" 2>/dev/null \
        && echo "    Modal app ${MODAL_APP} stopped." \
        || echo "    Modal app ${MODAL_APP} not found (already gone)."
else
    echo "    SKIP: MODAL_TOKEN_ID not set — skipping Modal cleanup."
fi

if [[ -n "${NEON_STAGING_API_KEY:-}" ]] && [[ -n "${NEON_STAGING_PROJECT_ID:-}" ]]; then
    [[ -z "$NEON_BRANCH_NAME" ]] && NEON_BRANCH_NAME="${PREVIEW_NEON_BRANCH}"
    echo "    Looking up Neon branch '${NEON_BRANCH_NAME}'..."
    branch_id="$(curl -sL \
        -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches" \
        | python3 -c "
import json, sys
branches = json.load(sys.stdin).get('branches', [])
match = next((b['id'] for b in branches if b['name'] == '${NEON_BRANCH_NAME}'), '')
print(match)
" 2>/dev/null || true)"
    if [[ -n "$branch_id" ]]; then
        curl -s -X DELETE \
            -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches/${branch_id}" \
            >/dev/null 2>&1 || true
        echo "    Neon branch ${NEON_BRANCH_NAME} deleted."
    else
        echo "    Neon branch '${NEON_BRANCH_NAME}' not found (already gone)."
    fi
else
    echo "    SKIP: NEON_STAGING_API_KEY or NEON_STAGING_PROJECT_ID not set — skipping Neon cleanup."
fi

echo ""
echo "Cleanup complete."
