#!/usr/bin/env bash
# pre-stop-lint.sh — Stop hook: pre-session-end lint gate.
#
# Receives a JSON event on stdin. Detects which file types were changed
# (staged + unstaged) via git diff, then runs per-language lint only for
# changed file types. Exits 2 with a summary if any check fails so Claude
# Code feeds the failure back to the agent before the session ends.
#
# Registered as a Stop hook in .claude/settings.json.
# Called automatically when Claude Code is about to stop responding.

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")"

INPUT=$(cat)

# Guard: if this hook is already running due to a previous stop-hook block,
# do not re-run to prevent infinite loops. The agent should have fixed things.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# Collect changed files (staged + unstaged + untracked, relative paths).
CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null || true)
UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED_FILES" "$STAGED_FILES" "$UNTRACKED_FILES" | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_CHANGED" ]]; then
  # No changed files — nothing to lint.
  exit 0
fi

# Detect which language families have changes.
HAS_ELIXIR=0
HAS_ELM=0
HAS_RUST=0
HAS_PYTHON=0
HAS_PROTO=0
HAS_DOCKERFILE=0
HAS_NPM=0

while IFS= read -r f; do
  # Use tr for bash 3.x compat (macOS ships bash 3.2).
  ext=$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')
  bname=$(basename "$f")
  case "$ext" in
    ex|exs) HAS_ELIXIR=1 ;;
    elm)    HAS_ELM=1    ;;
    rs)     HAS_RUST=1   ;;
    py)     HAS_PYTHON=1 ;;
    proto)  HAS_PROTO=1  ;;
  esac
  # Dockerfile detection via basename (no reliable extension).
  case "$bname" in
    Dockerfile*) HAS_DOCKERFILE=1 ;;
  esac
  # npm audit: package.json or package-lock.json changes.
  case "$bname" in
    package.json|package-lock.json) HAS_NPM=1 ;;
  esac
done <<< "$ALL_CHANGED"

FAIL=0
SUMMARY=()

run_check() {
  local label="$1"
  local fix_cmd="$2"
  shift 2
  local output
  output=$("$@" 2>&1)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    FAIL=1
    SUMMARY+=("HOOK FAIL: ${label}")
    SUMMARY+=("Run: ${fix_cmd}")
    SUMMARY+=("${output}")
    SUMMARY+=("")
  fi
}

# --- Elixir ---
if [[ $HAS_ELIXIR -eq 1 ]]; then
  # Check all changed Elixir files for format violations.
  ELIXIR_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(ex|exs)$' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue
    run_check \
      "mix format --check-formatted ${ABS}" \
      "cd ${REPO_ROOT}/apps/core && mix format ${ABS}" \
      bash -c "cd '${REPO_ROOT}/apps/core' && mix format --check-formatted '${ABS}'"
  done <<< "$ELIXIR_FILES"

  # Run credo across apps/core for any Elixir change.
  if [[ $FAIL -eq 0 ]]; then
    run_check \
      "mix credo --strict (apps/core)" \
      "cd ${REPO_ROOT}/apps/core && mix credo --strict" \
      bash -c "cd '${REPO_ROOT}/apps/core' && mix credo --strict"
  fi

  # Run sobelow security scan across apps/core for any Elixir change.
  if [[ $FAIL -eq 0 ]]; then
    run_check "mix sobelow (apps/core)" \
        "cd '${REPO_ROOT}/apps/core' && mix sobelow --exit" \
        bash -c "cd '${REPO_ROOT}/apps/core' && mix sobelow"
  fi

  # Run deps.audit for any Elixir change — skip gracefully if task not available.
  if [[ $FAIL -eq 0 ]]; then
    if bash -c "cd '${REPO_ROOT}/apps/core' && mix help deps.audit" > /dev/null 2>&1; then
      run_check \
        "mix deps.audit (apps/core)" \
        "cd ${REPO_ROOT}/apps/core && mix deps.audit" \
        bash -c "cd '${REPO_ROOT}/apps/core' && mix deps.audit"
    else
      : # SKIP: mix deps.audit not available (mix_audit package not installed)
    fi
  fi
fi

# --- Elm ---
if [[ $HAS_ELM -eq 1 ]]; then
  ELM_FILES=$(echo "$ALL_CHANGED" | grep -E '\.elm$' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue
    run_check \
      "elm-format --validate ${ABS}" \
      "cd ${REPO_ROOT}/frontend && elm-format ${ABS}" \
      bash -c "cd '${REPO_ROOT}/frontend' && elm-format --validate '${ABS}'"
  done <<< "$ELM_FILES"
fi

# --- Rust ---
if [[ $HAS_RUST -eq 1 ]]; then
  run_check \
    "cargo fmt --check (apps/scraper)" \
    "cd ${REPO_ROOT}/apps/scraper && cargo fmt" \
    bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo fmt --check"

  # cargo audit — skip gracefully if cargo-audit subcommand not installed.
  if [[ $FAIL -eq 0 ]]; then
    if bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo audit --version" > /dev/null 2>&1; then
      run_check \
        "cargo audit (apps/scraper)" \
        "cd ${REPO_ROOT}/apps/scraper && cargo audit" \
        bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo audit"
    else
      : # SKIP: cargo-audit not installed
    fi
  fi
fi

# --- Python ---
if [[ $HAS_PYTHON -eq 1 ]]; then
  PYTHON_FILES=$(echo "$ALL_CHANGED" | grep -E '\.py$' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue
    run_check \
      "ruff format --check ${ABS}" \
      "cd ${REPO_ROOT}/apps/vision && ruff format ${ABS}" \
      bash -c "cd '${REPO_ROOT}/apps/vision' && ruff format --check '${ABS}'"
    run_check \
      "ruff check ${ABS}" \
      "cd ${REPO_ROOT}/apps/vision && ruff check --fix ${ABS}" \
      bash -c "cd '${REPO_ROOT}/apps/vision' && ruff check '${ABS}'"
  done <<< "$PYTHON_FILES"
fi

# --- Protobuf ---
if [[ $HAS_PROTO -eq 1 ]]; then
  run_check \
    "buf lint proto/" \
    "cd ${REPO_ROOT} && buf lint proto/" \
    bash -c "cd '${REPO_ROOT}' && buf lint proto/"
fi

# --- Dockerfile ---
if [[ $HAS_DOCKERFILE -eq 1 ]]; then
  DOCKERFILE_FILES=$(echo "$ALL_CHANGED" | grep -E '(^|/)Dockerfile' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue

    # checkov IaC scan — skip gracefully if checkov not installed.
    if command -v checkov > /dev/null 2>&1; then
      run_check \
        "checkov -f ${ABS} --quiet" \
        "checkov -f ${ABS} --quiet" \
        checkov -f "$ABS" --quiet
    else
      : # SKIP: checkov not installed
    fi

    # hadolint — skip gracefully if hadolint not installed.
    if command -v hadolint > /dev/null 2>&1; then
      run_check \
        "hadolint ${ABS}" \
        "hadolint ${ABS}" \
        hadolint "$ABS"
    else
      : # SKIP: hadolint not installed
    fi
  done <<< "$DOCKERFILE_FILES"
fi

# --- NPM ---
if [[ $HAS_NPM -eq 1 ]]; then
  if command -v npm > /dev/null 2>&1; then
    NPM_FILES=$(echo "$ALL_CHANGED" | grep -E '(^|/)package(-lock)?\.json$' || true)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      # Determine the directory containing the package.json.
      NPM_DIR="${REPO_ROOT}/$(dirname "$f")"
      [[ -d "$NPM_DIR" ]] || continue
      run_check \
        "npm audit --audit-level=high (${NPM_DIR})" \
        "cd ${NPM_DIR} && npm audit --audit-level=high" \
        bash -c "cd '${NPM_DIR}' && npm audit --audit-level=high"
    done <<< "$NPM_FILES"
  else
    : # SKIP: npm not installed
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  printf '%s\n' "${SUMMARY[@]}" >&2
  printf '%s\n' "Fix the above failures before the session ends." >&2
  # Exit 2: Stop hook blocks Claude from stopping and feeds stderr back as error.
  exit 2
fi

exit 0
