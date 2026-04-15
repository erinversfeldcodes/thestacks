#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

ensure_postgres

# Generate Ecto schemas from proto definitions (gen/ is gitignored).
echo "==> Generating Ecto schemas from proto..."
(cd "$REPO_ROOT/apps/core" && mix proto.sync)

# Reset the test DB so migrations always run cleanly from a blank slate.
MIX_ENV=test mix ecto.drop --quiet
MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --quiet

coverage_rc=0
coverage_output="$(cd "$REPO_ROOT/apps/core" && mix coveralls 2>&1)" || coverage_rc=$?
echo "$coverage_output"
if [[ $coverage_rc -ne 0 ]]; then
    echo "ERROR: mix coveralls exited with code $coverage_rc" >&2
    exit $coverage_rc
fi

# Enforce minimum coverage threshold (excoveralls minimum_coverage config does not
# set a non-zero exit code on its own — parse the [TOTAL] line ourselves).
MINIMUM_COVERAGE=80
total="$(echo "$coverage_output" | grep '^\[TOTAL\]' | grep -oE '[0-9]+\.[0-9]+')"
if [[ -z "$total" ]]; then
    echo "ERROR: could not parse coverage total from excoveralls output" >&2
    exit 1
fi
pct="${total%.*}"  # integer part only for comparison
if [[ "$pct" -lt "$MINIMUM_COVERAGE" ]]; then
    echo "ERROR: coverage ${total}% is below minimum ${MINIMUM_COVERAGE}%" >&2
    exit 1
fi

# Verify all migrations are reversible
(cd "$REPO_ROOT/apps/core" && MIX_ENV=test mix ecto.rollback --all --quiet)
