#!/usr/bin/env bash
set -euo pipefail

ISBNS=(
  "9780156001311"
  "9781282763074"
)

OL_FAILED=()
GB_WARN=()

fetch_with_code() {
  local url="$1"
  curl -sS -w '\n%{http_code}' --max-time 10 "${url}" 2>/dev/null || printf '\n000'
}

ol_fetch_with_retry() {
  local url="$1" attempt body
  for attempt in 1 2 3; do
    if body=$(curl -fsS --max-time 15 "${url}" 2>&1); then
      printf '%s' "${body}"
      return 0
    fi
    [[ "${attempt}" -lt 3 ]] && sleep 3
  done
  printf '%s' "${body}"
  return 1
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

check_open_library() {
  local isbn="$1"
  local url="https://openlibrary.org/api/books?bibkeys=ISBN:${isbn}&format=json&jscmd=data"
  local body
  if ! body=$(ol_fetch_with_retry "${url}"); then
    echo "FAIL preflight: Open Library does not resolve ${isbn} (curl error after 3 attempts)"
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
