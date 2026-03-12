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
#   MODAL_TOKEN_ID      — Modal API token ID (vision sidecar calls Modal for inference)
#   MODAL_TOKEN_SECRET  — Modal API token secret
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

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

# Prefer ~/.local/bin/flyctl (installed via scripts/install-flyctl.sh) over any
# stale system flyctl (e.g. the superfly/homebrew-tap, last updated 2023).
export PATH="${HOME}/.local/bin:${PATH}"

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
# Vision sidecar runs as a Modal-hosted ASGI app (not a Fly machine).
# The endpoint is permanent and shared across all preview deploys.
VISION_SIDECAR_URL="https://erinversfeldcodes--thestacks-vision-vision-api.modal.run"
NEON_BRANCH_ID=""

echo "==> Deploy preview for branch: ${BRANCH}"
echo "    Core app:    ${CORE_APP}"
echo "    Vision URL:  ${VISION_SIDECAR_URL}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    local neon_args=""
    [[ -n "$NEON_BRANCH_ID" ]] && neon_args="--neon-branch-id ${NEON_BRANCH_ID}"
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" --branch "${BRANCH}" ${neon_args}
}
trap cleanup EXIT

# ── Pre-warm Modal container (cold start ~30s, amortised across deploy time) ──
# Modal's scaledown_window keeps the container alive between requests during a
# deploy session. No explicit pre-warm needed — the first E2E test will trigger
# the container start, which is fast enough (~30s) to not impact test timeouts.

# ── Create Neon branch ────────────────────────────────────────────────────────
if [[ -n "${NEON_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."

    # If a stale branch with this name exists (e.g. from a previously killed run),
    # delete it first so the create below succeeds cleanly.
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
        echo "    Deleting stale branch ${stale_id}..."
        curl -sL -X DELETE \
            -H "Authorization: Bearer ${NEON_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${stale_id}" > /dev/null
    fi

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

# ── Deploy vision sidecar to Modal ────────────────────────────────────────────
# The vision sidecar is a Modal-hosted ASGI app. Deploy it here so the latest
# code is live before the core app starts calling it. If apps/vision/ hasn't
# changed since the last deploy, Modal's build cache makes this near-instant.
if [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]]; then
    echo ""
    echo "==> Syncing Modal secret 'thestacks-vision'..."
    # Include MODAL_TOKEN_ID/SECRET in the Modal secret so vision_api's Python
    # SDK can authenticate when making cross-container calls to VisionModel.
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal secret create thestacks-vision \
            "VISION_HMAC_SECRET=${VISION_HMAC_SECRET:-}" \
            "MODAL_TOKEN_ID=${MODAL_TOKEN_ID}" \
            "MODAL_TOKEN_SECRET=${MODAL_TOKEN_SECRET}" \
            --force 2>&1 || { echo "FAIL deploy: Modal secret sync failed"; exit 1; }

    echo ""
    echo "==> Deploying vision sidecar to Modal..."
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        python3 -m modal deploy "${REPO_ROOT}/apps/vision/modal_app.py" 2>&1 \
        || { echo "FAIL deploy: Modal vision deploy failed"; exit 1; }
    echo "PASS deploy: vision sidecar deployed to Modal"
else
    echo "WARN: MODAL_TOKEN_ID/MODAL_TOKEN_SECRET not set — skipping Modal vision deploy."
    echo "      The existing Modal deployment (if any) will be used."
fi

# ── Create core app (destroy any stale one first) ─────────────────────────────
echo ""
echo "==> Creating ephemeral Fly app..."
fly apps destroy "${CORE_APP}" --yes 2>&1 | grep -v "^Error" || true
fly apps create "${CORE_APP}" 2>&1 || true

# ── Stage core secrets ────────────────────────────────────────────────────────
# Stage before deploy so they're available on first boot.
fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    VISION_SIDECAR_URL="${VISION_SIDECAR_URL}" \
    PHX_HOST="${CORE_APP}.fly.dev" \
    ${NEON_CONNECTION_URI:+DATABASE_URL="${NEON_CONNECTION_URI}"} \
    --app "${CORE_APP}" --stage

# ── Deploy core (then vision if changed) — sequential ─────────────────────────
# fly deploy blocks until release_command (migrations) + health checks pass.
# Sequential avoids simultaneous Fly Machines API polling that causes timeouts.
#
# fly_deploy_with_retry <app> <toml> <label>
# fly deploy sometimes exits non-zero due to local TCP port exhaustion
# (EADDRNOTAVAIL / "request canceled") during health check polling.  In that
# case the machine is often actually running fine.  After any failure we check
# the HTTPS health endpoint directly; if it responds we treat the deploy as
# successful.  If not, we wait 120s (clears TIME_WAIT sockets) and retry once.
fly_deploy_with_retry() {
    local app="$1" toml="$2" label="$3"
    local app_url="https://${app}.fly.dev"
    local attempt

    for attempt in 1 2; do
        if (cd "$REPO_ROOT" && fly deploy \
                --app "${app}" \
                --config "${toml}" \
                --image-label "${label}"); then
            return 0
        fi

        echo "    fly deploy failed (attempt ${attempt}/2) — checking if app is reachable..."
        local retries=6
        while [[ $retries -gt 0 ]]; do
            if curl -sf --max-time 10 "${app_url}/api/health" &>/dev/null; then
                echo "    App is healthy at ${app_url} — treating deploy as successful."
                return 0
            fi
            sleep 10
            ((retries--))
        done

        if [[ $attempt -lt 2 ]]; then
            echo "    App not reachable — waiting 120s for machines + TCP sockets to settle, then retrying..."
            sleep 120
        fi
    done
    return 1
}

CORE_URL="https://${CORE_APP}.fly.dev"

echo ""
echo "==> Deploying ${CORE_APP}..."
if ! fly_deploy_with_retry "${CORE_APP}" "${REPO_ROOT}/deploy/fly.core.toml" "pr-${SANITISED}"; then
    echo "FAIL deploy: core app deployment failed"
    exit 1
fi
echo "PASS deploy: core app deployed"

# ── Health check immediately after core deploy ────────────────────────────────
# Run this BEFORE vision deploy: auto_stop_machines=true means the core machine
# can stop if no traffic arrives during the vision build (~3 min). By hitting
# the health endpoint here we keep it warm and confirm it started correctly.
echo ""
echo "==> Waiting for ${CORE_URL}/api/health..."
RETRIES=18
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

# ── Seed the Neon branch ──────────────────────────────────────────────────────
# Migrations ran inside fly deploy (release_command in fly.core.toml).
# Seeds are preview-only fixtures, so we run them separately via fly machine exec
# which goes through the Fly Machines API — no WireGuard/SSH tunnel required.
echo ""
echo "==> Seeding ${CORE_APP}..."
machine_id="$(fly machines list --app "${CORE_APP}" --json 2>/dev/null \
    | python3 -c "
import json,sys
machines = json.load(sys.stdin)
started = [m for m in machines if m.get('state') == 'started']
print(started[0]['id'] if started else '')
" 2>/dev/null || true)"

if [[ -n "${machine_id}" ]]; then
    fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.seed()'\"" \
        --app "${CORE_APP}" --timeout 60 2>&1 \
        || { echo "FAIL deploy: seeds failed"; exit 1; }
    echo "PASS deploy: seeds applied"
else
    echo "WARN deploy: could not find running machine to run seeds"
fi

e2e_failed=0

# ── Upload smoke test + warmup (warms Modal GPU container for all E2E images) ──
# Submit all 4 E2E test images concurrently to warm the VisionModel GPU container
# and pre-resolve all book records. When E2E tests run, Books.find_existing(isbn)
# returns immediately, and VisionModel containers are already warm.
echo ""
echo "==> Upload smoke test / warmup against ${CORE_URL}/api/upload..."
smoke_login="$(curl -sf "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null || true)"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
if [[ -n "${smoke_token}" ]]; then
    # Submit all 4 E2E test images (the same images Playwright will use).
    warmup_images=(
        "${REPO_ROOT}/images/screenshot_mildly_obscured.jpg"
        "${REPO_ROOT}/images/screenshot_image_reversed_and_cut_off.jpg"
        "${REPO_ROOT}/images/screenshot_image_reversed.jpg"
        "${REPO_ROOT}/images/screenshot_mixed_text.jpg"
    )
    warmup_ids=()
    for img in "${warmup_images[@]}"; do
        img_name="$(basename "$img")"
        body_file="$(mktemp)"
        http_code="$(curl -s -o "${body_file}" -w "%{http_code}" \
            -X POST "${CORE_URL}/api/upload" \
            -H "Authorization: Bearer ${smoke_token}" \
            -F "image=@${img}" 2>/dev/null || true)"
        body="$(cat "${body_file}")"
        rm -f "${body_file}"
        if [[ "${http_code}" == "202" ]]; then
            img_id="$(echo "${body}" | python3 -c \
                "import json,sys; print(json.load(sys.stdin).get('image_id',''))" 2>/dev/null || true)"
            echo "    ${img_name}: accepted (image_id=${img_id})"
            warmup_ids+=("${img_id}")
        else
            echo "    ${img_name}: upload returned HTTP ${http_code} — skipping"
        fi
    done

    if [[ ${#warmup_ids[@]} -eq 0 ]]; then
        echo "FAIL deploy: all warmup uploads failed"
        e2e_failed=1
    else
        echo "    Polling until all ${#warmup_ids[@]} warmup pipelines complete (max 5 min)..."
        warmup_deadline=$(( $(date +%s) + 300 ))
        # Track done IDs as a space-separated string (bash 3.2 compatible; no declare -A).
        warmup_done_ids=""
        all_done=0
        while [[ $(date +%s) -lt $warmup_deadline ]]; do
            all_done=1
            for img_id in "${warmup_ids[@]}"; do
                # Skip if already marked done.
                case " ${warmup_done_ids} " in
                    *" ${img_id} "*) continue ;;
                esac
                poll_resp="$(curl -sf "${CORE_URL}/api/upload/${img_id}/status" \
                    -H "Authorization: Bearer ${smoke_token}" 2>/dev/null || true)"
                poll_status="$(echo "${poll_resp}" | python3 -c \
                    "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)"
                if [[ "${poll_status}" == "resolved" || "${poll_status}" == "rejected" ]]; then
                    echo "    ${img_id}: ${poll_status}"
                    warmup_done_ids="${warmup_done_ids} ${img_id}"
                else
                    all_done=0
                fi
            done
            if [[ $all_done -eq 1 ]]; then
                break
            fi
            sleep 5
        done
        # Count done ids (words in string).
        done_count=$(echo "${warmup_done_ids}" | wc -w | tr -d ' ')
        if [[ $all_done -eq 1 ]]; then
            echo "PASS deploy: warmup passed (all pipelines resolved/rejected)"
        else
            remaining=$(( ${#warmup_ids[@]} - done_count ))
            echo "WARN deploy: warmup timed out — ${remaining}/${#warmup_ids[@]} pipeline(s) still pending"
            echo "--- Core app logs (last 60 lines for diagnosis) ---"
            (fly logs --app "${CORE_APP}" 2>&1 &
             FLY_LOG_PID=$!
             sleep 10
             kill $FLY_LOG_PID 2>/dev/null
             wait $FLY_LOG_PID 2>/dev/null) | tail -60 || true
            echo "--- End core logs ---"
        fi
    fi
else
    echo "WARN deploy: warmup skipped — could not authenticate"
fi

# ── Run Playwright E2E against deployed stack ─────────────────────────────────
# Keep the Fly machine alive with a background ping during Playwright setup
# (Playwright installs browsers on first run — 30-120s with no app traffic,
# which can trigger Fly's auto_stop_machines and cold-start the machine).
echo ""
echo "==> Running Playwright E2E against ${CORE_URL}..."
(while true; do
    curl -sf --max-time 5 "${CORE_URL}/api/health" >/dev/null 2>&1 || true
    sleep 10
done) &
KEEP_ALIVE_PID=$!

# Capture Fly logs during E2E so we can diagnose upload pipeline failures.
FLY_LOGS_FILE="$(mktemp)"
(fly logs --app "${CORE_APP}" 2>&1) > "${FLY_LOGS_FILE}" &
FLY_LOGS_PID=$!

E2E_SERVICES=none BASE_URL="${CORE_URL}" bash "${REPO_ROOT}/scripts/test-e2e.sh" 2>&1 || e2e_failed=1

kill "${KEEP_ALIVE_PID}" 2>/dev/null || true
sleep 3  # Let log capture drain any final lines
kill "${FLY_LOGS_PID}" 2>/dev/null || true
wait "${FLY_LOGS_PID}" 2>/dev/null || true

echo ""
echo "--- Core app logs during E2E (last 200 lines) ---"
tail -200 "${FLY_LOGS_FILE}" || true
echo "--- End core logs ---"
rm -f "${FLY_LOGS_FILE}"

# ── Post-E2E DB diagnostic (runs always, most useful when E2E fails) ──────────
# Query the DB directly for recent uploaded_images and oban_jobs so we can see
# whether Oban jobs completed, were rejected, or never ran.
if [[ -n "${NEON_CONNECTION_URI:-}" ]] && command -v psql &>/dev/null; then
    echo ""
    echo "--- DB: recent uploaded_images (last 10) ---"
    psql "${NEON_CONNECTION_URI}" -c \
        "SELECT id, status, inserted_at FROM op.uploaded_images ORDER BY inserted_at DESC LIMIT 10;" \
        2>/dev/null || true
    echo ""
    echo "--- DB: oban_jobs in vision queue (last 10) ---"
    psql "${NEON_CONNECTION_URI}" -c \
        "SELECT id, state, attempt, max_attempts, errors::text, inserted_at FROM oban_jobs WHERE queue='vision' ORDER BY inserted_at DESC LIMIT 10;" \
        2>/dev/null || true
    echo "--- End DB diagnostics ---"
fi

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

# ── Nuclei (JWT + misconfig templates) ───────────────────────────────────────
echo ""
if command -v nuclei &>/dev/null; then
    echo "==> Running Nuclei (jwt + misconfig) against ${CORE_URL}..."
    # || true: nuclei exits non-zero when findings are present; we parse output ourselves.
    nuclei_output="$(nuclei -u "${CORE_URL}" \
        -tags jwt,misconfiguration \
        -severity medium,high,critical \
        -no-color -silent 2>&1)" || true
    echo "${nuclei_output}"
    if echo "${nuclei_output}" | grep -qiE "\[critical\]|\[high\]"; then
        echo "FAIL deploy: Nuclei found high/critical vulnerabilities"
    else
        echo "PASS deploy: Nuclei scan clean"
    fi
else
    echo "SKIP: nuclei not installed (brew install nuclei)"
fi

# ── jwt_tool (JWT attack surface) ─────────────────────────────────────────────
echo ""
if command -v jwt_tool &>/dev/null; then
    echo "==> Running jwt_tool against ${CORE_URL}/api/auth/login..."
    # Obtain a JWT from the preview environment
    login_resp="$(curl -sf "${CORE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null)" || true
    jwt_token="$(echo "${login_resp}" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
    if [[ -n "${jwt_token}" ]]; then
        # -X a: try all exploits (alg:none, HMAC confusion, kid injection, etc.)
        # -t: target endpoint to probe with forged tokens
        # -rh: request header template (*JWT* is replaced by jwt_tool with forged token)
        jwt_output="$(jwt_tool "${jwt_token}" \
            -t "${CORE_URL}/api/auth/me" \
            -rh "Authorization: Bearer *JWT*" \
            -X a 2>&1)" || true
        echo "${jwt_output}"
        if echo "${jwt_output}" | grep -qi "EXPLOIT"; then
            echo "FAIL deploy: jwt_tool found exploitable JWT vulnerability"
        else
            echo "PASS deploy: jwt_tool — no exploitable JWT vulnerabilities"
        fi
    else
        echo "SKIP jwt_tool: could not obtain JWT (login endpoint unreachable or credentials wrong)"
    fi
else
    echo "SKIP: jwt_tool not installed (pip install jwt_tool)"
fi

# ── IDOR test (cross-user resource access) ────────────────────────────────────
# Verifies that user2 cannot read or mutate user1's private placements.
# Requires both seed users: owner@thestacks.app and user@thestacks.app.
echo ""
echo "==> Running IDOR test (cross-user resource access)..."
idor_failed=0

u1_resp="$(curl -sf "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null)" || true
u1_token="$(echo "${u1_resp}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

u2_resp="$(curl -sf "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"user@thestacks.app","password":"dev-password-456"}' 2>/dev/null)" || true
u2_token="$(echo "${u2_resp}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${u1_token}" ]] || [[ -z "${u2_token}" ]]; then
    echo "SKIP: IDOR test — could not authenticate both seed users"
else
    # Get user1's library; extract a placement ID
    u1_library="$(curl -sf "${CORE_URL}/api/bookshelves/library" \
        -H "Authorization: Bearer ${u1_token}" 2>/dev/null)" || true
    placement_id="$(echo "${u1_library}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); p=d.get('placements',[]); print(p[0]['id'] if p else '')" \
        2>/dev/null || true)"

    if [[ -n "${placement_id}" ]]; then
        # Attempt to delete user1's placement as user2 — must be 403 or 404, not 200
        idor_status="$(curl -o /dev/null -s -w "%{http_code}" \
            -X DELETE "${CORE_URL}/api/placements/${placement_id}" \
            -H "Authorization: Bearer ${u2_token}")"
        if [[ "${idor_status}" == "200" ]]; then
            echo "FAIL deploy: IDOR — user2 deleted user1's placement ${placement_id} (HTTP 200)"
            idor_failed=1
        else
            echo "PASS deploy: IDOR — cross-user DELETE blocked (HTTP ${idor_status})"
        fi
    else
        echo "SKIP: IDOR placement test — user1 has no placements in library"
    fi

    if [[ $idor_failed -eq 0 ]]; then
        echo "PASS deploy: IDOR tests passed"
    else
        echo "FAIL deploy: IDOR tests found vulnerabilities"
    fi
fi

# ── Final result ──────────────────────────────────────────────────────────────
if [[ $e2e_failed -ne 0 ]]; then
    exit 1
fi

echo ""
echo "Deploy preview complete."
