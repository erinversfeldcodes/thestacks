#!/usr/bin/env bash
# post-tool-lint.sh — PostToolUse hook for per-file standards enforcement.
#
# Receives a JSON event on stdin. Extracts the file path from tool_input,
# determines the file type, and runs the appropriate formatter/linter check.
# Exits 2 on failure so Claude Code feeds the error back to the agent.
#
# Called by .claude/settings.json PostToolUse hook on Write|Edit|NotebookEdit.

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")"

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# No file path in the tool input — nothing to check (e.g. MultiEdit root call).
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Derive extension (lowercase). Use tr for bash 3.x compat (macOS ships bash 3.2).
EXT=$(printf '%s' "${FILE_PATH##*.}" | tr '[:upper:]' '[:lower:]')

# Derive basename for checks that need it (e.g. Dockerfile detection).
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

# ---------------------------------------------------------------------------
# gitleaks — runs on EVERY file write regardless of extension.
# Must appear before the extension-specific dispatch block.
# ---------------------------------------------------------------------------
if command -v gitleaks > /dev/null 2>&1; then
  run_check \
    "gitleaks detect --no-git --source ${FILE_PATH}" \
    "Run: gitleaks detect --no-git --source ${FILE_PATH}" \
    gitleaks detect --no-git --source "$FILE_PATH" --log-level error
else
  : # SKIP: gitleaks not installed
fi

# ---------------------------------------------------------------------------
# Dockerfile detection — basename match, not extension.
# Runs before the extension case because Dockerfiles have no reliable extension.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Extension-specific checks.
# ---------------------------------------------------------------------------
case "$EXT" in
  ex|exs)
    # mix format --check-formatted accepts absolute paths.
    # Credo and Sobelow run in the Stop hook only (per-file credo exceeds 2s DoD limit).
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
    # cargo fmt --check does not accept individual file paths; it checks the crate.
    run_check \
      "cargo fmt --check (apps/scraper)" \
      "cd ${REPO_ROOT}/apps/scraper && cargo fmt" \
      bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo fmt --check"

    # cargo clippy — full crate, fast on warm toolchain.
    if [[ $FAIL -eq 0 ]] && command -v cargo > /dev/null 2>&1; then
      run_check \
        "cargo clippy -- -D warnings (apps/scraper)" \
        "Run: cd ${REPO_ROOT}/apps/scraper && cargo clippy -- -D warnings" \
        bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo clippy -- -D warnings"
    fi
    ;;

  py)
    # Prefer the vision venv ruff; fall back to system ruff; skip if absent.
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

    # mypy — only for files inside apps/vision/.
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
    # sqlfluff for plain SQL files.
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
    # Unsupported extension — nothing more to check beyond the pre-dispatch checks above.
    ;;
esac

if [[ $FAIL -ne 0 ]]; then
  printf '%s\n' "${MESSAGES[@]}" >&2
  exit 2
fi

exit 0
