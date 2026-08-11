#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Surface .venv-tools/ and pip --user tools outside the dev shell, and make
# sure `dbt` is dbt-core (not the Homebrew dbt Cloud CLI) before `dbt docs
# generate` below.
# shellcheck source=scripts/lib/python-tools.sh
source "$REPO_ROOT/scripts/lib/python-tools.sh"
ensure_python_tools_path
require_dbt_core

if ! command -v check-model-has-description &>/dev/null; then
    echo "ERROR: dbt-checkpoint not installed. Run: pip install 'git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8'" >&2
    exit 1
fi

if [[ ! -f dbt/target/manifest.json ]]; then
    echo "ERROR: dbt/target/manifest.json not found. Run 'dbt compile' or 'dbt run' first." >&2
    exit 1
fi

echo "Generating dbt catalog for column-level checks..."
(cd dbt && dbt docs generate --quiet)

FAILED=()
WARNED=()

run_check() {
    local name="$1"; shift
    echo "  Checking: $name"
    if ! "$@"; then
        FAILED+=("$name")
    fi
}

run_warn() {
    local name="$1"; shift
    echo "  Checking: $name (warn-only)"
    if ! "$@"; then
        WARNED+=("$name")
    fi
}

echo "Running dbt-checkpoint quality gates..."

run_check "model-has-description" \
    bash -c 'cd dbt && check-model-has-description models/staging/schema.yml'

run_check "model-has-properties-file" \
    bash -c 'cd dbt && check-model-has-properties-file models/staging/schema.yml -- models/staging/stg_*.sql'

run_check "model-has-tests" \
    bash -c 'cd dbt && check-model-has-tests --test-cnt 2 -- models/staging/schema.yml'

run_check "script-has-no-table-name" \
    bash -c 'cd dbt && check-script-has-no-table-name models/staging/stg_*.sql'

run_check "script-ref-and-source" \
    bash -c 'cd dbt && check-script-ref-and-source models/staging/stg_*.sql'

run_check "model-has-all-columns" \
    bash -c 'cd dbt && check-model-has-all-columns models/staging/schema.yml -- models/staging/stg_*.sql'

run_check "source-has-freshness" \
    bash -c 'cd dbt && check-source-has-freshness --freshness warn_after error_after -- models/staging/sources.yml'

run_check "source-has-all-columns" \
    bash -c 'cd dbt && check-source-has-all-columns models/staging/sources.yml'

if [[ ${#WARNED[@]} -gt 0 ]]; then
    echo ""
    echo "WARN dbt-checkpoint checks (non-blocking):"
    for w in "${WARNED[@]}"; do
        echo "  - $w"
    done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "FAILED dbt-checkpoint checks:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
    exit 1
else
    echo "All blocking dbt-checkpoint checks passed."
fi
