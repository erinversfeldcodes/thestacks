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
#   NEON_PARENT_BRANCH      — Name of parent branch (default: production).
#                             TODO(Issue #136 follow-up): flip default to
#                             `staging` once that branch is bootstrapped.
#                             See docs/deployment/NEON_BRANCH_TOPOLOGY.md.
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

# ── Retry helper (prod only) ─────────────────────────────────────────────────
# Reviewer P1 #1: transient Fly/Modal/network flakes used to surface as a
# skipped SLO gate in prod, which left the rollback step inactive (its `if`
# pointed only at the gate's conclusion). Wrap every non-core component
# deploy in this helper — two attempts, then a hard exit. A hard failure
# here happens BEFORE core deploys, so no user-facing code is ever published
# in a half-upgraded state.
deploy_with_retry() {
    local name="$1"; shift
    if "$@"; then return 0; fi
    echo "    retry: ${name} failed once; retrying in 5s..."
    sleep 5
    if "$@"; then return 0; fi
    echo "FAIL deploy: ${name} failed twice; aborting before core deploy" >&2
    return 1
}

# Verify that a Fly app has at least one started machine with all its
# `[[checks]]` entries passing. Polls `fly status --json` up to the given
# deadline, returns 0 on success, non-zero on timeout.
#
# `fly deploy` already waits for checks before returning 0, but upstream
# images like searxng/searxng lack curl/wget so we can't double-check
# from inside the container via `fly ssh console -C curl ...`. Parsing
# `fly status --json` is tool-agnostic — it asks Fly's proxy for the
# state of the same health checks defined in the app's fly.toml. No
# in-container tooling assumed; works against any image.
#
# Usage: wait_for_fly_checks <app> <timeout_seconds>
wait_for_fly_checks() {
    local app="$1"
    local timeout="${2:-90}"
    local deadline=$(( $(date +%s) + timeout ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if fly status --app "$app" --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
machines = data.get("Machines") or data.get("machines") or []
healthy = False
for m in machines:
    state = m.get("state", "")
    checks = m.get("checks") or []
    if state == "started" and checks and all(
        (c.get("status") or "").lower() == "passing" for c in checks
    ):
        healthy = True
        break
sys.exit(0 if healthy else 1)
' 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

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
# Production mode: stable app names + existing prod DB (no Neon branch).
# Driven by --production or $STACKS_CORE_PROD=true. Off by default to keep
# the preview flow identical for existing callers.
PROD_MODE=0
if [[ "${STACKS_CORE_PROD:-}" == "true" ]] || [[ "${STACKS_CORE_PROD:-}" == "1" ]]; then
    PROD_MODE=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        --production) PROD_MODE=1; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$BRANCH" ]]; then
    BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
fi

SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"

if [[ "$PROD_MODE" -eq 1 ]]; then
    CORE_APP="${CORE_APP:-thestacks-core}"
    MODAL_APP="${MODAL_APP:-thestacks-vision}"
    # Prod uses the existing production DB via DATABASE_URL — not a Neon
    # branch. Suppress branch creation by clearing NEON_API_KEY locally.
    NEON_API_KEY=""
    echo "==> Deploy stack in PRODUCTION mode"
else
    CORE_APP="stacks-core-pr-${SANITISED}"
    MODAL_APP="thestacks-vision-${SANITISED}"
    echo "==> Deploy stack for branch: ${BRANCH}"
fi
VISION_SERVICE_URL=""
NEON_BRANCH_NAME=""

echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"

# ── Create Neon branch ────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."

    # Parent branch for preview creation. Target is `staging` — a
    # migrations-only + fixture-data branch — so previews NEVER clone
    # production user data. Flipping once staging is bootstrapped; default
    # currently `production` so preview flow keeps working during the
    # Issue #136 pre-launch window. See docs/deployment/NEON_BRANCH_TOPOLOGY.md.
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
    # Reviewer P1 #1: in prod mode, retry the Modal deploy once on failure.
    # Preview mode keeps the original fail-fast behaviour so existing callers
    # (and per-PR ephemeral stacks) aren't silently slowed down by flakes.
    _modal_deploy_once() {
        MODAL_APP_NAME="${MODAL_APP}" \
        MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
            python3 -m modal deploy "${REPO_ROOT}/apps/vision/modal_app.py" 2>&1
    }
    if [[ "$PROD_MODE" -eq 1 ]]; then
        if ! modal_deploy_output="$(_modal_deploy_once)"; then
            echo "    retry: Modal vision deploy failed once; retrying in 5s..."
            sleep 5
            if ! modal_deploy_output="$(_modal_deploy_once)"; then
                echo "$modal_deploy_output"
                echo "FAIL deploy: Modal vision deploy failed twice; aborting before core" >&2
                exit 1
            fi
        fi
    else
        modal_deploy_output="$(_modal_deploy_once)" \
            || { echo "$modal_deploy_output"; echo "FAIL deploy: Modal vision deploy failed"; exit 1; }
    fi
    echo "$modal_deploy_output"

    # Try SDK lookup first, fall back to parsing the deploy output.
    # The SDK call can fail if the function isn't registered yet.
    VISION_SERVICE_URL="$(MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -c "
import modal
f = modal.Function.from_name('${MODAL_APP}', 'vision_api')
print(f.web_url)
" 2>/dev/null || true)"

    # Fallback: parse URL from `modal deploy` output. Modal's tree formatter
    # wraps long URLs across lines with multi-byte UTF-8 box chars (│├└─🔨)
    # that sed can't strip reliably. Use Python for portable parsing.
    if [[ -z "$VISION_SERVICE_URL" || "$VISION_SERVICE_URL" != http* ]]; then
        VISION_SERVICE_URL="$(python3 -c "
import re, sys
text = sys.stdin.read().replace('\n', '')
cleaned = re.sub(r'[│├└─🔨\s]+', '', text)
urls = re.findall(r'https://[^\s(]+\.modal\.run', cleaned)
print(urls[0] if urls else '')
" <<< "$modal_deploy_output" || true)"
        if [[ -n "$VISION_SERVICE_URL" ]]; then
            echo "    (URL from deploy output — SDK lookup was unavailable)"
        fi
    fi
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
if [[ "$PROD_MODE" -eq 1 ]]; then
    SCRAPER_APP="${SCRAPER_APP:-thestacks-scraper}"
else
    SCRAPER_APP="stacks-scraper-pr-${SANITISED}"
fi
SCRAPER_INTERNAL_URL="http://${SCRAPER_APP}.internal:8080"

if [[ -n "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo ""
    echo "==> Deploying scraper (app: ${SCRAPER_APP})..."
    if [[ "$PROD_MODE" -eq 0 ]]; then
        fly apps destroy "${SCRAPER_APP}" --yes 2>&1 | grep -v "^Error" || true
    fi
    fly apps create "${SCRAPER_APP}" 2>&1 || true

    fly secrets set \
        SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}" \
        RUST_LOG="info" \
        --app "${SCRAPER_APP}" --stage

    _scraper_deploy_once() {
        (cd "$REPO_ROOT" && fly deploy \
            --app "${SCRAPER_APP}" \
            --config "${REPO_ROOT}/deploy/fly.scraper.toml" \
            --image-label "pr-${SANITISED}" \
            --depot=false)
    }
    if [[ "$PROD_MODE" -eq 1 ]]; then
        # Prod: retry-once then hard-fail (P1 #1). A silent scraper outage
        # in prod breaks price discovery — must not be tolerated silently.
        if deploy_with_retry "scraper" _scraper_deploy_once; then
            echo "PASS deploy: scraper deployed at ${SCRAPER_INTERNAL_URL}"
        else
            exit 1
        fi
    else
        if _scraper_deploy_once; then
            echo "PASS deploy: scraper deployed at ${SCRAPER_INTERNAL_URL}"
        else
            echo "WARN deploy: scraper deployment failed — core will degrade gracefully"
            SCRAPER_INTERNAL_URL=""
        fi
    fi
elif [[ -z "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo "WARN: SCRAPER_HMAC_SECRET not set — skipping scraper deploy."
    SCRAPER_INTERNAL_URL=""
fi

# ── Deploy SearXNG (ephemeral per preview; stable in prod) ─────────────────
if [[ "$PROD_MODE" -eq 1 ]]; then
    SEARXNG_APP="${SEARXNG_APP:-thestacks-searxng}"
else
    SEARXNG_APP="stacks-searxng-pr-${SANITISED}"
fi
SEARXNG_INTERNAL_URL="http://${SEARXNG_APP}.internal:8080"

if [[ -n "${SEARXNG_SECRET_KEY:-}" ]]; then
    echo ""
    echo "==> Deploying SearXNG (app: ${SEARXNG_APP})..."
    if [[ "$PROD_MODE" -eq 0 ]]; then
        fly apps destroy "${SEARXNG_APP}" --yes 2>&1 | grep -v "^Error" || true
    fi
    fly apps create "${SEARXNG_APP}" 2>&1 || true

    # If the previous deploy pushed the app into a `suspended` state (N
    # consecutive OOM-kill restart attempts), resume before we try again.
    # `fly apps resume` is idempotent — no-ops if the app isn't suspended.
    if [[ "$PROD_MODE" -eq 1 ]]; then
        fly apps resume "${SEARXNG_APP}" 2>&1 | grep -v "^Error" || true
    fi

    fly secrets set \
        SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY}" \
        --app "${SEARXNG_APP}" --stage

    # Render settings.yml into the Docker build context. The Dockerfile
    # COPYs `settings.rendered.yml` into `/etc/searxng/settings.yml`, so
    # the first boot of the container sees our curated 5-engine config
    # instead of the upstream default (which OOM-killed a 256MB VM
    # within seconds). The rendered file is gitignored and cleaned up
    # after the deploy.
    SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml"
    SETTINGS_RENDERED="${REPO_ROOT}/deploy/searxng/settings.rendered.yml"
    sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|g" \
        "${SETTINGS_TEMPLATE}" > "${SETTINGS_RENDERED}"
    trap '[[ -f "${SETTINGS_RENDERED:-/dev/null}" ]] && rm -f "${SETTINGS_RENDERED}"' EXIT

    # CD into the Dockerfile's directory so Fly's remote builder uses it
    # as the build context. Running this from the repo root produced a
    # 2-byte context (root .dockerignore filtered everything) and the
    # COPY settings.rendered.yml failed at build time. See the top
    # comment in deploy/searxng/Dockerfile for the diagnosis.
    _searxng_deploy_once() {
        (cd "$REPO_ROOT/deploy/searxng" && fly deploy \
            --app "${SEARXNG_APP}" \
            --config "${REPO_ROOT}/deploy/fly.searxng.toml" \
            --yes)
    }

    _searxng_success=0
    if [[ "$PROD_MODE" -eq 1 ]]; then
        # SearXNG is in the SLO gate's hot path via /internal/deps-check.
        # If it can't come up healthy, the gate pollutes its measurements:
        # availability drops, real_5xx_rate rises from deps-check 503s,
        # downstream latency SLIs may shift because catalogue-path calls
        # touch SearXNG, and db_pool_queue_p95_ms can creep up from
        # retries eating connections. All false signals relative to
        # core's actual health.
        #
        # Earlier policy was WARN-and-continue on SearXNG failure (on
        # the reasoning that search is non-critical). The gate-pollution
        # problem means that's not an acceptable trade: a SearXNG
        # outage would cause the gate to breach on derived signals and
        # roll core back on a bad diagnosis. Block the deploy up front
        # instead so the rollback path fires on a clean, named signal.
        #
        # Preview mode keeps WARN-and-continue — ephemeral branches
        # aren't rolled back on search-dependency health.
        if ! deploy_with_retry "searxng" _searxng_deploy_once; then
            rm -f "${SETTINGS_RENDERED}"
            echo "FAIL deploy: SearXNG deployment failed after retry — aborting prod release so the gate doesn't run on a polluted SearXNG signal" >&2
            exit 1
        fi

        # SearXNG's first-passing-check can take 3–4 minutes on a
        # cold deploy: custom image build + 512MB VM allocation +
        # Python startup + engine loading. Observed 234s on the
        # 2026-04-20 run — an earlier 90s timeout cleared
        # SEARXNG_URL on core and broke deps-check. 300s gives room.
        echo "==> Verifying SearXNG health via fly status (up to 300s)..."
        if ! wait_for_fly_checks "${SEARXNG_APP}" 300; then
            rm -f "${SETTINGS_RENDERED}"
            echo "FAIL deploy: SearXNG deploy returned 0 but fly status never reported started+passing within 300s — aborting prod release" >&2
            exit 1
        fi
        _searxng_success=1
        echo "PASS deploy: SearXNG healthy at ${SEARXNG_INTERNAL_URL}"
    else
        if _searxng_deploy_once; then
            _searxng_success=1
            echo "PASS deploy: SearXNG deployed at ${SEARXNG_INTERNAL_URL} (preview — no health probe)"
        fi
    fi

    rm -f "${SETTINGS_RENDERED}"

    # Preview-only failure path — prod has already exited on failure
    # above. Core still has SEARXNG_URL from fly.core.toml [env] if it
    # were to reach the gate on a degraded preview, but we don't gate
    # preview anyway.
    if [[ "$_searxng_success" -eq 0 ]]; then
        echo "WARN deploy: SearXNG deployment failed (preview) — core will degrade gracefully"
    fi
else
    echo "WARN: SEARXNG_SECRET_KEY not set — skipping SearXNG deploy."
    SEARXNG_INTERNAL_URL=""
fi

# ── Create core app ───────────────────────────────────────────────────────────
# Do NOT destroy the app between deployments. fly deploy replaces machines
# in-place, so destroy+create is redundant and causes a NXDOMAIN DNS cache
# entry on macOS that breaks all subsequent curl/Node DNS lookups for 5+ min.
echo ""
echo "==> Creating ephemeral Fly app (if not already exists)..."
fly apps create "${CORE_APP}" 2>&1 || true  # noop if app already exists

# Allocate a shared IPv4 address. Fly apps on the Machines platform get IPv6-only
# by default, which means `curl -4` (and GitHub runners, which lack IPv6 connectivity
# to Fly's anycast AAAA edge) cannot reach the app. `--shared` is SNI-routed and
# free; `|| true` because re-allocation on an app that already has one is a noop
# that prints an error.
fly ips allocate-v4 --shared --app "${CORE_APP}" 2>&1 || true

# ── Stage core secrets ────────────────────────────────────────────────────────
# DATABASE_URL sourcing:
#   preview: NEON_CONNECTION_URI was populated by the Neon-branch creation block above.
#   prod:    NEON_API_KEY is cleared → no branch → caller must provide DATABASE_URL
#            directly in the environment (from a GitHub secret in CI, or an operator
#            export for local prod-mode use).
EFFECTIVE_DATABASE_URL="${NEON_CONNECTION_URI:-${DATABASE_URL:-}}"

fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    GUARDIAN_SECRET_KEY="${GUARDIAN_SECRET_KEY:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    VISION_SERVICE_URL="${VISION_SERVICE_URL}" \
    PHX_HOST="${CORE_APP}.fly.dev" \
    RATE_LIMIT_AUTH="60" \
    ${EFFECTIVE_DATABASE_URL:+DATABASE_URL="${EFFECTIVE_DATABASE_URL}"} \
    ${R2_ACCOUNT_ID:+R2_ACCOUNT_ID="${R2_ACCOUNT_ID}"} \
    ${R2_ACCESS_KEY_ID:+R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"} \
    ${R2_SECRET_ACCESS_KEY:+R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"} \
    ${R2_BUCKET_NAME:+R2_BUCKET_NAME="${R2_BUCKET_NAME}"} \
    ${VISION_TOGETHER_API_KEY:+VISION_TOGETHER_API_KEY="${VISION_TOGETHER_API_KEY}"} \
    ${SCRAPER_HMAC_SECRET:+SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}"} \
    ${SCRAPER_INTERNAL_URL:+SCRAPER_SERVICE_URL="${SCRAPER_INTERNAL_URL}"} \
    ${SEARXNG_INTERNAL_URL:+SEARXNG_URL="${SEARXNG_INTERNAL_URL}"} \
    ${BRAVE_SEARCH_API_KEY:+BRAVE_SEARCH_API_KEY="${BRAVE_SEARCH_API_KEY}"} \
    ${GOOGLE_BOOKS_API_KEY:+GOOGLE_BOOKS_API_KEY="${GOOGLE_BOOKS_API_KEY}"} \
    ${RESEND_API_KEY:+RESEND_API_KEY="${RESEND_API_KEY}" EMAIL_PROVIDER="resend"} \
    ${STACKS_APP_DB_PASSWORD:+STACKS_APP_DB_PASSWORD="${STACKS_APP_DB_PASSWORD}"} \
    ${STACKS_DBT_DB_PASSWORD:+STACKS_DBT_DB_PASSWORD="${STACKS_DBT_DB_PASSWORD}"} \
    ${METRICS_SCRAPE_TOKEN:+METRICS_SCRAPE_TOKEN="${METRICS_SCRAPE_TOKEN}"} \
    ${PROD_OWNER_EMAIL:+PROD_OWNER_EMAIL="${PROD_OWNER_EMAIL}"} \
    ${PROD_OWNER_PASSWORD:+PROD_OWNER_PASSWORD="${PROD_OWNER_PASSWORD}"} \
    SMOKE_TESTS_ENABLED="true" \
    --app "${CORE_APP}" --stage

# ── DATABASE_URL assertion (prod only, P2 #9) ────────────────────────────────
# On a brand-new prod app no DATABASE_URL is configured yet, and
# `${NEON_CONNECTION_URI:+...}` above means we only set it from a preview
# Neon branch. In prod mode DATABASE_URL must already be present as a Fly
# secret (the operator-blessed prod Neon connection string). If it isn't,
# boot fails with a cryptic runtime.exs raise after the container has
# already rolled. Fail fast here with a clear message instead.
if [[ "$PROD_MODE" -eq 1 ]]; then
    echo ""
    echo "==> Verifying DATABASE_URL was composed for ${CORE_APP}..."
    # Check the env-var we just fed to `fly secrets set` rather than querying
    # Fly back — on a never-successfully-deployed app, staged-but-uncommitted
    # secrets don't always show in `fly secrets list`. If EFFECTIVE_DATABASE_URL
    # is non-empty here, the Fly stage call above received it; if empty, the
    # caller (deploy-production.yml Compose step) didn't provide DATABASE_URL
    # or a Neon preview URI, and boot would fail cryptically at runtime.exs.
    if [[ -z "${EFFECTIVE_DATABASE_URL:-}" ]]; then
        echo "FAIL deploy: DATABASE_URL is empty." >&2
        echo "  Prod mode requires DATABASE_URL from the calling environment." >&2
        echo "  In CI, verify the 'Compose DATABASE_URL' step in" >&2
        echo "  .github/workflows/deploy-production.yml ran and produced a" >&2
        echo "  non-empty value from the STACKS_PROD_DB_* component secrets." >&2
        exit 1
    fi
    echo "PASS deploy: DATABASE_URL composed (length: ${#EFFECTIVE_DATABASE_URL})"
fi

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

# ── Generate Ecto schemas from proto ────────────────────────────────────────
# Use gen-ecto-proto.sh instead of `mix proto.sync` — it bootstraps without
# requiring app compilation (avoids chicken-and-egg when gen/ is gitignored).
echo ""
echo "==> Generating Ecto schemas from proto..."
bash "$REPO_ROOT/scripts/gen-ecto-proto.sh" \
    || { echo "FAIL deploy: gen-ecto-proto.sh failed"; exit 1; }
# Also generate inter-service proto structs (AssociateRequest etc.)
python3 "$REPO_ROOT/scripts/gen_python_proto.py" --language elixir \
    || { echo "FAIL deploy: gen_python_proto.py --language elixir failed"; exit 1; }
if [[ ! -d "$REPO_ROOT/apps/core/lib/stacks/gen" ]] || [[ -z "$(ls -A "$REPO_ROOT/apps/core/lib/stacks/gen" 2>/dev/null)" ]]; then
    echo "FAIL deploy: apps/core/lib/stacks/gen/ is empty after generation"; exit 1
fi
echo "    Ecto schemas generated to apps/core/lib/stacks/gen/"

# ── Build frontend assets ─────────────────────────────────────────────────────
echo ""
echo "==> Rebuilding frontend assets via esbuild..."
if command -v node &>/dev/null && [[ -f "$REPO_ROOT/apps/core/assets/build.js" ]]; then
    # Clear Elm incremental build cache before every deploy. The esbuild-plugin-elm
    # uses elm-stuff/ as a compilation cache keyed by file mtime, not content hash.
    # A stale cache can produce an identical app.js even when Elm source changes.
    echo "    Clearing Elm incremental build cache (elm-stuff/)..."
    rm -rf "$REPO_ROOT/apps/core/assets/elm/elm-stuff"
    (cd "$REPO_ROOT/apps/core/assets" && node build.js --production) \
        || { echo "FAIL deploy: frontend build failed"; exit 1; }
    echo "    app.js rebuilt"
    # Verify textures were copied (build.js follows static/textures symlink)
    if [[ -d "$REPO_ROOT/apps/core/priv/static/textures" ]]; then
        echo "    textures: $(ls "$REPO_ROOT/apps/core/priv/static/textures/" | wc -l | tr -d ' ') files in priv/static/textures/"
    else
        echo "    WARN: priv/static/textures/ not found after build — mix phx.digest will fail"
    fi
else
    echo "    SKIP: node or build.js not found — Docker build will handle it"
fi

# ── Deploy core ──────────────────────────────────────────────────────────────
CORE_URL="https://${CORE_APP}.fly.dev"

# Debug: verify static assets exist before sending to Fly builder
echo ""
echo "==> Pre-deploy static asset check:"
echo "    priv/static/ contents:"
ls -la "$REPO_ROOT/apps/core/priv/static/" 2>/dev/null || echo "    ERROR: priv/static/ does not exist!"
echo "    priv/static/textures/ file count: $(ls "$REPO_ROOT/apps/core/priv/static/textures/" 2>/dev/null | wc -l | tr -d ' ')"
echo "    priv/static/textures/ total size: $(du -sh "$REPO_ROOT/apps/core/priv/static/textures/" 2>/dev/null | cut -f1 || echo 'N/A')"
echo "    priv/static/index.html exists: $(test -f "$REPO_ROOT/apps/core/priv/static/index.html" && echo 'yes' || echo 'NO')"
echo "    sample texture file size: $(wc -c "$REPO_ROOT/apps/core/priv/static/textures/spine-cloth-brown.png" 2>/dev/null | awk '{print $1}' || echo 'N/A') bytes"
echo ""
echo "==> Deploying ${CORE_APP}..."
# Pass a unique ASSET_HASH to bust the remote builder cache for priv/static.
# Without this, the builder reuses a stale COPY layer from a previous build
# that may not have included textures or freshly-built assets.
ASSET_HASH="$(date +%s)-$(git rev-parse --short HEAD)"
if ! (cd "$REPO_ROOT" && fly deploy \
        --app "${CORE_APP}" \
        --config "${REPO_ROOT}/deploy/fly.core.toml" \
        --image-label "pr-${SANITISED}" \
        --depot=false \
        --build-arg "ASSET_HASH=${ASSET_HASH}"); then
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
fly machines list --app "${CORE_APP}" --json 2>/dev/null \
| python3 -c "
import json,sys
for m in json.load(sys.stdin):
    print(m['id'])
" 2>/dev/null | while read -r mid; do
    fly machines start "$mid" --app "${CORE_APP}" 2>/dev/null && \
        echo "    Signaled machine ${mid}" || true
done
sleep 5

echo "==> Waiting for ${CORE_URL}/api/health..."
# After fly apps destroy → fly apps create, macOS caches a stale NXDOMAIN for
# the hostname. Flushing requires sudo. Instead, tunnel via fly proxy which uses
# Fly's WireGuard connection and needs no DNS resolution at all.
_PROXY_PORT=14987
fly proxy "${_PROXY_PORT}:4000" --app "${CORE_APP}" >/dev/null 2>&1 &
_PROXY_PID=$!

RETRIES=30
until curl -sf --max-time 10 "http://localhost:${_PROXY_PORT}/api/health" >/dev/null 2>&1; do
    if [[ $RETRIES -le 0 ]]; then
        kill "${_PROXY_PID}" 2>/dev/null || true
        echo "--- Fly app logs (last 30 lines) ---"
        (fly logs --app "${CORE_APP}" 2>&1 & sleep 8; kill %1 2>/dev/null) | tail -30 || true
        echo "--- End logs ---"
        echo "FAIL deploy: health check timed out for ${CORE_URL}"
        exit 1
    fi
    echo "    Not ready — retrying in 5s ($RETRIES attempts left)..."
    sleep 5
    ((RETRIES--))
done
kill "${_PROXY_PID}" 2>/dev/null || true
wait "${_PROXY_PID}" 2>/dev/null || true
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
    # Prod and preview run DIFFERENT seed paths:
    #   prod:    Stacks.Release.seed_prod/0 — creates one owner user from
    #            PROD_OWNER_EMAIL + PROD_OWNER_PASSWORD fly secrets. Idempotent.
    #   preview: Stacks.Release.seed/0 (gated by ALLOW_SEEDS=true) — full
    #            dev fixture set for CI/E2E.
    echo ""
    if [[ "$PROD_MODE" -eq 1 ]]; then
        echo "==> Seeding ${CORE_APP} (prod owner only)..."
        fly machine exec "${machine_id}" \
            "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.seed_prod()'\"" \
            --app "${CORE_APP}" --timeout 60 2>&1 \
            || { echo "FAIL deploy: prod seed failed"; exit 1; }
        echo "PASS deploy: prod owner seed applied"
    else
        echo "==> Seeding ${CORE_APP} (dev fixtures)..."
        fly machine exec "${machine_id}" \
            "/bin/sh -c \"ALLOW_SEEDS=true /app/bin/core eval 'Stacks.Release.seed()'\"" \
            --app "${CORE_APP}" --timeout 60 2>&1 \
            || { echo "FAIL deploy: seeds failed"; exit 1; }
        echo "PASS deploy: dev seeds applied"
    fi
else
    echo "WARN deploy: could not find running machine to run migrations/seeds"
fi

# ── Deploy log shipper (prod only) ────────────────────────────────────────────
# One shipper per Fly org, not per preview. Fly's NATS log broadcast is
# org-scoped (`logs.>` emits every app's stdout/stderr), so a single
# subscriber captures core + vision + scraper + SearXNG + every preview
# app — we'd waste money + burn Axiom quota running one per PR. The
# preview branch of this script therefore skips the shipper entirely;
# preview logs still reach Axiom via the single prod shipper.
#
# Graceful-on-failure: the shipper going down doesn't block a release.
# Logs simply stop flowing to Axiom until the next successful deploy.
# Monitor via Axiom-side "no ingest for N min" alerts (future work).
#
# First-deploy bootstrap: if `thestacks-log-shipper` doesn't exist yet,
# `fly apps create` makes it, secrets stage, `fly deploy` builds the
# image from deploy/log-shipper/Dockerfile. No manual operator step.
if [[ "$PROD_MODE" -eq 1 ]] && [[ -n "${LOG_SHIPPER_ACCESS_TOKEN:-}" ]]; then
    LOG_SHIPPER_APP="${LOG_SHIPPER_APP:-thestacks-log-shipper}"
    echo ""
    echo "==> Deploying log shipper (app: ${LOG_SHIPPER_APP})..."

    fly apps create "${LOG_SHIPPER_APP}" 2>&1 || true

    # ORG is hardcoded in fly.log-shipper.toml [env], so we only stage
    # the secret env vars. AXIOM_TOKEN / AXIOM_DATASET are empty-safe
    # via the `${VAR:-}` expansion — a missing Axiom credential is
    # surfaced as a Vector startup error rather than a script-level
    # unbound-variable crash.
    fly secrets set \
        LOG_SHIPPER_ACCESS_TOKEN="${LOG_SHIPPER_ACCESS_TOKEN}" \
        AXIOM_TOKEN="${AXIOM_TOKEN:-}" \
        AXIOM_DATASET="${AXIOM_DATASET:-}" \
        --app "${LOG_SHIPPER_APP}" --stage

    # CD into the Dockerfile's directory for the same reason as the
    # SearXNG deploy above — CWD wins over --config's directory for
    # Fly's build context.
    _log_shipper_deploy_once() {
        (cd "$REPO_ROOT/deploy/log-shipper" && fly deploy \
            --app "${LOG_SHIPPER_APP}" \
            --config "${REPO_ROOT}/deploy/fly.log-shipper.toml" \
            --yes)
    }

    if deploy_with_retry "log-shipper" _log_shipper_deploy_once; then
        # Same reasoning as SearXNG's 300s timeout above — cold image
        # build + VM boot + Vector's config parse + NATS source
        # connection + API server start. Vector is lighter than
        # SearXNG but still far from instant on a cold deploy.
        echo "==> Verifying log shipper health via fly status (up to 300s)..."
        # Vector's built-in /health on :8686 is what fly.log-shipper.toml's
        # [[checks]] block hits. Same rationale as SearXNG: parse Fly's
        # own report rather than running curl inside the container. A
        # previous iteration tried `fly ssh console -C curl localhost:8686`
        # and silently broke on base images that ship without curl.
        if wait_for_fly_checks "${LOG_SHIPPER_APP}" 300; then
            echo "PASS deploy: log shipper deployed"
        else
            echo "WARN deploy: log shipper deploy returned 0 but fly status never reported passing checks within 300s — logs may not ship until next deploy, core unaffected"
        fi
    else
        echo "WARN deploy: log shipper deployment failed — logs will not ship this cycle, core unaffected"
    fi
elif [[ "$PROD_MODE" -eq 1 ]]; then
    echo "WARN: LOG_SHIPPER_ACCESS_TOKEN not set — skipping log shipper deploy (logs will not persist beyond Fly's short retention)."
fi

# ── Vision pipeline warmup ────────────────────────────────────────────────────
# Pre-warm Modal's vision containers before the SLO gate (or E2E tests) start
# probing. Without this the gate's first probe iteration IS the first request
# post-deploy — every /analyze call hits a cold H100 container (~30-60s to
# load vLLM + model weights into GPU memory). The gate's 6-parallel-canary
# burst forces Modal to scale out, so several containers cold-start
# concurrently; those slow samples live in the p95's top 5 %, dragging the
# measurement ~1.5 s above the steady-state figure.
#
# Strategy: fire all 6 gate canaries in parallel so Modal spawns the same
# container count the gate will demand. `scaledown_window=1200` (20 min on
# the @app.cls decorator) keeps them warm through the 10-min gate window.
#
# Credentials: PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD (same vars
# check-slo-gate.sh uses — set in the production workflow from
# PROD_OWNER_EMAIL / PROD_OWNER_PASSWORD secrets). Dev defaults
# (owner@thestacks.app / dev-password-123) match the seeded preview user.
#
# Failure handling: an individual upload or stream timeout is a WARN, not a
# FAIL — a warmup that couldn't complete still partially pre-spawned
# containers, which is better than no warmup. Only auth failure is fatal,
# since it implies the new deploy can't talk to its own auth endpoint.

WARMUP_EMAIL="${PROBE_SEED_EMAIL:-owner@thestacks.app}"
WARMUP_PASSWORD="${PROBE_SEED_PASSWORD:-dev-password-123}"

# Canaries match scripts/probe-production.sh's burst set — firing the same
# six images Modal will see during the gate maximises the proportion of
# warm-path requests once the gate starts.
warmup_canaries=(
    "${REPO_ROOT}/images/barcode_isbn_clean.jpg"
    "${REPO_ROOT}/images/not_a_book.jpg"
    "${REPO_ROOT}/images/screenshot_image_reversed.jpg"
    "${REPO_ROOT}/images/screenshot_image_reversed_and_cut_off.jpg"
    "${REPO_ROOT}/images/screenshot_mildly_obscured.jpg"
    "${REPO_ROOT}/images/screenshot_mixed_text.jpg"
)

echo ""
echo "==> Vision pipeline warmup against ${CORE_URL}/api/upload..."

# Wait for external edge routing. deploy-stack.sh already verified health
# via fly-proxy (localhost path), but Fly's anycast edge can lag by a minute
# after deploy while learning about the new machines. Poll up to ~2 min.
echo "    Waiting for external edge routing (${CORE_URL}/api/health)..."
edge_ready=0
for _ in $(seq 1 24); do
    edge_code="$(curl -4 -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "${CORE_URL}/api/health" || true)"
    if [[ "${edge_code}" == "200" ]]; then
        edge_ready=1
        echo "    Edge routing ready (HTTP 200)."
        break
    fi
    sleep 5
done
if [[ $edge_ready -ne 1 ]]; then
    echo "WARN warmup: external edge never returned HTTP 200 (last: ${edge_code}) — skipping vision warmup"
    echo ""
    echo "PASS deploy: stack is live at ${CORE_URL}"
    echo "    Core app:    ${CORE_APP}"
    echo "    Modal app:   ${MODAL_APP}"
    echo "    Neon branch: ${NEON_BRANCH_NAME}"
    exit 0
fi

# Build the login JSON via python's json.dumps rather than shell interpolation
# so credentials with quotes/backslashes round-trip safely. Pass the secrets
# as argv — env-var indirection doesn't survive `<(process substitution)`
# reliably, which caused a KeyError: 'WARMUP_EMAIL' at first cut.
login_body_file="$(mktemp)"
login_payload_file="$(mktemp)"
python3 -c "import json,sys; json.dump({'email':sys.argv[1],'password':sys.argv[2]}, sys.stdout)" \
    "${WARMUP_EMAIL}" "${WARMUP_PASSWORD}" > "${login_payload_file}"
smoke_login_code="$(curl -4 -s -o "${login_body_file}" -w "%{http_code}" \
    --max-time 30 \
    "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    --data-binary @"${login_payload_file}" \
    || true)"
rm -f "${login_payload_file}"
smoke_login="$(cat "${login_body_file}" 2>/dev/null || true)"
rm -f "${login_body_file}"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${smoke_token}" ]]; then
    echo "FAIL warmup: could not authenticate as warmup user (HTTP ${smoke_login_code})"
    echo "    Check PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD."
    exit 1
fi

# Fire all canaries in parallel so Modal sees the same scale-out demand
# shape the gate will generate. Collect image_ids from the 202 responses.
echo "    Uploading ${#warmup_canaries[@]} canaries in parallel..."
warmup_dir="$(mktemp -d)"
upload_pids=()
for img in "${warmup_canaries[@]}"; do
    (
        img_name="$(basename "$img")"
        body_file="${warmup_dir}/upload_${img_name}"
        http_code="$(curl -4 -s -o "${body_file}" -w "%{http_code}" \
            --max-time 30 \
            -X POST "${CORE_URL}/api/upload" \
            -H "Authorization: Bearer ${smoke_token}" \
            -F "image=@${img}" 2>/dev/null || true)"
        if [[ "${http_code}" == "202" ]]; then
            img_id="$(python3 -c \
                "import json,sys; print(json.load(open('${body_file}')).get('image_id',''))" \
                2>/dev/null || true)"
            echo "${img_id}" > "${warmup_dir}/id_${img_name}"
        fi
    ) &
    upload_pids+=("$!")
done
for pid in "${upload_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

warmup_ids=()
for img in "${warmup_canaries[@]}"; do
    img_name="$(basename "$img")"
    id_file="${warmup_dir}/id_${img_name}"
    if [[ -f "$id_file" ]] && img_id="$(cat "$id_file")" && [[ -n "$img_id" ]]; then
        warmup_ids+=("$img_id")
        echo "    ${img_name}: accepted (image_id=${img_id})"
    else
        echo "    ${img_name}: upload did not return 202 — skipping"
    fi
done

if [[ ${#warmup_ids[@]} -eq 0 ]]; then
    echo "WARN warmup: all uploads failed — app may be broken, but the deploy step already passed health checks"
    rm -rf "${warmup_dir}"
    echo ""
    echo "PASS deploy: stack is live at ${CORE_URL}"
    echo "    Core app:    ${CORE_APP}"
    echo "    Modal app:   ${MODAL_APP}"
    echo "    Neon branch: ${NEON_BRANCH_NAME}"
    exit 0
fi

# Stream each pipeline's SSE channel so Modal runs the full /analyze call
# and spawns a container per concurrent request (up to max_containers=10).
# Bound by --max-time 480 (8 min) — a cold H100 container should boot
# within this; if not, Modal is unhealthy enough that the gate will catch
# it regardless.
echo "    Streaming ${#warmup_ids[@]} warmup pipelines in parallel (up to 8 min each)..."
stream_pids=()
for img_id in "${warmup_ids[@]}"; do
    (
        stream_resp="$(curl -4 -sf --max-time 480 \
            "${CORE_URL}/api/upload/${img_id}/stream?token=${smoke_token}" \
            2>/dev/null || true)"
        echo "${stream_resp}" | python3 -c \
            "import json,sys
lines=[l.strip() for l in sys.stdin if l.startswith('data:')]
d=json.loads(lines[-1][5:]) if lines else {}
print(d.get('status','timeout'))" \
            > "${warmup_dir}/status_${img_id}" 2>/dev/null \
            || echo "timeout" > "${warmup_dir}/status_${img_id}"
    ) &
    stream_pids+=("$!")
done
for pid in "${stream_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

all_terminal=1
for img_id in "${warmup_ids[@]}"; do
    img_status="$(cat "${warmup_dir}/status_${img_id}" 2>/dev/null || echo "timeout")"
    echo "    ${img_id}: ${img_status}"
    if [[ "${img_status}" != "resolved" && "${img_status}" != "rejected" ]]; then
        all_terminal=0
    fi
done
rm -rf "${warmup_dir}"

if [[ $all_terminal -eq 1 ]]; then
    echo "PASS warmup: all ${#warmup_ids[@]} pipelines resolved/rejected — Modal containers warm"
else
    echo "WARN warmup: one or more pipelines timed out — Modal may still be partially cold"
    echo "    The SLO gate will likely still pass, but p95 may reflect the remaining cold-start tail."
fi

# ── Output ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS deploy: stack is live at ${CORE_URL}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"
echo "    Neon branch: ${NEON_BRANCH_NAME}"
