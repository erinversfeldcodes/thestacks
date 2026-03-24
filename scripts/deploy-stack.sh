#!/usr/bin/env bash
# scripts/deploy-stack.sh — deploy an ephemeral preview stack to Fly.io.
#
# Creates Neon branch, deploys Modal vision service, deploys Fly core app,
# runs migrations, seeds the DB, and waits for health. Does NOT run tests
# or clean up — that's the caller's responsibility.
#
# On success, writes the preview URL and metadata to stdout as PASS lines.
# On failure, writes FAIL lines and exits non-zero.
#
# Required env vars:
#   FLY_API_TOKEN   — Fly.io API token
#   NEON_PROJECT_ID — Neon project to branch from
#
# Optional env vars:
#   NEON_API_KEY            — Neon API key (required when using Neon branch)
#   MODAL_TOKEN_ID          — Modal API token ID
#   MODAL_TOKEN_SECRET      — Modal API token secret
#   VISION_HMAC_SECRET      — Elixir → vision HMAC auth
#   SECRET_KEY_BASE         — Phoenix secret key base
#   NEON_PARENT_BRANCH      — Name of parent branch (default: production)
#   GITHUB_HEAD_REF         — set automatically in GitHub Actions
#   R2_ACCOUNT_ID           — Cloudflare R2 account ID (object storage)
#   R2_ACCESS_KEY_ID        — R2 access key
#   R2_SECRET_ACCESS_KEY    — R2 secret key
#   R2_BUCKET_NAME          — R2 bucket name (default: stacks-images)
#   VISION_TOGETHER_API_KEY — Together AI API key (LLM features)
#   SCRAPER_HMAC_SECRET     — Scraper sidecar HMAC auth
#   BRAVE_SEARCH_API_KEY    — Brave Search API key (source discovery)
#
# Usage:
#   scripts/deploy-stack.sh
#   scripts/deploy-stack.sh --branch my-feature-branch

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ -z "${FLY_API_TOKEN:-}" ]]; then
    echo "SKIP: FLY_API_TOKEN not set — skipping deploy."
    exit 0
fi

if [[ -z "${NEON_PROJECT_ID:-}" ]]; then
    echo "SKIP: NEON_PROJECT_ID not set — skipping deploy."
    exit 0
fi

if ! command -v fly &>/dev/null; then
    echo "SKIP: flyctl not installed (brew install flyctl)"
    exit 0
fi

# ── Branch name → Fly app name ────────────────────────────────────────────────
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

SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"

CORE_APP="stacks-core-pr-${SANITISED}"
MODAL_APP="thestacks-vision-${SANITISED}"
VISION_SERVICE_URL=""
NEON_BRANCH_NAME=""

echo "==> Deploy stack for branch: ${BRANCH}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"

# ── Create Neon branch ────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."

    NEON_PARENT_BRANCH="${NEON_PARENT_BRANCH:-production}"
    echo "    Parent branch: ${NEON_PARENT_BRANCH}"
    NEON_PARENT_BRANCH_ID="$(curl -sL \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches" \
        | python3 -c "
import json,sys
branches = json.load(sys.stdin).get('branches', [])
match = [b['id'] for b in branches if b['name'] == '${NEON_PARENT_BRANCH}']
print(match[0] if match else '')
" 2>/dev/null || true)"

    if [[ -z "$NEON_PARENT_BRANCH_ID" ]]; then
        echo "FAIL deploy: Neon parent branch '${NEON_PARENT_BRANCH}' not found in project ${NEON_PROJECT_ID}" >&2
        exit 1
    fi
    echo "    Parent branch ID: ${NEON_PARENT_BRANCH_ID}"

    stale_id="$(curl -sL \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches" \
        | python3 -c "
import json,sys
branches = json.load(sys.stdin).get('branches', [])
match = [b['id'] for b in branches if b['name'] == 'preview/${SANITISED}']
print(match[0] if match else '')
" 2>/dev/null || true)"
    if [[ -n "$stale_id" ]]; then
        echo "    Deleting stale branch preview/${SANITISED}..."
        curl -sL -X DELETE \
            -H "Authorization: Bearer ${NEON_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${stale_id}" > /dev/null
    fi

    neon_response="$(curl -sL -X POST \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"branch\": {\"name\": \"preview/${SANITISED}\", \"parent_id\": \"${NEON_PARENT_BRANCH_ID}\"}, \"endpoints\": [{\"type\": \"read_write\"}]}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches?include_passwords=true")"

    NEON_CONNECTION_URI="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['connection_uris'][0]['connection_uri'])" 2>/dev/null || true)"
    neon_branch_name="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['branch']['name'])" 2>/dev/null || true)"

    if [[ "$neon_branch_name" != "preview/${SANITISED}" ]]; then
        echo "FAIL deploy: Neon branch creation failed" >&2
        echo "$neon_response" | head -5 >&2
        exit 1
    fi
    NEON_BRANCH_NAME="preview/${SANITISED}"
    echo "    Neon branch created: ${NEON_BRANCH_NAME}"
    if [[ -n "$NEON_CONNECTION_URI" ]]; then
        echo "    Connection URI obtained."
    else
        echo "    WARNING: no connection URI returned."
    fi
else
    echo "SKIP: NEON_API_KEY not set — skipping Neon branch creation."
    NEON_CONNECTION_URI=""
fi

# ── Deploy vision service to Modal ────────────────────────────────────────────
if [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]]; then
    echo ""
    echo "==> Syncing Modal secret 'thestacks-vision'..."
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal secret create thestacks-vision \
            "VISION_HMAC_SECRET=${VISION_HMAC_SECRET:-}" \
            "MODAL_TOKEN_ID=${MODAL_TOKEN_ID}" \
            "MODAL_TOKEN_SECRET=${MODAL_TOKEN_SECRET}" \
            --force 2>&1 || { echo "FAIL deploy: Modal secret sync failed"; exit 1; }

    echo ""
    echo "==> Deploying vision service to Modal (app: ${MODAL_APP})..."
    modal_deploy_output="$(MODAL_APP_NAME="${MODAL_APP}" \
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal deploy "${REPO_ROOT}/apps/vision/modal_app.py" 2>&1)" \
        || { echo "$modal_deploy_output"; echo "FAIL deploy: Modal vision deploy failed"; exit 1; }
    echo "$modal_deploy_output"

    VISION_SERVICE_URL="$(MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -c "
import modal
f = modal.Function.from_name('${MODAL_APP}', 'vision_api')
print(f.web_url)
" 2>/dev/null)"
    if [[ -z "$VISION_SERVICE_URL" ]]; then
        echo "FAIL deploy: could not retrieve Modal vision service URL via SDK" >&2
        exit 1
    fi
    echo "    Vision URL: ${VISION_SERVICE_URL}"
    echo "PASS deploy: vision service deployed to Modal"
else
    echo "WARN: MODAL_TOKEN_ID/MODAL_TOKEN_SECRET not set — skipping Modal vision deploy."
fi

# ── Deploy scraper service ──────────────────────────────────────────────────
SCRAPER_APP="stacks-scraper-pr-${SANITISED}"
SCRAPER_INTERNAL_URL="http://${SCRAPER_APP}.internal:8080"

if [[ -n "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo ""
    echo "==> Deploying scraper (app: ${SCRAPER_APP})..."
    fly apps destroy "${SCRAPER_APP}" --yes 2>&1 | grep -v "^Error" || true
    fly apps create "${SCRAPER_APP}" 2>&1 || true

    fly secrets set \
        SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}" \
        RUST_LOG="info" \
        --app "${SCRAPER_APP}" --stage

    if (cd "$REPO_ROOT" && fly deploy \
            --app "${SCRAPER_APP}" \
            --config "${REPO_ROOT}/deploy/fly.scraper.toml" \
            --image-label "pr-${SANITISED}" \
            --no-cache); then
        echo "PASS deploy: scraper deployed at ${SCRAPER_INTERNAL_URL}"
    else
        echo "WARN deploy: scraper deployment failed — core will degrade gracefully"
        SCRAPER_INTERNAL_URL=""
    fi
else
    echo "WARN: SCRAPER_HMAC_SECRET not set — skipping scraper deploy."
    SCRAPER_INTERNAL_URL=""
fi

# ── Deploy SearXNG (ephemeral per preview) ─────────────────────────────────
SEARXNG_APP="stacks-searxng-pr-${SANITISED}"
SEARXNG_INTERNAL_URL="http://${SEARXNG_APP}.internal:8080"

if [[ -n "${SEARXNG_SECRET_KEY:-}" ]]; then
    echo ""
    echo "==> Deploying SearXNG (app: ${SEARXNG_APP})..."
    fly apps destroy "${SEARXNG_APP}" --yes 2>&1 | grep -v "^Error" || true
    fly apps create "${SEARXNG_APP}" 2>&1 || true

    fly secrets set \
        SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY}" \
        --app "${SEARXNG_APP}" --stage

    # Create volume for settings mount (required by fly.searxng.toml)
    fly volumes create searxng_settings \
        --app "${SEARXNG_APP}" \
        --region iad \
        --size 1 \
        --yes 2>&1 || true

    # Render settings.yml with the secret key
    SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml"
    SETTINGS_TMP="$(mktemp /tmp/searxng-settings-XXXXXX.yml)"
    sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|g" \
        "${SETTINGS_TEMPLATE}" > "${SETTINGS_TMP}"

    if (fly deploy \
            --app "${SEARXNG_APP}" \
            --config "${REPO_ROOT}/deploy/fly.searxng.toml" \
            --yes); then
        # Upload rendered settings to the running machine
        fly ssh sftp shell --app "${SEARXNG_APP}" <<SFTP_EOF || true
put ${SETTINGS_TMP} /etc/searxng/settings.yml
SFTP_EOF
        echo "PASS deploy: SearXNG deployed at ${SEARXNG_INTERNAL_URL}"
    else
        echo "WARN deploy: SearXNG deployment failed — core will degrade gracefully"
        SEARXNG_INTERNAL_URL=""
    fi
    rm -f "${SETTINGS_TMP}"
else
    echo "WARN: SEARXNG_SECRET_KEY not set — skipping SearXNG deploy."
    SEARXNG_INTERNAL_URL=""
fi

# ── Create core app ───────────────────────────────────────────────────────────
echo ""
echo "==> Creating ephemeral Fly app..."
fly apps destroy "${CORE_APP}" --yes 2>&1 | grep -v "^Error" || true
fly apps create "${CORE_APP}" 2>&1 || true

# ── Stage core secrets ────────────────────────────────────────────────────────
fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    VISION_SERVICE_URL="${VISION_SERVICE_URL}" \
    PHX_HOST="${CORE_APP}.fly.dev" \
    RATE_LIMIT_AUTH="60" \
    ${NEON_CONNECTION_URI:+DATABASE_URL="${NEON_CONNECTION_URI}"} \
    ${R2_ACCOUNT_ID:+R2_ACCOUNT_ID="${R2_ACCOUNT_ID}"} \
    ${R2_ACCESS_KEY_ID:+R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"} \
    ${R2_SECRET_ACCESS_KEY:+R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"} \
    ${R2_BUCKET_NAME:+R2_BUCKET_NAME="${R2_BUCKET_NAME}"} \
    ${VISION_TOGETHER_API_KEY:+VISION_TOGETHER_API_KEY="${VISION_TOGETHER_API_KEY}"} \
    ${SCRAPER_HMAC_SECRET:+SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}"} \
    ${SCRAPER_INTERNAL_URL:+SCRAPER_SERVICE_URL="${SCRAPER_INTERNAL_URL}"} \
    ${SEARXNG_INTERNAL_URL:+SEARXNG_URL="${SEARXNG_INTERNAL_URL}"} \
    ${BRAVE_SEARCH_API_KEY:+BRAVE_SEARCH_API_KEY="${BRAVE_SEARCH_API_KEY}"} \
    --app "${CORE_APP}" --stage

# ── Generate proto Elm decoders ───────────────────────────────────────────────
echo ""
echo "==> Generating Elm proto decoders..."
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh" \
        || { echo "FAIL deploy: proto Elm generation failed"; exit 1; }
    if [[ ! -d "$REPO_ROOT/proto/gen/elm" ]] || [[ -z "$(ls -A "$REPO_ROOT/proto/gen/elm" 2>/dev/null)" ]]; then
        echo "FAIL deploy: proto/gen/elm/ is empty after generation"; exit 1
    fi
    echo "    proto/gen/elm/ generated"
else
    echo "FAIL deploy: scripts/gen-elm-proto.sh not found"
    exit 1
fi

# ── Build frontend assets ─────────────────────────────────────────────────────
echo ""
echo "==> Rebuilding frontend assets via esbuild..."
if command -v node &>/dev/null && [[ -f "$REPO_ROOT/apps/core/assets/build.js" ]]; then
    (cd "$REPO_ROOT/apps/core/assets" && node build.js --production) \
        || { echo "FAIL deploy: frontend build failed"; exit 1; }
    echo "    app.js rebuilt"
else
    echo "    SKIP: node or build.js not found — Docker build will handle it"
fi

# ── Deploy core ──────────────────────────────────────────────────────────────
CORE_URL="https://${CORE_APP}.fly.dev"

echo ""
echo "==> Deploying ${CORE_APP}..."
if ! (cd "$REPO_ROOT" && fly deploy \
        --app "${CORE_APP}" \
        --config "${REPO_ROOT}/deploy/fly.core.toml" \
        --image-label "pr-${SANITISED}" \
        --no-cache); then
    echo "FAIL deploy: core app deployment failed"
    exit 1
fi
echo "PASS deploy: core app deployed"

# ── Signal proxy to route traffic ─────────────────────────────────────────────
# fly deploy creates and health-checks machines internally, but the Fly proxy
# doesn't always route external HTTPS traffic immediately. An explicit
# `fly machines start` via the Machines API signals the proxy to update its
# routing table. Without this, external curls can fail for 100+ seconds even
# though internal health checks pass.
echo ""
echo "==> Signaling Fly proxy to route traffic..."
MACHINE_ID="$(fly machines list --app "${CORE_APP}" --json 2>/dev/null \
    | python3 -c "import json,sys; ms=json.load(sys.stdin); print(ms[0]['id'] if ms else '')" 2>/dev/null || true)"
if [[ -n "$MACHINE_ID" ]]; then
    fly machines start "$MACHINE_ID" --app "${CORE_APP}" 2>/dev/null || true
    echo "    Signaled machine ${MACHINE_ID}"
    sleep 5
fi

echo "==> Waiting for ${CORE_URL}/api/health..."
RETRIES=10
until curl -sf --max-time 15 "${CORE_URL}/api/health" &>/dev/null; do
    if [[ $RETRIES -le 0 ]]; then
        echo "FAIL deploy: health check timed out for ${CORE_URL}"
        exit 1
    fi
    echo "    Not ready — retrying in 10s ($RETRIES attempts left)..."
    sleep 10
    ((RETRIES--))
done
echo "PASS deploy: health check passed"

# ── Migrate ──────────────────────────────────────────────────────────────────
echo ""
echo "==> Running migrations on ${CORE_APP}..."
machine_id="$(fly machines list --app "${CORE_APP}" --json 2>/dev/null \
    | python3 -c "
import json,sys
machines = json.load(sys.stdin)
started = [m for m in machines if m.get('state') == 'started']
print(started[0]['id'] if started else '')
" 2>/dev/null || true)"

if [[ -n "${machine_id}" ]]; then
    fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.migrate()'\"" \
        --app "${CORE_APP}" --timeout 60 2>&1 \
        || { echo "FAIL deploy: migrations failed"; exit 1; }
    echo "PASS deploy: migrations applied"

    # ── Seed ─────────────────────────────────────────────────────────────────
    echo ""
    echo "==> Seeding ${CORE_APP}..."
    fly machine exec "${machine_id}" \
        "/bin/sh -c \"ALLOW_SEEDS=true /app/bin/core eval 'Stacks.Release.seed()'\"" \
        --app "${CORE_APP}" --timeout 60 2>&1 \
        || { echo "FAIL deploy: seeds failed"; exit 1; }
    echo "PASS deploy: seeds applied"
else
    echo "WARN deploy: could not find running machine to run migrations/seeds"
fi

# ── Output ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS deploy: stack is live at ${CORE_URL}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"
echo "    Neon branch: ${NEON_BRANCH_NAME}"
