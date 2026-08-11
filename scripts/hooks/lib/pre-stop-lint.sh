#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")"

MIX_CMD="mix"
if [[ -z "${STACKS_DEV_SHELL:-}" ]]; then
  export PATH="/nix/var/nix/profiles/default/bin:${HOME}/.nix-profile/bin:${PATH}"
  if command -v nix >/dev/null 2>&1; then
    MIX_CMD="nix develop '${REPO_ROOT}' --command mix"
  fi
fi

INPUT=$(cat)

STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null || true)
UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED_FILES" "$STAGED_FILES" "$UNTRACKED_FILES" | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_CHANGED" ]]; then
  exit 0
fi

HAS_ELIXIR=0
HAS_ELM=0
HAS_RUST=0
HAS_PYTHON=0
HAS_PROTO=0
HAS_DOCKERFILE=0
HAS_NPM=0

while IFS= read -r f; do
  ext=$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')
  bname=$(basename "$f")
  case "$ext" in
    ex|exs) HAS_ELIXIR=1 ;;
    elm)    HAS_ELM=1    ;;
    rs)     HAS_RUST=1   ;;
    py)     HAS_PYTHON=1 ;;
    proto)  HAS_PROTO=1  ;;
  esac
  case "$bname" in
    Dockerfile*) HAS_DOCKERFILE=1 ;;
  esac
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

if [[ $HAS_ELIXIR -eq 1 ]]; then
  ELIXIR_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(ex|exs)$' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue
    run_check \
      "mix format --check-formatted ${ABS}" \
      "cd ${REPO_ROOT}/apps/core && mix format ${ABS}" \
      bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} format --check-formatted '${ABS}'"
  done <<< "$ELIXIR_FILES"

  if [[ $FAIL -eq 0 ]]; then
    run_check \
      "mix credo --strict (apps/core)" \
      "cd ${REPO_ROOT}/apps/core && mix credo --strict" \
      bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} credo --strict"
  fi

  if [[ $FAIL -eq 0 ]]; then
    run_check "mix sobelow (apps/core)" \
        "cd '${REPO_ROOT}/apps/core' && mix sobelow --exit" \
        bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} sobelow"
  fi

  if [[ $FAIL -eq 0 ]]; then
    if bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} help deps.audit" > /dev/null 2>&1; then
      run_check \
        "mix deps.audit (apps/core)" \
        "cd ${REPO_ROOT}/apps/core && mix deps.audit" \
        bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} deps.audit"
    else
      : # SKIP: mix deps.audit not available (mix_audit package not installed)
    fi
  fi
fi

if [[ $HAS_ELM -eq 1 ]]; then
  if [[ -x "${REPO_ROOT}/frontend/node_modules/.bin/elm-format" ]]; then
    ELM_FORMAT="${REPO_ROOT}/frontend/node_modules/.bin/elm-format"
  elif command -v elm-format > /dev/null 2>&1; then
    ELM_FORMAT="elm-format"
  else
    ELM_FORMAT=""
  fi

  if [[ -n "$ELM_FORMAT" ]]; then
    ELM_FILES=$(echo "$ALL_CHANGED" | grep -E '\.elm$' || true)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      ABS="${REPO_ROOT}/${f}"
      [[ -f "$ABS" ]] || continue
      run_check \
        "elm-format --validate ${ABS}" \
        "cd ${REPO_ROOT}/frontend && elm-format ${ABS}" \
        bash -c "'${ELM_FORMAT}' --validate '${ABS}'"
    done <<< "$ELM_FILES"
  fi
fi

if [[ $HAS_RUST -eq 1 ]]; then
  run_check \
    "cargo fmt --check (apps/scraper)" \
    "cd ${REPO_ROOT}/apps/scraper && cargo fmt" \
    bash -c "cd '${REPO_ROOT}/apps/scraper' && cargo fmt --check"

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

if [[ $HAS_PYTHON -eq 1 ]]; then
  if [[ -f "${REPO_ROOT}/apps/vision/.venv/bin/ruff" ]]; then
    RUFF="${REPO_ROOT}/apps/vision/.venv/bin/ruff"
  elif command -v ruff > /dev/null 2>&1; then
    RUFF="ruff"
  else
    RUFF=""
  fi

  if [[ -n "$RUFF" ]]; then
    PYTHON_FILES=$(echo "$ALL_CHANGED" | grep -E '\.py$' || true)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      ABS="${REPO_ROOT}/${f}"
      [[ -f "$ABS" ]] || continue
      run_check \
        "ruff format --check ${ABS}" \
        "cd ${REPO_ROOT}/apps/vision && ruff format ${ABS}" \
        bash -c "'${RUFF}' format --check '${ABS}'"
      run_check \
        "ruff check ${ABS}" \
        "cd ${REPO_ROOT}/apps/vision && ruff check --fix ${ABS}" \
        bash -c "'${RUFF}' check '${ABS}'"
    done <<< "$PYTHON_FILES"
  fi
fi

if [[ $HAS_PROTO -eq 1 ]]; then
  run_check \
    "buf lint proto/" \
    "cd ${REPO_ROOT} && buf lint proto/" \
    bash -c "cd '${REPO_ROOT}' && buf lint proto/"

  if [[ $FAIL -eq 0 && -f "${REPO_ROOT}/proto/persisted.exs" ]]; then
    run_check \
      "mix proto.sync --check" \
      "cd ${REPO_ROOT}/apps/core && mix proto.sync" \
      bash -c "cd '${REPO_ROOT}/apps/core' && ${MIX_CMD} proto.sync --check"
  fi
fi

if [[ $HAS_DOCKERFILE -eq 1 ]]; then
  DOCKERFILE_FILES=$(echo "$ALL_CHANGED" | grep -E '(^|/)Dockerfile' || true)
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ABS="${REPO_ROOT}/${f}"
    [[ -f "$ABS" ]] || continue

    if command -v checkov > /dev/null 2>&1; then
      run_check \
        "checkov -f ${ABS} --quiet" \
        "checkov -f ${ABS} --quiet" \
        checkov -f "$ABS" --quiet
    else
      : # SKIP: checkov not installed
    fi

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

if [[ $HAS_NPM -eq 1 ]]; then
  if command -v npm > /dev/null 2>&1; then
    NPM_FILES=$(echo "$ALL_CHANGED" | grep -E '(^|/)package(-lock)?\.json$' || true)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
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

if echo "$ALL_CHANGED" | grep -qE '^issues/.*\.md$'; then
  run_check \
    "issue-evidence (completion-bar §9/§10)" \
    "attach an evidence token to each checked DoD box; point every tracking #NNN at a real issues/NNN-*.md" \
    bash "${REPO_ROOT}/scripts/hooks/lib/check-issue-evidence.sh" "${REPO_ROOT}"
fi

if [[ $FAIL -ne 0 ]]; then
  printf '%s\n' "${SUMMARY[@]}" >&2
  printf '%s\n' "Fix the above failures before the session ends." >&2
  exit 2
fi

exit 0
