#!/usr/bin/env bash
# scripts/cleanup-preview.sh — destroy ephemeral preview resources for a branch.
#
# Deletes the two Fly apps and the Neon DB branch created by deploy-preview.sh.
# Safe to run multiple times; missing resources are silently skipped.
#
# Teardown ORDER matters (Issue #170 D): Fly machines are stopped BEFORE the
# Neon preview branch is deleted. The core app's pooled Postgrex connections
# otherwise keep pointing at the deleted Neon endpoint until autostop kicks
# in, spraying `Postgrex ... The requested endpoint could not be found`
# errors into the core logs — harmless, but noisy enough to mask real DB
# errors. Stopping the machines first drains the pool before the endpoint
# disappears.
#
# Manual verification (2026-07-08 procedure, re-run after any reorder):
#   1. Deploy a preview (scripts/deploy-preview.sh).
#   2. In a second terminal: `fly logs --app stacks-core-pr-<branch>`.
#   3. Run this script and watch the log tail through the Neon deletion —
#      zero Postgrex "endpoint could not be found" errors after the machine
#      stop completes.
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
#                             names are derived (Issue #170 C). CI sets it;
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
    echo "    Keeping ${CORE_APP} (auto_stop_machines handles idle cost, preserves DNS)."

    echo "    Stopping ${CORE_APP} machines (drain DB pool before Neon branch deletion)..."
    { fly machines list --app "${CORE_APP}" --json 2>/dev/null || echo "[]"; } \
        | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    print(m['id'])
" 2>/dev/null \
        | while read -r mid; do
            [[ -z "$mid" ]] && continue
            fly machine stop "$mid" --app "${CORE_APP}" 2>/dev/null \
                && echo "    Stopped machine ${mid}." \
                || echo "    Machine ${mid} already stopped (or stop failed — non-fatal)."
        done

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
