#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

EXT=$(printf '%s' "${FILE_PATH##*.}" | tr '[:upper:]' '[:lower:]')

BASENAME=$(basename "$FILE_PATH")

FAIL=0
MESSAGES=()

run_check() {
  local label="$1"
  local fix_cmd="$2"
  shift 2
  local output
  output=$("$@" 2>&1)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    FAIL=1
    MESSAGES+=("HOOK FAIL: ${label}")
    MESSAGES+=("Run: ${fix_cmd}")
    MESSAGES+=("${output}")
    MESSAGES+=("")
  fi
}

if command -v gitleaks > /dev/null 2>&1; then
  case "$BASENAME" in
    .env|.env.local)
      : # SKIP: gitignored env file
      ;;
    *)
      _gitleaks_config=()
      if [[ -f "${REPO_ROOT}/.gitleaks.toml" ]]; then
        _gitleaks_config=(--config "${REPO_ROOT}/.gitleaks.toml")
      fi
      run_check \
        "gitleaks detect --no-git --source ${FILE_PATH}" \
        "Run: gitleaks detect --no-git --source ${FILE_PATH}" \
        gitleaks detect --no-git --source "$FILE_PATH" --log-level error "${_gitleaks_config[@]}"
      ;;
  esac
else
  : # SKIP: gitleaks not installed
fi

case "$BASENAME" in
  Dockerfile*)
    if command -v hadolint > /dev/null 2>&1; then
      run_check \
        "hadolint ${FILE_PATH}" \
        "Run: hadolint ${FILE_PATH}" \
        hadolint "$FILE_PATH"
    else
      : # SKIP: hadolint not installed
    fi
    ;;
esac

case "$EXT" in
  ex|exs)
    run_check \
      "mix format --check-formatted ${FILE_PATH}" \
      "cd ${REPO_ROOT}/apps/core && mix format ${FILE_PATH}" \
      bash -c "cd '${REPO_ROOT}/apps/core' && mix format --check-formatted '${FILE_PATH}'"

    ;;

  elm)
    if [[ -x "${REPO_ROOT}/frontend/node_modules/.bin/elm-format" ]]; then
      ELM_FMT="${REPO_ROOT}/frontend/node_modules/.bin/elm-format"
    elif command -v elm-format > /dev/null 2>&1; then
      ELM_FMT="elm-format"
    else
      ELM_FMT=""
    fi
    if [[ -n "$ELM_FMT" ]]; then
      run_check \
        "elm-format --validate ${FILE_PATH}" \
        "cd ${REPO_ROOT}/frontend && elm-format ${FILE_PATH}" \
        bash -c "'${ELM_FMT}' --validate '${FILE_PATH}'"
    fi
    ;;

  rs)
    run_check \
      "cargo fmt --check (apps/scraper)" \
      "cd ${REPO_ROOT}/apps/scraper && cargo fmt" \
      bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo fmt --check"

    if [[ $FAIL -eq 0 ]] && command -v cargo > /dev/null 2>&1; then
      run_check \
        "cargo clippy -- -D warnings (apps/scraper)" \
        "Run: cd ${REPO_ROOT}/apps/scraper && cargo clippy -- -D warnings" \
        bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo clippy -- -D warnings"
    fi
    ;;

  py)
    if [[ -f "${REPO_ROOT}/apps/vision/.venv/bin/ruff" ]]; then
      RUFF="${REPO_ROOT}/apps/vision/.venv/bin/ruff"
    elif command -v ruff > /dev/null 2>&1; then
      RUFF="ruff"
    else
      RUFF=""
    fi

    if [[ -n "$RUFF" ]]; then
      run_check \
        "ruff format --check ${FILE_PATH}" \
        "cd ${REPO_ROOT}/apps/vision && ruff format ${FILE_PATH}" \
        bash -c "'${RUFF}' format --check '${FILE_PATH}'"

      if [[ $FAIL -eq 0 ]]; then
        run_check \
          "ruff check ${FILE_PATH}" \
          "cd ${REPO_ROOT}/apps/vision && ruff check --fix ${FILE_PATH}" \
          bash -c "'${RUFF}' check '${FILE_PATH}'"
      fi
    fi

    if [[ $FAIL -eq 0 ]]; then
      case "$FILE_PATH" in
        */apps/vision/*)
          if [[ -f "${REPO_ROOT}/apps/vision/.venv/bin/mypy" ]]; then
            run_check \
              "mypy ${FILE_PATH} --ignore-missing-imports" \
              "Run: cd ${REPO_ROOT}/apps/vision && mypy ${FILE_PATH} --ignore-missing-imports" \
              bash -c "cd '${REPO_ROOT}/apps/vision' && .venv/bin/mypy '${FILE_PATH}' --ignore-missing-imports"
          elif command -v mypy > /dev/null 2>&1; then
            run_check \
              "mypy ${FILE_PATH} --ignore-missing-imports" \
              "Run: cd ${REPO_ROOT}/apps/vision && mypy ${FILE_PATH} --ignore-missing-imports" \
              bash -c "cd '${REPO_ROOT}/apps/vision' && mypy '${FILE_PATH}' --ignore-missing-imports"
          else
            : # SKIP: mypy not installed
          fi
          ;;
      esac
    fi
    ;;

  proto)
    run_check \
      "buf lint proto/" \
      "cd ${REPO_ROOT} && buf lint proto/" \
      bash -c "cd '${REPO_ROOT}' && buf lint proto/"
    ;;

  sql)
    if command -v sqlfluff > /dev/null 2>&1; then
      run_check \
        "sqlfluff lint ${FILE_PATH}" \
        "Run: sqlfluff lint ${FILE_PATH}" \
        sqlfluff lint "$FILE_PATH"
    else
      : # SKIP: sqlfluff not installed
    fi
    ;;

  *)
    ;;
esac

if [[ $FAIL -ne 0 ]]; then
  printf '%s\n' "${MESSAGES[@]}" >&2
  exit 2
fi

exit 0
