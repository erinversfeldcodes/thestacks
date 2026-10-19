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

# ⛔ A MISSING TOOL IS A FAILURE, not a skip.
#
# This used to be one `if command -v fly … else SKIP` branch, and it failed open
# in the worst possible way: in GitHub Actions the setup action installs
# `flyctl` and NOT `fly`, so the condition was false on every run, the Fly
# teardown was skipped in silence, and the workflow reported success. Two
# preview apps from a merged branch survived that way until a Fly listing turned
# them up by hand — one of them still holding an unattached volume.
#
# The weekly orphan sweep hit the identical cause and failed LOUDLY, which is
# the only reason any of it was visible. A cleanup script that deletes nothing
# must not be the quiet one.
#
# Still skips when the TOKEN is absent, because that is a legitimate local
# invocation with nothing to authenticate against — but it says which of the two
# reasons applied rather than collapsing them into one message.
if ! command -v fly &>/dev/null; then
    echo "FAIL cleanup: 'fly' is not on PATH." >&2
    echo "       In CI the flyctl action installs 'flyctl' only; alias it to 'fly' first." >&2
    echo "       Nothing was destroyed. This is a refusal, not a pass." >&2
    exit 1
fi

if [[ -n "${FLY_API_TOKEN:-}" ]]; then
    fly apps destroy "${CORE_APP}" --yes 2>/dev/null && echo "    Destroyed ${CORE_APP}." || echo "    ${CORE_APP} not found (already gone)."
    fly apps destroy "${SCRAPER_APP}" --yes 2>/dev/null && echo "    Destroyed ${SCRAPER_APP}." || echo "    ${SCRAPER_APP} not found (already gone)."
    fly apps destroy "${SEARXNG_APP}" --yes 2>/dev/null && echo "    Destroyed ${SEARXNG_APP}." || echo "    ${SEARXNG_APP} not found (already gone)."
    fly apps destroy "${VM_APP}" --yes 2>/dev/null && echo "    Destroyed ${VM_APP}." || echo "    ${VM_APP} not found (already gone)."
    fly apps destroy "${GRAFANA_APP}" --yes 2>/dev/null && echo "    Destroyed ${GRAFANA_APP}." || echo "    ${GRAFANA_APP} not found (already gone)."
else
    echo "    SKIP: FLY_API_TOKEN not set — skipping Fly cleanup (nothing to authenticate with)."
fi

if [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]] && command -v python3 &>/dev/null; then
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal app stop "${MODAL_APP}" 2>/dev/null \
        && echo "    Modal app ${MODAL_APP} stopped." \
        || modal_stop_failed=1

    # ⛔ "not found (already gone)" USED TO BE PRINTED HERE unconditionally, and
    # it was a lie in the one case that mattered.
    #
    # `python3 -m modal` fails identically whether the app is genuinely absent
    # or the modal CLI is not installed — and the cleanup workflow did not
    # install it. So every closed-PR run reported the Modal app as already
    # cleaned up while stopping nothing. 24 orphaned vision apps accumulated,
    # the oldest from 20 July, and only a hand-run `modal app list` found them.
    #
    # So the two cases are now distinguished before anything is claimed.
    if [[ "${modal_stop_failed:-0}" == "1" ]]; then
        if ! python3 -m modal --version >/dev/null 2>&1; then
            echo "FAIL cleanup: the modal CLI is not installed, so no Modal app was stopped." >&2
            echo "       This is a refusal, not a pass — 'already gone' cannot be distinguished" >&2
            echo "       from 'never tried' without it." >&2
            exit 1
        fi
        echo "    Modal app ${MODAL_APP} not found (already gone)."
    fi
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
