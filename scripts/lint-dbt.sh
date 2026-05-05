#!/usr/bin/env bash
set -euo pipefail

# lint-dbt.sh — dbt-checkpoint quality gates for staging models.
#
# Runs after `dbt compile` or `dbt run` (requires dbt/target/manifest.json).
# Validates that generated and hand-written dbt models conform to project
# conventions: descriptions, tests, freshness, column alignment.
#
# Prerequisites: dbt-checkpoint v2.0.8+ (installed by setup.sh)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v check-model-has-description &>/dev/null; then
    echo "ERROR: dbt-checkpoint not installed. Run: pip install 'git+https://github.com/dbt-checkpoint/dbt-checkpoint.git@v2.0.8'" >&2
    exit 1
fi

if [[ ! -f dbt/target/manifest.json ]]; then
    echo "ERROR: dbt/target/manifest.json not found. Run 'dbt compile' or 'dbt run' first." >&2
    exit 1
fi

# Column-level checks (check-model-has-all-columns, check-source-has-all-columns)
# require catalog.json. Always regenerate so it reflects the current DB schema
# rather than a potentially stale artifact from a prior run.
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

# warn_check: logs a warning but does not fail the gate.
# Use for checks with known pre-existing gaps being addressed incrementally.
run_warn() {
    local name="$1"; shift
    echo "  Checking: $name (warn-only)"
    if ! "$@"; then
        WARNED+=("$name")
    fi
}

echo "Running dbt-checkpoint quality gates..."

# --- Model checks ---

# Every model in schema.yml must have a description.
run_check "model-has-description" \
    bash -c 'cd dbt && check-model-has-description models/staging/schema.yml'

# Every model .sql file must have a corresponding schema.yml entry.
run_check "model-has-properties-file" \
    bash -c 'cd dbt && check-model-has-properties-file models/staging/schema.yml -- models/staging/stg_*.sql'

# Every model must have at least 2 tests (not_null + unique on PK at minimum).
run_check "model-has-tests" \
    bash -c 'cd dbt && check-model-has-tests --test-cnt 2 -- models/staging/schema.yml'

# Generated SQL must use source()/ref(), never raw table names.
run_check "script-has-no-table-name" \
    bash -c 'cd dbt && check-script-has-no-table-name models/staging/stg_*.sql'

# All source() and ref() calls must point to existing definitions.
run_check "script-ref-and-source" \
    bash -c 'cd dbt && check-script-ref-and-source models/staging/stg_*.sql'

# Every column in the SQL must be listed in schema.yml (catches drift).
run_check "model-has-all-columns" \
    bash -c 'cd dbt && check-model-has-all-columns models/staging/schema.yml -- models/staging/stg_*.sql'

# --- Source checks ---

# Sources must have freshness configuration.
run_check "source-has-freshness" \
    bash -c 'cd dbt && check-source-has-freshness --freshness warn_after error_after -- models/staging/sources.yml'

# Every column in the source table must be listed in sources.yml.
run_check "source-has-all-columns" \
    bash -c 'cd dbt && check-source-has-all-columns models/staging/sources.yml'

# --- Summary ---

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
