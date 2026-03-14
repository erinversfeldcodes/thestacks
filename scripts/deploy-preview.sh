#!/usr/bin/env bash
# scripts/deploy-preview.sh — deploy a preview stack, run tests, then clean up.
#
# This script orchestrates the full preview lifecycle:
#   1. Deploy stack (via deploy-stack.sh)
#   2. Warmup vision pipeline
#   3. Run Playwright E2E tests
#   4. Run security scans (ZAP, Nuclei, jwt_tool, IDOR)
#   5. Clean up all resources
#
# The cleanup trap ensures resources are destroyed even on failure.
# To deploy WITHOUT cleanup (for manual inspection), use deploy-stack.sh directly.
#
# Usage:
#   scripts/deploy-preview.sh
#   scripts/deploy-preview.sh --branch my-feature-branch

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ── Parse args ────────────────────────────────────────────────────────────────
BRANCH_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH_ARG="--branch $2"; shift 2 ;;
        *) shift ;;
    esac
done

# Derive names for cleanup (same logic as deploy-stack.sh)
BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"
CORE_APP="stacks-core-pr-${SANITISED}"
CORE_URL="https://${CORE_APP}.fly.dev"
NEON_BRANCH_NAME="preview/${SANITISED}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" --branch "${BRANCH}" --neon-branch-name "${NEON_BRANCH_NAME}"
}
trap cleanup EXIT

# ── Deploy ────────────────────────────────────────────────────────────────────
bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}

e2e_failed=0

# ── Upload smoke test + warmup ────────────────────────────────────────────────
echo ""
echo "==> Upload smoke test / warmup against ${CORE_URL}/api/upload..."
smoke_login="$(curl -sf "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null || true)"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
if [[ -n "${smoke_token}" ]]; then
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
        echo "    Polling until all ${#warmup_ids[@]} warmup pipelines complete (max 6 min)..."
        warmup_deadline=$(( $(date +%s) + 360 ))
        warmup_done_ids=""
        all_done=0
        while [[ $(date +%s) -lt $warmup_deadline ]]; do
            all_done=1
            for img_id in "${warmup_ids[@]}"; do
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
        done_count=$(echo "${warmup_done_ids}" | wc -w | tr -d ' ')
        if [[ $all_done -eq 1 ]]; then
            echo "PASS deploy: warmup passed (all pipelines resolved/rejected)"
        else
            remaining=$(( ${#warmup_ids[@]} - done_count ))
            echo "FAIL deploy: warmup timed out — ${remaining}/${#warmup_ids[@]} pipeline(s) still pending"
            echo "--- Core app logs (last 60 lines) ---"
            (fly logs --app "${CORE_APP}" 2>&1 &
             FLY_LOG_PID=$!
             sleep 10
             kill $FLY_LOG_PID 2>/dev/null
             wait $FLY_LOG_PID 2>/dev/null) | tail -60 || true
            echo "--- End core logs ---"
            e2e_failed=1
        fi
    fi
else
    echo "WARN deploy: warmup skipped — could not authenticate"
fi

# ── Playwright E2E ────────────────────────────────────────────────────────────
echo ""
echo "==> Running Playwright E2E against ${CORE_URL}..."
(while true; do
    curl -sf --max-time 5 "${CORE_URL}/api/health" >/dev/null 2>&1 || true
    sleep 10
done) &
KEEP_ALIVE_PID=$!

FLY_LOGS_FILE="$(mktemp)"
(fly logs --app "${CORE_APP}" 2>&1) > "${FLY_LOGS_FILE}" &
FLY_LOGS_PID=$!

E2E_SERVICES=none BASE_URL="${CORE_URL}" bash "${REPO_ROOT}/scripts/test-e2e.sh" 2>&1 || e2e_failed=1

kill "${KEEP_ALIVE_PID}" 2>/dev/null || true
sleep 3
kill "${FLY_LOGS_PID}" 2>/dev/null || true
wait "${FLY_LOGS_PID}" 2>/dev/null || true

echo ""
echo "--- Core app logs during E2E (last 200 lines) ---"
tail -200 "${FLY_LOGS_FILE}" || true
echo "--- End core logs ---"
rm -f "${FLY_LOGS_FILE}"

# ── Post-E2E DB diagnostic ───────────────────────────────────────────────────
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

# ── OWASP ZAP ────────────────────────────────────────────────────────────────
echo ""
if command -v docker &>/dev/null; then
    echo "==> Running OWASP ZAP baseline scan against ${CORE_URL}..."
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

# ── Nuclei ────────────────────────────────────────────────────────────────────
echo ""
if command -v nuclei &>/dev/null; then
    echo "==> Running Nuclei (jwt + misconfig) against ${CORE_URL}..."
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

# ── jwt_tool ─────────────────────────────────────────────────────────────────
echo ""
if command -v jwt_tool &>/dev/null; then
    echo "==> Running jwt_tool against ${CORE_URL}/api/auth/login..."
    login_resp="$(curl -sf "${CORE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null)" || true
    jwt_token="$(echo "${login_resp}" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
    if [[ -n "${jwt_token}" ]]; then
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
        echo "SKIP jwt_tool: could not obtain JWT"
    fi
else
    echo "SKIP: jwt_tool not installed (run setup.sh to install)"
fi

# ── IDOR test ─────────────────────────────────────────────────────────────────
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
    u1_library="$(curl -sf "${CORE_URL}/api/bookshelves/library" \
        -H "Authorization: Bearer ${u1_token}" 2>/dev/null)" || true
    placement_id="$(echo "${u1_library}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); p=d.get('placements',[]); print(p[0]['id'] if p else '')" \
        2>/dev/null || true)"

    if [[ -n "${placement_id}" ]]; then
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
