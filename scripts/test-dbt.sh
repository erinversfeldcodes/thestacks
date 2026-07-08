#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets (CLOAK_KEY, etc.) if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

# dbt lives in .venv-tools/, exposed by flake.nix shellHook inside the dev
# shell. Outside it, python-tools.sh surfaces .venv-tools/bin and the active
# interpreter's pip --user bin, and require_dbt_core guards against `dbt`
# resolving to the Homebrew dbt Cloud CLI (same binary name, wrong product).
# shellcheck source=scripts/lib/python-tools.sh
source "$REPO_ROOT/scripts/lib/python-tools.sh"
ensure_python_tools_path
require_dbt_core

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

# Generate Ecto schemas from proto definitions (gen/ is gitignored).
echo "==> Generating Ecto schemas from proto..."
(cd "$REPO_ROOT/apps/core" && mix proto.sync)

# Terminate any open connections before dropping so this is safe to run after
# other test suites (e.g. test-elixir) that leave DB pool connections alive.
_pg_bin="$(_find_pg_isready)"; _pg_bin="${_pg_bin%pg_isready}"
"${_pg_bin}psql" -h localhost -U postgres -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'stacks_dev' AND pid <> pg_backend_pid();" \
    -o /dev/null 2>/dev/null || true

# Always start from a clean DB so Ecto seeds load without FK ordering issues.
mix ecto.drop --quiet
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run apps/core/priv/repo/seeds.exs

(cd dbt && dbt run)
(cd dbt && dbt test)
