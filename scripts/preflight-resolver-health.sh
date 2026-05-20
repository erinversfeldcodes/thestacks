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
# Exit codes:
#   0  every ISBN resolved a title from Open Library
#   1  one or more ISBNs failed to resolve from Open Library
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
  echo "Summary: FAIL — ${#OL_FAILED[@]}/${#ISBNS[@]} ISBN(s) did not resolve via Open Library: ${OL_FAILED[*]}"
  if (( ${#GB_WARN[@]} > 0 )); then
    echo "Summary: Google Books also missed: ${GB_WARN[*]} (advisory)"
  fi
  echo "Action: rerun the curl line above manually to confirm. If OL is down, either retry the deploy or escalate."
  exit 1
fi

if (( ${#GB_WARN[@]} > 0 )); then
  echo "Summary: PASS — Open Library resolved all ${#ISBNS[@]} ISBN(s). Google Books missed ${#GB_WARN[@]} (advisory, not blocking)."
else
  echo "Summary: PASS — Open Library and Google Books resolved all ${#ISBNS[@]} ISBN(s)."
fi
exit 0
