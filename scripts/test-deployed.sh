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
# modules that drive the live API guard on it themselves and self-skip when it
# is unset, so a run without it exercises the dbt/storage half, skips the
# live-API half, and still prints "All deployed-only checks passed". Requiring
# it up front is what stops that vacuous green.
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

# ⚠️ This block used to invoke `dbt run --target preview`, and the whole thing
# was unfalsifiable in two independent ways.
#
#   * There is no `preview` target. dbt/profiles.yml declares exactly ONE
#     output, so the command could never resolve on any machine.
#   * A dbt failure printed FAIL and fell through. The script's only `exit 1`
#     paths were a missing env var and failing Elixir tests, so the summary
#     below could print "All deployed-only checks passed" having never
#     materialised a single model — and did, every time it ran.
#
# Both are fixed by delegating to scripts/dbt-deployed.sh, which derives the
# connection from DATABASE_URL, refuses a local host, sweeps orphan relations
# first, and runs `dbt build` so a model whose test fails does not get built
# upon. Its exit code is honoured here: 2 means nothing ran and is reported as a
# SKIP, anything else non-zero fails the script.
DBT_OK=false
DBT_STATUS="not run"

echo -e "\n${CYAN}${BOLD}--- dbt build against the deployed database ---${RESET}"
set +e
bash "$REPO_ROOT/scripts/dbt-deployed.sh"
dbt_rc=$?
set -e

case "$dbt_rc" in
    0)
        DBT_OK=true
        DBT_STATUS="built"
        echo -e "${GREEN}${BOLD}PASS${RESET} dbt build"
        ;;
    2)
        # Honestly a SKIP: dbt absent, or DATABASE_URL unusable. Not a pass, and
        # it is said in words in the summary rather than left as a bare `false`.
        DBT_STATUS="SKIPPED — nothing was run (see the output above)"
        echo -e "${RED}${BOLD}SKIP${RESET} dbt build — nothing was run"
        ;;
    *)
        echo -e "${RED}${BOLD}FAIL${RESET} dbt build (exit $dbt_rc)"
        echo "The deployed warehouse was not built. Failing rather than continuing:"
        echo "a green deployed-test run that materialised nothing is the defect"
        echo "this script spent its whole life having."
        exit 1
        ;;
esac

echo -e "\n${CYAN}${BOLD}--- mix test --only deployed_only ---${RESET}"

cd "$REPO_ROOT/apps/core"

if mix test --only deployed_only; then
    echo -e "\n${GREEN}${BOLD}PASS${RESET} Deployed-only Elixir tests"
else
    echo -e "\n${RED}${BOLD}FAIL${RESET} Deployed-only Elixir tests"
    exit 1
fi

echo -e "\n${CYAN}${BOLD}=== Summary ===${RESET}"
echo "  dbt warehouse: ${DBT_STATUS}"
echo "  Elixir deployed-only tests: passed"

if [[ "$DBT_OK" == "true" ]]; then
    echo -e "${GREEN}${BOLD}All deployed-only checks passed.${RESET}"
else
    # Not a pass, and it does not claim to be. The exit code stays 0 because the
    # Elixir half did run and did pass; the wording is what stops this being
    # read as a full green.
    echo -e "${CYAN}${BOLD}Elixir deployed-only checks passed; the dbt half was not run.${RESET}"
fi
