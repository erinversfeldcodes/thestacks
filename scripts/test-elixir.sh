#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

ensure_postgres

# Reset the test DB so migrations always run cleanly from a blank slate.
MIX_ENV=test mix ecto.drop --quiet
MIX_ENV=test mix ecto.create --quiet
MIX_ENV=test mix ecto.migrate --quiet

(cd "$REPO_ROOT/apps/core" && mix coveralls)

# Verify all migrations are reversible
(cd apps/core && MIX_ENV=test mix ecto.rollback --all --quiet)
