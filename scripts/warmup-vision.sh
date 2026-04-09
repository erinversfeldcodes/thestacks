#!/usr/bin/env bash
# scripts/warmup-vision.sh — warm the vision pipeline before E2E tests.
#
# Uploads 4 cover-photo images as the seed user and streams their SSE pipelines
# in parallel. This triggers a Modal cold-start (if needed) before the E2E suite
# runs, so the first real upload test doesn't pay the cold-start penalty.
#
# Usage:
#   scripts/warmup-vision.sh <core_url> <core_app>
#
# Exit codes:
#   0 — warmup ran (pipelines may have timed out — that's a warning, not fatal)
#   1 — could not authenticate or all uploads failed (app is broken)

set -euo pipefail

CORE_URL="${1:?core_url required}"
CORE_APP="${2:?core_app required}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ""
echo "==> Vision pipeline warmup against ${CORE_URL}/api/upload..."

smoke_login="$(curl -sf "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null || true)"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${smoke_token}" ]]; then
    echo "WARN warmup: skipped — could not authenticate as seed user"
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
    echo "FAIL warmup: all uploads failed — app may be broken"
    exit 1
fi

# Stream each pipeline's SSE endpoint in parallel. Blocks until resolved/rejected
# or the per-stream timeout fires. The stream endpoint returns immediately when
# the job is already terminal, so no polling loop is needed.
echo "    Streaming ${#warmup_ids[@]} pipelines in parallel (max 2 min each)..."
warmup_dir="$(mktemp -d)"
stream_pids=()
for img_id in "${warmup_ids[@]}"; do
    (
        stream_resp="$(curl -sf --max-time 480 \
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
