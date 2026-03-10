#!/usr/bin/env bash
# scripts/deploy-preview.sh — deploy an ephemeral preview stack to Fly.io and
# run E2E + DAST tests against it, then destroy everything.
#
# Required env vars:
#   FLY_API_TOKEN   — Fly.io API token
#   NEON_PROJECT_ID — Neon project to branch from
#
# Optional env vars:
#   NEON_API_KEY        — Neon API key (required when using Neon branch)
#   TOGETHER_API_KEY    — Vision sidecar LLM key
#   VISION_HMAC_SECRET  — Elixir → vision HMAC auth
#   SECRET_KEY_BASE     — Phoenix secret key base
#   GITHUB_HEAD_REF     — set automatically in GitHub Actions
#
# Usage:
#   scripts/deploy-preview.sh
#   scripts/deploy-preview.sh --branch my-feature-branch
#
# Outputs lines parseable by _parse_ci_output:
#   PASS deploy: ...
#   FAIL deploy: ...

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ -z "${FLY_API_TOKEN:-}" ]]; then
    echo "SKIP: FLY_API_TOKEN not set — skipping deploy preview."
    exit 0
fi

if [[ -z "${NEON_PROJECT_ID:-}" ]]; then
    echo "SKIP: NEON_PROJECT_ID not set — skipping deploy preview."
    exit 0
fi

if ! command -v fly &>/dev/null; then
    echo "SKIP: flyctl not installed (brew install flyctl)"
    exit 0
fi

# ── Branch name → Fly app name ────────────────────────────────────────────────
# Parse optional --branch arg
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$BRANCH" ]]; then
    BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
fi

# Sanitise: lowercase, replace / and _ with -, truncate to 30 chars
SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
# Strip trailing hyphens that may result from truncation
SANITISED="${SANITISED%-}"

CORE_APP="stacks-core-pr-${SANITISED}"
VISION_APP="stacks-vision-pr-${SANITISED}"
NEON_BRANCH_ID=""

echo "==> Deploy preview for branch: ${BRANCH}"
echo "    Core app:   ${CORE_APP}"
echo "    Vision app: ${VISION_APP}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local neon_args=""
    [[ -n "$NEON_BRANCH_ID" ]] && neon_args="--neon-branch-id ${NEON_BRANCH_ID}"
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" --branch "${BRANCH}" ${neon_args}
}
trap cleanup EXIT

# ── Create Neon branch ────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."
    # Request an endpoint alongside the branch so a connection URI is available
    # immediately. include_passwords=true returns the full connection string.
    neon_response="$(curl -sL -X POST \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"branch\": {\"name\": \"preview/${SANITISED}\"}, \"endpoints\": [{\"type\": \"read_write\"}]}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches?include_passwords=true")"

    # Use python3 for reliable JSON parsing (jq may not be present)
    NEON_BRANCH_ID="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['branch']['id'])" 2>/dev/null || true)"
    NEON_CONNECTION_URI="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['connection_uris'][0]['connection_uri'])" 2>/dev/null || true)"

    if [[ -z "$NEON_BRANCH_ID" ]]; then
        echo "FAIL deploy: Neon branch creation failed" >&2
        echo "$neon_response" | head -5 >&2
        exit 1
    fi
    echo "    Neon branch created: ${NEON_BRANCH_ID}"
    if [[ -n "$NEON_CONNECTION_URI" ]]; then
        echo "    Connection URI obtained."
    else
        echo "    WARNING: no connection URI returned — DATABASE_URL will not be set for core app."
    fi
else
    echo "SKIP: NEON_API_KEY not set — skipping Neon branch creation."
    NEON_CONNECTION_URI=""
fi

# ── Create apps ───────────────────────────────────────────────────────────────
echo ""
echo "==> Creating ephemeral Fly apps..."
fly apps create "${CORE_APP}" 2>&1 || true
fly apps create "${VISION_APP}" 2>&1 || true

# ── Deploy core ───────────────────────────────────────────────────────────────
echo ""
echo "==> Deploying ${CORE_APP}..."
deploy_core_failed=0
fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    ${NEON_CONNECTION_URI:+DATABASE_URL="${NEON_CONNECTION_URI}"} \
    --app "${CORE_APP}" --stage
fly deploy \
    --app "${CORE_APP}" \
    --config "${REPO_ROOT}/deploy/fly.core.toml" \
    --image-label "pr-${SANITISED}" \
    2>&1 || deploy_core_failed=1

if [[ $deploy_core_failed -eq 1 ]]; then
    echo "FAIL deploy: core app deployment failed"
    exit 1
fi
echo "PASS deploy: core app deployed"

# ── Deploy vision ─────────────────────────────────────────────────────────────
echo ""
echo "==> Deploying ${VISION_APP}..."
deploy_vision_failed=0
fly secrets set \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    VISION_TOGETHER_API_KEY="${VISION_TOGETHER_API_KEY:-}" \
    --app "${VISION_APP}" --stage
fly deploy \
    --app "${VISION_APP}" \
    --config "${REPO_ROOT}/deploy/fly.vision.toml" \
    --image-label "pr-${SANITISED}" \
    2>&1 || deploy_vision_failed=1

if [[ $deploy_vision_failed -eq 1 ]]; then
    echo "FAIL deploy: vision app deployment failed"
    exit 1
fi
echo "PASS deploy: vision app deployed"

# ── Wait for health check ─────────────────────────────────────────────────────
CORE_URL="https://${CORE_APP}.fly.dev"
echo ""
echo "==> Waiting for ${CORE_URL}/api/health..."
RETRIES=10
until curl -sf "${CORE_URL}/api/health" &>/dev/null; do
    if [[ $RETRIES -le 0 ]]; then
        echo "FAIL deploy: health check timed out for ${CORE_URL}"
        exit 1
    fi
    echo "    Not ready — retrying in 15s ($RETRIES attempts left)..."
    sleep 15
    ((RETRIES--))
done
echo "PASS deploy: health check passed"

# ── Migrate and seed the Neon branch ──────────────────────────────────────────
echo ""
echo "==> Running migrations and seeds on ${CORE_APP}..."
fly ssh console --app "${CORE_APP}" -C "/app/bin/core eval 'Stacks.Release.migrate()'" 2>&1 \
    || { echo "FAIL deploy: migrations failed"; exit 1; }
fly ssh console --app "${CORE_APP}" -C "/app/bin/core eval 'Stacks.Release.seed()'" 2>&1 \
    || { echo "FAIL deploy: seeds failed"; exit 1; }
echo "PASS deploy: migrations and seeds applied"

# ── Run Playwright E2E against deployed stack ─────────────────────────────────
echo ""
echo "==> Running Playwright E2E against ${CORE_URL}..."
e2e_failed=0
E2E_SERVICES=none BASE_URL="${CORE_URL}" bash "${REPO_ROOT}/scripts/test-e2e.sh" 2>&1 || e2e_failed=1

if [[ $e2e_failed -eq 0 ]]; then
    echo "PASS deploy: deployed E2E tests passed"
else
    echo "FAIL deploy: deployed E2E tests failed"
fi

# ── OWASP ZAP baseline (passive DAST) ────────────────────────────────────────
echo ""
if command -v docker &>/dev/null; then
    echo "==> Running OWASP ZAP baseline scan against ${CORE_URL}..."
    # Capture ZAP output; check FAIL-NEW count directly — spider errors cause exit 2 even
    # with no actual security failures (expected for an API-only backend with no root route).
    # || true prevents set -e from exiting on ZAP's non-zero exit (warnings/spider errors).
    zap_output="$(docker run --rm \
        --mount type=tmpfs,destination=/zap/wrk \
        ghcr.io/zaproxy/zaproxy:stable \
        zap-baseline.py -t "${CORE_URL}" 2>&1)" || true
    echo "${zap_output}"
    if echo "${zap_output}" | grep -q "FAIL-NEW: 0"; then
        echo "PASS deploy: OWASP ZAP baseline passed (FAIL-NEW: 0)"
    else
        echo "FAIL deploy: OWASP ZAP baseline found new security failures"
    fi
else
    echo "SKIP: docker not available — skipping OWASP ZAP scan"
fi

# ── Final result ──────────────────────────────────────────────────────────────
if [[ $e2e_failed -ne 0 ]]; then
    exit 1
fi

echo ""
echo "Deploy preview complete."
