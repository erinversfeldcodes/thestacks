#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:4000}"

SECRET="${SCRAPER_HMAC_SECRET:-}"

if [[ -z "$SECRET" ]]; then
  echo "ERROR: SCRAPER_HMAC_SECRET is not set" >&2
  exit 1
fi

SMOKE_PATH="/api/internal/smoke/circuit_breakers"
TS=$(date +%s)
SIG=$(echo -n "${TS}.POST.${SMOKE_PATH}" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
TOKEN="${TS}.${SIG}"

echo "Running circuit breaker smoke test against $BASE_URL..."

# ⛔ THE PROOF A BROWSER WOULD HAVE. This route is on the `:api` pipeline, so the
# double-submit CSRF check applies to it like any other state-changing route: the
# readable `stacks_csrf` cookie echoed in `X-CSRF-Token`. A page fetch is how a
# browser is issued that cookie, and this script has to do it by hand.
#
# ⚖️ AN EXEMPTION WAS THE OTHER OPTION AND WAS DECLINED. This route carries an
# HMAC token and no cookie, so it has no ambient authority to borrow — the same
# property that exempts the `partner_auth` routes, and on principle it would
# qualify. Declined because the exemption is the expensive half: it would widen
# the carve-out set, change the counts `scripts/check-csrf-scope.sh` asserts and
# the "83 of 91" figure spelled in two files, and leave a future reader to
# re-derive why this one route is different. One extra GET in a smoke script is
# cheaper than a policy carve-out, and it cannot weaken anything.
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

# ⛔ THE STATUS IS KEPT. This was `curl -s -o /dev/null … || true`, which threw
# away both the status and the body and then reported the one consequence it had
# NOT observed: "this POST would be refused with 403 csrf_check_failed". The
# `/` route is on the `:spa` pipeline, which carries no rate limiter and no auth,
# and `Plugs.CsrfCookie` issues the cookie unconditionally when the request
# arrives without one — so a 200 ALWAYS carries it, and a missing cookie means
# the fetch did not succeed at all. The old message named a CSRF cause for what
# is really "the stack did not answer", and a gate run was spent working that
# out from a log that no longer had the answer in it.
PAGE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
  --cookie-jar "$JAR" --max-time 15 "$BASE_URL/")" || PAGE_STATUS="000"
PROOF="$(awk '$6 == "stacks_csrf" { print $7 }' "$JAR" | tail -1)"
if [ -z "$PROOF" ]; then
  echo "FAIL smoke: GET $BASE_URL/ returned HTTP $PAGE_STATUS and issued no"
  echo "     stacks_csrf cookie, so the POST below has no proof to send."
  if [ "$PAGE_STATUS" = "200" ]; then
    echo "     ⛔ A 200 with no cookie is a CSRF defect: the :spa pipeline's"
    echo "     CsrfCookie plug issues one on every page response that arrives"
    echo "     without it. Look at the plug and the pipeline, not at this script."
  else
    echo "     ⚠️ This is the stack failing to serve its own page, NOT a CSRF"
    echo "     fault — 000 means curl never got a response (DNS, TLS, refused,"
    echo "     or the 15s timeout); a 5xx means it answered and failed. A cold"
    echo "     preview machine 502s on the first hit, so warm /api/health and"
    echo "     re-run before treating this as a defect."
  fi
  exit 1
fi

RESPONSE=$(curl -sf -X POST \
  --max-time 120 \
  -b "$JAR" \
  -H "X-CSRF-Token: $PROOF" \
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
