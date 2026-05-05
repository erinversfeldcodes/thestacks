#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

ensure_postgres

# Generate Ecto schemas from proto definitions (gen/ is gitignored).
echo "==> Generating Ecto schemas from proto..."
(cd "$REPO_ROOT/apps/core" && mix proto.sync)

# Kill any lingering BEAM processes holding connections to stacks_test.
# DBConnection reconnects immediately after pg_terminate_backend, so the only
# reliable fix is to stop the Elixir process that owns the pool.
# proto.sync (run above) exits before this point, so any BEAM processes still
# connected to postgres are orphaned from a previous mix coveralls run.
_lingering_pids=$(lsof -i TCP:5432 2>/dev/null | awk '/beam\.smp/ {print $2}' | sort -u)
if [[ -n "$_lingering_pids" ]]; then
    echo "==> Killing lingering BEAM processes: $_lingering_pids"
    echo "$_lingering_pids" | xargs kill -TERM 2>/dev/null || true
    sleep 2
    # SIGKILL any that didn't respond to SIGTERM
    echo "$_lingering_pids" | xargs kill -KILL 2>/dev/null || true
fi

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
