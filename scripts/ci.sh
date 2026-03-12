#!/usr/bin/env bash
# scripts/ci.sh — local equivalent of .github/workflows/ci.yml.disabled
#
# Runs every check the CI pipeline runs, in the same order, using the same
# scripts the CI jobs call. The CI workflow runs these in parallel across
# isolated runners; here they run sequentially in your local environment.
#
# Prerequisites (must be installed and on PATH):
#   Elixir/Mix, Node/npm, Rust/Cargo, Python/pip, buf, dbt, sqlfluff,
#   gitleaks, semgrep, hadolint, checkov, trivy
#
# Postgres must be running locally for test-elixir and test-dbt.
# By default those scripts connect using your local MIX_ENV credentials.
# Set DATABASE_URL or the DBT_* env vars to override.
#
# Usage:
#   scripts/ci.sh              # run everything
#   scripts/ci.sh elixir       # run only the elixir group
#   scripts/ci.sh elm rust     # run only elm and rust groups

# Do NOT use set -e here. ci.sh deliberately runs every group even when earlier
# ones fail, accumulating failures in the FAILED array for a final summary.
# Individual scripts use set -euo pipefail internally.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Load local .env for dev secrets (FLY_API_TOKEN, NEON_*, etc.) when outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

# Colours for section banners
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "${GREEN}${BOLD}PASS${RESET} $1"; }
fail() { echo -e "${RED}${BOLD}FAIL${RESET} $1"; }

run_group() {
    local name="$1"; shift
    echo -e "\n${CYAN}${BOLD}=== $name ===${RESET}"
    if "$@"; then
        pass "$name"
    else
        fail "$name"
        return 1
    fi
}

# Determine which groups to run (default: all).
# NOTE: Do NOT use GROUPS — it is a bash built-in read-only variable (user GIDs).
if [[ $# -eq 0 ]]; then
    # e2e is excluded from the default run — it requires all services to be live,
    # depends on vision model timing, and is covered by deploy-preview.sh smoke tests.
    # Run explicitly with: scripts/ci.sh e2e
    CI_GROUPS=(elixir elm rust python proto dbt security squawk licenses)
else
    CI_GROUPS=("$@")
fi

has_group() {
    local target="$1"
    for g in "${CI_GROUPS[@]}"; do [[ "$g" == "$target" ]] && return 0; done
    return 1
}

FAILED=()

# ── Elixir ────────────────────────────────────────────────────────────────────
if has_group elixir; then
    echo -e "\n${CYAN}${BOLD}=== elixir: deps ===${RESET}"
    mix deps.get

    if ! run_group "elixir: lint" bash scripts/lint-elixir.sh; then FAILED+=(elixir-lint); fi
    if ! run_group "elixir: test" bash scripts/test-elixir.sh; then FAILED+=(elixir-test); fi
fi

# ── Elm ───────────────────────────────────────────────────────────────────────
if has_group elm; then
    echo -e "\n${CYAN}${BOLD}=== elm: deps ===${RESET}"
    (cd frontend && npm install --save-dev elm elm-format elm-test)

    if ! run_group "elm: lint" bash scripts/lint-elm.sh; then FAILED+=(elm-lint); fi
    if ! run_group "elm: test" bash scripts/test-elm.sh; then FAILED+=(elm-test); fi
fi

# ── Rust ──────────────────────────────────────────────────────────────────────
if has_group rust; then
    if ! run_group "rust: lint" bash scripts/lint-rust.sh; then FAILED+=(rust-lint); fi
    if ! run_group "rust: test" bash scripts/test-rust.sh; then FAILED+=(rust-test); fi
fi

# ── Python ────────────────────────────────────────────────────────────────────
if has_group python; then
    echo -e "\n${CYAN}${BOLD}=== python: deps ===${RESET}"
    (cd apps/vision && pip install -r requirements.txt -r requirements-dev.txt)

    if ! run_group "python: lint" bash scripts/lint-python.sh; then FAILED+=(python-lint); fi
    if ! run_group "python: test" bash scripts/test-python.sh; then FAILED+=(python-test); fi
fi

# ── Protobuf ──────────────────────────────────────────────────────────────────
if has_group proto; then
    if ! run_group "proto: lint" bash scripts/lint-proto.sh; then FAILED+=(proto-lint); fi
fi

# ── dbt ───────────────────────────────────────────────────────────────────────
# CI runs lint-sql.sh with SQLFLUFF_TEMPLATER=dbt against a live DB.
# Locally the default in lint-sql.sh is jinja (offline). Override by setting
# SQLFLUFF_TEMPLATER=dbt in your environment if you want full macro resolution.
if has_group dbt; then
    echo -e "\n${CYAN}${BOLD}=== dbt: deps ===${RESET}"
    pip install dbt-postgres sqlfluff sqlfluff-templater-dbt

    if ! run_group "dbt: lint sql" bash scripts/lint-sql.sh; then FAILED+=(dbt-lint-sql); fi
    if ! run_group "dbt: run + test" bash scripts/test-dbt.sh; then FAILED+=(dbt-test); fi
fi

# ── Security ──────────────────────────────────────────────────────────────────
# Requires: gitleaks, semgrep, hadolint, checkov, trivy (all via brew install).
# Note: gitleaks in CI uses fetch-depth=0 to scan full git history.
#   Locally, security.sh uses --no-git (working tree only). To replicate CI
#   exactly run: gitleaks detect --source . (without --no-git).
# Note: CodeQL runs only in CI (.github/workflows/codeql.yml.disabled).
#   It requires GitHub-hosted runners and cannot be replicated locally.
if has_group security; then
    if ! run_group "security: scans" bash scripts/security.sh; then FAILED+=(security); fi
fi

# ── Squawk (migration safety) ──────────────────────────────────────────────────
if has_group squawk; then
    if ! run_group "squawk: migration lint" bash scripts/security-squawk.sh; then FAILED+=(squawk); fi
fi

# ── E2E ───────────────────────────────────────────────────────────────────────
if has_group e2e; then
    if ! run_group "e2e: playwright" bash scripts/test-e2e.sh; then FAILED+=(e2e); fi
fi

# ── Licenses ──────────────────────────────────────────────────────────────────
if has_group licenses; then
    if ! run_group "licenses: compliance" bash scripts/check-licenses.sh; then FAILED+=(licenses); fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All checks passed.${RESET}"
else
    echo -e "${RED}${BOLD}Failed checks:${RESET}"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
fi

# ── Deploy preview (runs only if all local checks passed) ─────────────────────
if [[ ${#FAILED[@]} -eq 0 ]] && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}=== deploy: preview + E2E ===${RESET}"
    bash scripts/deploy-preview.sh || true
fi

if [[ ${#FAILED[@]} -ne 0 ]]; then
    exit 1
fi
