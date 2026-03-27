#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:4000}"

# HMAC token matching the X-Internal-Token scheme used by the smoke endpoint.
# The endpoint verifies against scraper_hmac_secret (SCRAPER_HMAC_SECRET env var).
SECRET="${SCRAPER_HMAC_SECRET:-}"

if [[ -z "$SECRET" ]]; then
  echo "ERROR: SCRAPER_HMAC_SECRET is not set" >&2
  exit 1
fi

SMOKE_PATH="/api/internal/smoke/circuit_breakers"
TS=$(date +%s)
# openssl dgst output varies by platform:
#   macOS: "<hex>"             (no label)
#   Linux: "HMAC-SHA256(stdin)= <hex>"
# awk '{print $NF}' extracts the last field on both.
SIG=$(echo -n "${TS}.POST.${SMOKE_PATH}" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
TOKEN="${TS}.${SIG}"

echo "Running circuit breaker smoke test against $BASE_URL..."

RESPONSE=$(curl -sf -X POST \
  --max-time 120 \
  -H "Content-Type: application/json" \
  -H "X-Internal-Token: $TOKEN" \
  "$BASE_URL${SMOKE_PATH}")

echo "$RESPONSE" | python3 -m json.tool

RESULT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")

if [ "$RESULT" = "pass" ]; then
  echo "All circuit breakers passed"
  exit 0
else
  echo "Circuit breaker smoke test FAILED"
  exit 1
fi
