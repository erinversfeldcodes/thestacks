#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

export DBT_USER="${DBT_USER:-postgres}"
export DBT_PASSWORD="${DBT_PASSWORD:-postgres}"
export DBT_HOST="${DBT_HOST:-localhost}"
export DBT_PORT="${DBT_PORT:-5432}"
export DBT_DBNAME="${DBT_DBNAME:-stacks_dev}"

ensure_postgres

echo "==> Generating Ecto schemas from proto..."
(cd "$REPO_ROOT/apps/core" && mix proto.sync)

_pg_bin="$(_find_pg_isready)"; _pg_bin="${_pg_bin%pg_isready}"
"${_pg_bin}psql" -h localhost -U postgres -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'stacks_dev' AND pid <> pg_backend_pid();" \
    -o /dev/null 2>/dev/null || true

mix ecto.drop --quiet
mix ecto.create --quiet
mix ecto.migrate --quiet
mix run apps/core/priv/repo/seeds.exs

(cd dbt && dbt run)
(cd dbt && dbt test)

# ──────────────────────────────────────────────────────────────────────────────
# The Elixir tests that need a dbt-built warehouse.
#
# ⚠️ Eight tests in `upload_dbt_test.exs` assert that the staging views and the
# community-read mart reflect the operational tables, and NONE of them had ever
# run. They were tagged `:deployed_only`, a precondition they cannot be
# satisfied by: each writes a fixture through `Repo` and reads it back from
# `staging.*` through the same `Repo`, so what they need is ONE database holding
# both their fixtures and a warehouse — and a deployed stack has the warehouse
# but not the fixtures. Re-tagged `:needs_dbt_warehouse`; this is the runner
# that satisfies it, so the tag stops being a claim nothing checks.
#
# The TEST database, not the dev one built above: those tests run under
# `MIX_ENV=test` and `Core.Repo` resolves to `stacks_test` there. A staging VIEW
# queried on the test's own sandboxed connection sees its uncommitted fixture,
# which is what makes the arrangement work at all — the views only have to
# exist.
#
# The mart case is the exception and needs the seed: `mart_community_read_count`
# is `materialized='incremental'`, a table rather than a view, so a rolled-back
# fixture is invisible to it and only committed rows count.
echo "==> Preparing the test database for the warehouse-dependent Elixir tests..."
(
    cd "$REPO_ROOT/apps/core"
    MIX_ENV=test mix ecto.create --quiet
    MIX_ENV=test mix ecto.migrate --quiet
)
MIX_ENV=test mix run apps/core/priv/repo/seeds.exs >/dev/null

echo "==> Building the warehouse in the test database..."
(cd dbt && DBT_DBNAME=stacks_test dbt run)

echo "==> Running the warehouse-dependent Elixir tests..."
(cd "$REPO_ROOT/apps/core" && MIX_ENV=test mix test --only needs_dbt_warehouse)
warehouse_tests_rc=$?

# Left seeded, the test database breaks every later `mix test` run that assumes
# an empty one. This script is already destructive by contract — it drops the
# dev database on line 38 — so cleaning up after itself is consistent, and the
# next `mix test` recreates what it needs.
echo "==> Dropping the seeded test database so later runs start clean..."
(cd "$REPO_ROOT/apps/core" && MIX_ENV=test mix ecto.drop --quiet) || true

exit "$warehouse_tests_rc"
