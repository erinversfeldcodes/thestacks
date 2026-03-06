#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure pip-installed tools (dbt, sqlfluff) are on PATH.
# Python --user installs land in ~/Library/Python/*/bin on macOS.
for pybin in "$HOME"/Library/Python/*/bin; do
    [[ -d "$pybin" ]] && export PATH="$pybin:$PATH"
done
# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

# ── Connect as postgres superuser (same as CI) ─────────────────────────────────
# profiles.yml defaults to the stacks_dbt role, which has no LOGIN privilege.
# Locally we connect as the postgres superuser, matching CI behaviour.
# These can be overridden by exporting the DBT_* vars before running this script.
export DBT_USER="${DBT_USER:-postgres}"
export DBT_PASSWORD="${DBT_PASSWORD:-postgres}"
export DBT_HOST="${DBT_HOST:-localhost}"
export DBT_PORT="${DBT_PORT:-5432}"
export DBT_DBNAME="${DBT_DBNAME:-stacks_dev}"

ensure_postgres

# Always start from a clean DB so Ecto seeds load without FK ordering issues.
mix ecto.drop --quiet
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run apps/core/priv/repo/seeds.exs

(cd dbt && dbt run --select staging)
(cd dbt && dbt test --select staging)
