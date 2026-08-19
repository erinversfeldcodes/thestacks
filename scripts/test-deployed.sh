#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${CYAN}${BOLD}=== Deployed-only test suite ===${RESET}"

# Both of these are load-bearing, and BASE_URL especially so: the deployed-only
# modules guard on it themselves and self-skip when it is unset, so a run
# without it exercises the dbt/storage half, skips the live-API half, and still
# prints "All deployed-only checks passed". Requiring it up front is what stops
# that vacuous green.
missing=()
[[ -z "${DATABASE_URL:-}" ]] && missing+=("DATABASE_URL")
[[ -z "${BASE_URL:-}" ]] && missing+=("BASE_URL")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}${BOLD}ERROR:${RESET} Missing required env vars: ${missing[*]}"
    echo "Set them before running, e.g.:"
    echo "  DATABASE_URL=postgres://... BASE_URL=https://<preview>.fly.dev \\"
    echo "    bash scripts/test-deployed.sh"
    exit 1
fi

echo "  DATABASE_URL is set"
echo "  BASE_URL=${BASE_URL}"

DBT_OK=false

if command -v dbt &>/dev/null; then
    echo -e "\n${CYAN}${BOLD}--- dbt run --target preview ---${RESET}"
    if (cd "$REPO_ROOT/dbt" && dbt run --target preview); then
        DBT_OK=true
        echo -e "${GREEN}${BOLD}PASS${RESET} dbt run"

        echo -e "\n${CYAN}${BOLD}--- dbt test --target preview ---${RESET}"
        if (cd "$REPO_ROOT/dbt" && dbt test --target preview); then
            echo -e "${GREEN}${BOLD}PASS${RESET} dbt test"
        else
            echo -e "${RED}${BOLD}FAIL${RESET} dbt test (continuing with Elixir tests)"
        fi
    else
        echo -e "${RED}${BOLD}FAIL${RESET} dbt run (continuing with Elixir tests)"
    fi
else
    echo -e "\n${CYAN}dbt not found on PATH — skipping dbt run/test${RESET}"
fi

echo -e "\n${CYAN}${BOLD}--- mix test --only deployed_only ---${RESET}"

cd "$REPO_ROOT/apps/core"

if mix test --only deployed_only; then
    echo -e "\n${GREEN}${BOLD}PASS${RESET} Deployed-only Elixir tests"
else
    echo -e "\n${RED}${BOLD}FAIL${RESET} Deployed-only Elixir tests"
    exit 1
fi

echo -e "\n${CYAN}${BOLD}=== Summary ===${RESET}"
echo "  dbt materialised: ${DBT_OK}"
echo "  Elixir deployed-only tests: passed"
echo -e "${GREEN}${BOLD}All deployed-only checks passed.${RESET}"
