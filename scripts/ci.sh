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

# Load version pins (OTP, Elixir, Node, Python, Postgres).
# Same file consumed by .github/workflows/ci.yml via the `versions` job.
if [[ -f "$REPO_ROOT/.versions" ]]; then
    # shellcheck source=../.versions
    source "$REPO_ROOT/.versions"
fi

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
    # e2e and smoke are excluded from the default run — they require a live deployed
    # stack. Run explicitly with: scripts/ci.sh e2e  or  scripts/ci.sh smoke
    # smoke requires SMOKE_URL and SCRAPER_HMAC_SECRET to be set.
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
    # Toolchain drift guard (Issue #300): fail early if the flake's Elixir/OTP
    # has drifted from .versions — CI's nix-less runner can't check the flake,
    # so this is the only place the divergence is caught.
    if ! run_group "elixir: version-drift" bash scripts/check-version-drift.sh; then FAILED+=(elixir-version-drift); fi

    echo -e "\n${CYAN}${BOLD}=== elixir: deps ===${RESET}"
    mix deps.get

    echo -e "\n${CYAN}${BOLD}=== elixir: proto.sync ===${RESET}"
    (cd apps/core && mix proto.sync)

    if ! run_group "elixir: lint" bash scripts/lint-elixir.sh; then FAILED+=(elixir-lint); fi
    if ! run_group "elixir: test" bash scripts/test-elixir.sh; then FAILED+=(elixir-test); fi
fi

# ── Elm ───────────────────────────────────────────────────────────────────────
if has_group elm; then
    echo -e "\n${CYAN}${BOLD}=== elm: deps ===${RESET}"
    (cd frontend && npm ci)

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
    # Use the venv pip — the system pip3 is too old to resolve modern package versions.
    VENV_PIP="$REPO_ROOT/apps/vision/.venv/bin/pip"
    PIP="${VENV_PIP:-$(command -v pip3 || command -v pip)}"
    (cd apps/vision && "$PIP" install -r requirements.txt -r requirements-dev.txt)

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
    PIP="$(command -v pip3 || command -v pip)"
    "$PIP" install dbt-postgres sqlfluff sqlfluff-templater-dbt

    if ! run_group "dbt: lint sql" bash scripts/lint-sql.sh; then FAILED+=(dbt-lint-sql); fi
    if ! run_group "dbt: run + test" bash scripts/test-dbt.sh; then FAILED+=(dbt-test); fi
    if ! run_group "dbt: checkpoint" bash scripts/lint-dbt.sh; then FAILED+=(dbt-checkpoint); fi
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

# ── Smoke (circuit breakers) ──────────────────────────────────────────────────
# Requires a live deployed stack. Set SMOKE_URL and SCRAPER_HMAC_SECRET.
# Example: SMOKE_URL=https://my-app.fly.dev scripts/ci.sh smoke
if has_group smoke; then
    if [[ -z "${SMOKE_URL:-}" ]]; then
        echo -e "${RED}${BOLD}ERROR${RESET} smoke: SMOKE_URL is not set"
        FAILED+=(smoke)
    elif [[ -z "${SCRAPER_HMAC_SECRET:-}" ]]; then
        echo -e "${RED}${BOLD}ERROR${RESET} smoke: SCRAPER_HMAC_SECRET is not set"
        FAILED+=(smoke)
    else
        if ! run_group "smoke: circuit breakers" \
            bash scripts/smoke-circuit-breakers.sh "${SMOKE_URL}"; then
            FAILED+=(smoke)
        fi
    fi
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

# ── Deploy preview (runs only when full default suite passes) ─────────────────
# Only triggers when all groups are run (no args), all pass, and FLY_API_TOKEN
# is set. Skipped when running a targeted subset (e.g. ci.sh elixir rust).
if [[ $# -eq 0 ]] && [[ ${#FAILED[@]} -eq 0 ]] && [[ -n "${FLY_API_TOKEN:-}" ]]; then
    _branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
    # Shared derivation (Issue #170 C): honours the optional PREVIEW_SUFFIX
    # env var (set by CI, unset locally) so this block and the deploy/cleanup
    # scripts always agree on the preview resource names.
    # shellcheck source=scripts/lib/preview-names.sh
    source "$REPO_ROOT/scripts/lib/preview-names.sh"
    derive_preview_names "$_branch"
    _core_app="${PREVIEW_CORE_APP}"
    _core_url="https://${_core_app}.fly.dev"
    _neon_branch="${PREVIEW_NEON_BRANCH}"

    # ── Deploy + warmup ───────────────────────────────────────────────────────
    echo -e "\n${CYAN}${BOLD}=== deploy: stack + warmup ===${RESET}"
    if bash scripts/deploy-preview.sh; then

        # ── E2E ───────────────────────────────────────────────────────────────
        echo -e "\n${CYAN}${BOLD}=== deploy: E2E ===${RESET}"

        # Warm both Fly machines AND the Neon database before Playwright starts.
        # Health-check and login page hits wake the Fly machines; the DB calls
        # (login API + catalogue query) unpark Neon so the first Playwright test
        # doesn't time out waiting for the DB to spin up.
        echo "==> Warming Fly.io machines and Neon database..."
        _warm_pids=()
        for i in {1..20}; do
            curl -sf --max-time 5 "${_core_url}/api/health" >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        for i in {1..10}; do
            curl -sf --max-time 10 "${_core_url}/login" >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        # DB-warming calls: POST /api/auth/login and GET /api/catalogue both query
        # Postgres, ensuring Neon is active before Playwright's first test runs.
        for i in {1..5}; do
            curl -sf --max-time 30 "${_core_url}/api/auth/login" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                >/dev/null 2>&1 &
            _warm_pids+=("$!")
        done
        for i in {1..3}; do
            _db_warm_token="$(curl -sf --max-time 30 "${_core_url}/api/auth/login" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
            if [[ -n "${_db_warm_token}" ]]; then
                curl -sf --max-time 30 "${_core_url}/api/catalogue?per_page=20" \
                    -H "Authorization: Bearer ${_db_warm_token}" >/dev/null 2>&1 || true
            fi
        done
        for pid in "${_warm_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        sleep 2

        # Keep-alive: prevents auto_stop_machines firing mid-suite
        (while true; do
            curl -sf --max-time 5 "${_core_url}/api/health" >/dev/null 2>&1 || true
            sleep 10
        done) &
        _keep_alive_pid=$!

        _fly_logs="$(mktemp)"
        (fly logs --app "${_core_app}" 2>&1) > "${_fly_logs}" &
        _fly_logs_pid=$!

        if ! CI=1 E2E_SERVICES=none BASE_URL="${_core_url}" \
                run_group "deploy: e2e" bash scripts/test-e2e.sh; then
            FAILED+=(deploy-e2e)
        fi

        kill "${_keep_alive_pid}" 2>/dev/null || true
        kill "${_fly_logs_pid}" 2>/dev/null || true
        wait "${_fly_logs_pid}" 2>/dev/null || true
        echo ""
        echo "--- Core app logs during E2E (last 200 lines) ---"
        tail -200 "${_fly_logs}" || true
        echo "--- End core logs ---"
        rm -f "${_fly_logs}"

        # ── Smoke (circuit breakers) — must run after E2E ─────────────────────
        # Deliberately blows all circuit breakers; running before E2E corrupts
        # Fuse state on both Fly machines and causes vision tests to fast-fail.
        if [[ -n "${SCRAPER_HMAC_SECRET:-}" ]]; then
            if ! SMOKE_URL="${_core_url}" \
                    run_group "deploy: smoke" \
                    bash scripts/smoke-circuit-breakers.sh "${_core_url}"; then
                true  # advisory — circuit breaker failures don't gate the build
            fi
        else
            echo "SKIP deploy: smoke — SCRAPER_HMAC_SECRET not set"
        fi

        # ── Security live (OWASP ZAP, Nuclei, jwt_tool, IDOR) ────────────────
        echo -e "\n${CYAN}${BOLD}=== deploy: security-live ===${RESET}"

        if command -v docker &>/dev/null; then
            echo "==> OWASP ZAP baseline scan..."
            # Pinned to 2.16.1 — the upstream `:stable` tag drifted to a
            # state where the Automation Framework writes its summary file
            # to a path zap-baseline.py doesn't expect (`/home/zap/zap_out.json`)
            # and `--autooff` mode times out downloading add-ons before the
            # scan starts. 2.16.1 is the last known-good version where
            # baseline.py + AF + add-on bundle line up. Bumping the pin is
            # a one-line edit; pair with a fresh local re-run to confirm
            # the new tag still produces the `FAIL-NEW: 0` line the grep
            # below depends on.
            zap_out="$(docker run --rm \
                --mount type=tmpfs,destination=/zap/wrk \
                ghcr.io/zaproxy/zaproxy:2.16.1 \
                zap-baseline.py -t "${_core_url}" 2>&1)" || true
            echo "${zap_out}"
            if echo "${zap_out}" | grep -q "FAIL-NEW: 0"; then
                pass "deploy: ZAP baseline"
            else
                fail "deploy: ZAP baseline found new failures"
            fi
        else
            echo "SKIP: docker not available — skipping OWASP ZAP"
        fi

        if command -v nuclei &>/dev/null; then
            echo "==> Nuclei (jwt + misconfig)..."
            nuclei_out="$(nuclei -u "${_core_url}" \
                -tags jwt,misconfiguration \
                -severity medium,high,critical \
                -no-color -silent 2>&1)" || true
            echo "${nuclei_out}"
            if echo "${nuclei_out}" | grep -qiE "\[critical\]|\[high\]"; then
                fail "deploy: Nuclei found high/critical vulnerabilities"
            else
                pass "deploy: Nuclei scan clean"
            fi
        else
            echo "SKIP: nuclei not installed (brew install nuclei)"
        fi

        if command -v jwt_tool &>/dev/null; then
            echo "==> jwt_tool..."
            _jwt_resp="$(curl -sf "${_core_url}/api/auth/login" \
                -H "Content-Type: application/json" \
                -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' \
                2>/dev/null || true)"
            _jwt="$(echo "${_jwt_resp}" | python3 -c \
                "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
            if [[ -n "${_jwt}" ]]; then
                jwt_out="$(jwt_tool "${_jwt}" \
                    -t "${_core_url}/api/auth/me" \
                    -rh "Authorization: Bearer *JWT*" \
                    -X a 2>&1)" || true
                echo "${jwt_out}"
                if echo "${jwt_out}" | grep -qi "EXPLOIT"; then
                    fail "deploy: jwt_tool found exploitable vulnerability"
                else
                    pass "deploy: jwt_tool clean"
                fi
            else
                echo "SKIP: jwt_tool — could not obtain JWT"
            fi
        else
            echo "SKIP: jwt_tool not installed (run setup.sh)"
        fi

        echo "==> IDOR test (cross-user resource access)..."
        _u1="$(curl -sf "${_core_url}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d '{"email":"owner@thestacks.app","password":"dev-password-123"}' 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" \
            2>/dev/null || true)"
        _u2="$(curl -sf "${_core_url}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d '{"email":"user@thestacks.app","password":"dev-password-456"}' 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" \
            2>/dev/null || true)"
        if [[ -z "${_u1}" ]] || [[ -z "${_u2}" ]]; then
            echo "SKIP: IDOR — could not authenticate both seed users"
        else
            _placement="$(curl -sf "${_core_url}/api/bookshelves/library" \
                -H "Authorization: Bearer ${_u1}" 2>/dev/null \
                | python3 -c \
                    "import json,sys; d=json.load(sys.stdin); s=d.get('shelves',[]); p=[pl for sh in s for pl in sh.get('placements',[])]; print(p[0]['id'] if p else '')" \
                2>/dev/null || true)"
            if [[ -n "${_placement}" ]]; then
                _idor_code="$(curl -o /dev/null -s -w "%{http_code}" \
                    -X DELETE "${_core_url}/api/placements/${_placement}" \
                    -H "Authorization: Bearer ${_u2}")"
                if [[ "${_idor_code}" == "200" ]]; then
                    fail "deploy: IDOR — user2 deleted user1's placement (HTTP 200)"
                else
                    pass "deploy: IDOR cross-user DELETE blocked (HTTP ${_idor_code})"
                fi
            else
                echo "SKIP: IDOR — user1 has no placements in library"
            fi
        fi

    else
        fail "deploy: stack or warmup failed"
        FAILED+=(deploy)
    fi

    # ── Cleanup — always runs, whether deploy/tests passed or failed ──────────
    echo -e "\n${CYAN}${BOLD}=== deploy: cleanup ===${RESET}"
    bash scripts/cleanup-preview.sh \
        --branch "${_branch}" \
        --neon-branch-name "${_neon_branch}" || true
fi

if [[ ${#FAILED[@]} -ne 0 ]]; then
    exit 1
fi
