#!/usr/bin/env bash
#
# preflight-resolver-health.sh — gate the deployed E2E run on the external
# ISBN resolvers that the upload pipeline depends on at enrichment time.
#
# Why this exists:
#   The upload Playwright suite (e2e/tests/upload.spec.ts) polls for up to
#   60 s expecting EnrichBookJob to replace a placeholder "ISBN 978..."
#   title with real metadata from Open Library / Google Books. If OL is
#   down or rate-limiting when the preview deploy happens, that poll burns
#   ~6 minutes only to fail on a known external cause. Running this script
#   immediately before the E2E step makes the failure fast (~5–10 s) and
#   gives the operator a curl command they can rerun manually.
#
# Sources:
#   - Open Library  → hard required. Any miss FAILS the script.
#   - Google Books  → advisory only. Misses are WARN but do not fail.
#
# Two layers of checks:
#   1. Endpoint health — the exact endpoints ISBNResolver.search_by_title/4
#      hits (OL /search.json, GB /volumes). Catches whole-upstream outages
#      and, for Google Books, quota exhaustion: GB returns 429/403 with
#      quota_limit_value: "0" when the daily quota is dead (observed on
#      this branch), which silently degrades the resolver to OL-only.
#      GB being down/quota-dead is a WARN — it is the fallback source and
#      E2E can pass without it — but the operator should know the run's
#      resolution quality is degraded.
#   2. ISBN resolution — the specific ISBNs the E2E upload suite depends on.
#
# Exit codes:
#   0  Open Library healthy (search endpoint up + every ISBN resolved);
#      Google Books issues are WARN-only
#   1  Open Library search endpoint down or one or more ISBNs failed to
#      resolve from Open Library
#
set -euo pipefail

# ISBNs the real-pipeline tests in e2e/tests/upload.spec.ts depend on the
# external resolver chain to enrich. Reconciliation:
#
#   9780156001311  The Name of the Rose
#                  → barcode_isbn_clean.jpg (lines 11, 165 — barcode OCR
#                    fast path: pipeline emits ISBN 978... placeholder
#                    title then EnrichBookJob polls OL within 60 s).
#
#   9781282763074  Born Again Bodies
#                  → screenshot_mildly_obscured.jpg (line 420 — vision
#                    pipeline OCRs cover, resolves this ISBN, enriches
#                    via OL).
#
# Other real-pipeline tests in upload.spec.ts (Flyboys, Train to Crystal
# City, screenshot_mixed_text 5-book identification, manual ISBN entry
# for The Dispossessed) do NOT hardcode an ISBN literal in the test, and
# the seeded Dispossessed lookups hit the internal DB rather than OL.
# Adding ISBNs that no test depends on adds noise without value.
ISBNS=(
  "9780156001311"
  "9781282763074"
)

OL_FAILED=()
GB_WARN=()

# ── Layer 1: endpoint health ─────────────────────────────────────────────────
# Query terms are arbitrary well-known books — these checks assert the
# ENDPOINTS answer sanely, not that a specific record exists.

# curl helper: prints the response body followed by a final line holding
# the HTTP status code. "000" on transport-level failure.
fetch_with_code() {
  local url="$1"
  curl -sS -w '\n%{http_code}' --max-time 10 "${url}" 2>/dev/null || printf '\n000'
}

check_open_library_search_endpoint() {
  local url="https://openlibrary.org/search.json?title=the+great+gatsby&fields=key,title,isbn&limit=1"
  local response body http_code doc_count
  response="$(fetch_with_code "${url}")"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "${http_code}" != "200" ]]; then
    echo "FAIL preflight: Open Library search endpoint returned HTTP ${http_code} (expected 200)"
    echo "  Rerun manually: curl -sS \"${url}\""
    OL_FAILED+=("search-endpoint")
    return 1
  fi

  doc_count=$(printf '%s' "${body}" | jq -r '.docs | length' 2>/dev/null || echo 0)
  if [[ "${doc_count}" -lt 1 ]]; then
    echo "FAIL preflight: Open Library search endpoint returned 200 but no docs — search index degraded"
    echo "  Rerun manually: curl -sS \"${url}\""
    OL_FAILED+=("search-endpoint")
    return 1
  fi

  echo "PASS Open Library  search endpoint  ->  HTTP 200, ${doc_count} doc(s)"
  return 0
}

check_google_books_volumes_endpoint() {
  local url="https://www.googleapis.com/books/v1/volumes?q=intitle:gatsby&maxResults=1"
  local response body http_code item_count reason
  response="$(fetch_with_code "${url}")"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  case "${http_code}" in
    200)
      item_count=$(printf '%s' "${body}" | jq -r '.items | length' 2>/dev/null || echo 0)
      if [[ "${item_count}" -lt 1 ]]; then
        echo "WARN preflight: Google Books volumes endpoint returned 200 but no items (advisory only)"
        GB_WARN+=("volumes-endpoint")
      else
        echo "PASS Google Books  volumes endpoint  ->  HTTP 200, ${item_count} item(s)"
      fi
      ;;
    429|403)
      # GB signals quota exhaustion as 429 (rateLimitExceeded) or 403
      # (quotaExceeded/dailyLimitExceeded). Say so explicitly — this is
      # the "quota-dead 503s" failure mode that poisons E2E tuning runs.
      reason=$(printf '%s' "${body}" | jq -r '.error.errors[0].reason // .error.status // "unknown"' 2>/dev/null || echo "unknown")
      echo "WARN preflight: Google Books QUOTA EXHAUSTED — HTTP ${http_code} (reason: ${reason})."
      echo "  The resolver will run OL-only this cycle: GB fallback + subtitle evidence unavailable."
      echo "  Advisory only — E2E can pass without GB, but resolution quality is degraded."
      GB_WARN+=("quota-exhausted")
      ;;
    *)
      echo "WARN preflight: Google Books volumes endpoint returned HTTP ${http_code} (advisory only)"
      echo "  Rerun manually: curl -sS \"${url}\""
      GB_WARN+=("volumes-endpoint")
      ;;
  esac
  return 0
}

echo "Preflight: endpoint health (OL search required, GB volumes advisory)..."
echo
check_open_library_search_endpoint || true
check_google_books_volumes_endpoint
echo

# ── Layer 2: per-ISBN resolution ─────────────────────────────────────────────

check_open_library() {
  local isbn="$1"
  local url="https://openlibrary.org/api/books?bibkeys=ISBN:${isbn}&format=json&jscmd=data"
  local body
  if ! body=$(curl -fsS --max-time 10 "${url}" 2>&1); then
    echo "FAIL preflight: Open Library does not resolve ${isbn} (curl error)"
    echo "  curl -sS \"${url}\" returned: ${body}"
    OL_FAILED+=("${isbn}")
    return 1
  fi

  local title
  title=$(printf '%s' "${body}" | jq -r --arg key "ISBN:${isbn}" '.[$key].title // empty')

  if [[ -z "${title}" || "${title}" == "null" ]]; then
    echo "FAIL preflight: Open Library does not resolve ${isbn} (response did not include a title field)"
    echo "  curl -sS \"${url}\" returned: ${body}"
    OL_FAILED+=("${isbn}")
    return 1
  fi

  echo "PASS Open Library  ${isbn}  ->  ${title}"
  return 0
}

check_google_books() {
  local isbn="$1"
  local url="https://www.googleapis.com/books/v1/volumes?q=isbn:${isbn}"
  local body
  if ! body=$(curl -fsS --max-time 10 "${url}" 2>&1); then
    echo "WARN preflight: Google Books did not resolve ${isbn} (curl error — advisory only)"
    GB_WARN+=("${isbn}")
    return 0
  fi

  local title
  title=$(printf '%s' "${body}" | jq -r '.items[0].volumeInfo.title // empty')

  if [[ -z "${title}" || "${title}" == "null" ]]; then
    echo "WARN preflight: Google Books did not resolve ${isbn} (no title in response — advisory only)"
    GB_WARN+=("${isbn}")
    return 0
  fi

  echo "PASS Google Books  ${isbn}  ->  ${title}"
  return 0
}

echo "Preflight: checking ${#ISBNS[@]} ISBN(s) against Open Library (required) + Google Books (advisory)..."
echo

for isbn in "${ISBNS[@]}"; do
  check_open_library "${isbn}" || true
  check_google_books "${isbn}" || true
done

echo
if (( ${#OL_FAILED[@]} > 0 )); then
  echo "Summary: FAIL — ${#OL_FAILED[@]} Open Library check(s) failed: ${OL_FAILED[*]}"
  if (( ${#GB_WARN[@]} > 0 )); then
    echo "Summary: Google Books also degraded: ${GB_WARN[*]} (advisory)"
  fi
  echo "Action: rerun the curl line above manually to confirm. If OL is down, either retry the deploy or escalate."
  exit 1
fi

if (( ${#GB_WARN[@]} > 0 )); then
  echo "Summary: PASS (with warnings) — Open Library healthy. Google Books degraded: ${GB_WARN[*]} (advisory, not blocking)."
else
  echo "Summary: PASS — Open Library and Google Books healthy; all ${#ISBNS[@]} ISBN(s) resolved."
fi
exit 0
