#!/usr/bin/env bash
# scripts/deploy-preview.sh — deploy a preview stack and warm the vision pipeline.
#
# Does NOT run tests or clean up — that is ci.sh's responsibility.
# Use this script directly for manual inspection of a deployed preview stack.
# To deploy WITH tests and cleanup, run scripts/ci.sh (which calls this script).
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

BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
SANITISED="$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '/_' '-' | cut -c1-30)"
SANITISED="${SANITISED%-}"
CORE_APP="stacks-core-pr-${SANITISED}"
CORE_URL="https://${CORE_APP}.fly.dev"

# ── Deploy ────────────────────────────────────────────────────────────────────
bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}

# ── Vision pipeline warmup ────────────────────────────────────────────────────
# Pre-warms the Modal container so E2E tests don't pay the cold-start penalty.
# All curls use -4 because GitHub runners lack IPv6 connectivity to Fly's AAAA
# addresses (ENETUNREACH). Pipeline-stream timeouts are non-fatal, but auth
# failure IS fatal — we can't deploy a stack we can't talk to.
echo ""
echo "==> Vision pipeline warmup against ${CORE_URL}/api/upload..."
login_body_file="$(mktemp)"
smoke_login_code="$(curl -4 -s -o "${login_body_file}" -w "%{http_code}" \
    "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' || true)"
smoke_login="$(cat "${login_body_file}" 2>/dev/null || true)"
rm -f "${login_body_file}"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${smoke_token}" ]]; then
    echo "FAIL warmup: could not authenticate as seed user (HTTP ${smoke_login_code})"
    echo "    Response body: ${smoke_login}"
    exit 1
fi

# One barcode image is enough to wake the GPU (triggers classify → GPU, then
# extract → pyzbar short-circuit, then a single ISBN resolve call).
# Using screenshot images here burns the Google Books rate limit before E2E.
warmup_images=(
    "${REPO_ROOT}/images/not_a_book.jpg"
)
warmup_ids=()
for img in "${warmup_images[@]}"; do
    img_name="$(basename "$img")"
    body_file="$(mktemp)"
    http_code="$(curl -4 -s -o "${body_file}" -w "%{http_code}" \
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
    echo "FAIL warmup: all uploads failed — app may be broken"
    exit 1
fi

echo "    Streaming ${#warmup_ids[@]} warmup pipelines in parallel (max 2 min each)..."
warmup_dir="$(mktemp -d)"
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
            > "${warmup_dir}/${img_id}" 2>/dev/null \
            || echo "timeout" > "${warmup_dir}/${img_id}"
    ) &
    stream_pids+=("$!")
done
for pid in "${stream_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

all_done=1
for img_id in "${warmup_ids[@]}"; do
    img_status="$(cat "${warmup_dir}/${img_id}" 2>/dev/null || echo "timeout")"
    echo "    ${img_id}: ${img_status}"
    if [[ "${img_status}" != "resolved" && "${img_status}" != "rejected" ]]; then
        all_done=0
    fi
done
rm -rf "${warmup_dir}"

if [[ $all_done -eq 1 ]]; then
    echo "PASS warmup: all pipelines resolved/rejected"
else
    echo "WARN warmup: one or more pipelines timed out (Modal may still be cold-starting)"
    echo "--- Core app logs (last 60 lines) ---"
    (fly logs --app "${CORE_APP}" 2>&1 &
     FLY_LOG_PID=$!
     sleep 10
     kill $FLY_LOG_PID 2>/dev/null
     wait $FLY_LOG_PID 2>/dev/null) | tail -60 || true
    echo "--- End core logs ---"
fi
