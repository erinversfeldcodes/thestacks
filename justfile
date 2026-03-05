# The Stacks — Task Runner

# Start all services for local development.
# Run each service in a separate terminal, or use this recipe which
# backgrounds all three. Press Ctrl-C to stop; child processes will
# receive SIGTERM via the trap.
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    just db-create 2>/dev/null || true
    just db-migrate
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
    (cd apps/core && mix phx.server) &
    (cd apps/vision && uvicorn app.main:app --reload --port 8000) &
    (cd apps/scraper && cargo run) &
    wait

# Run all tests
test: test-elixir test-elm test-rust test-python test-dbt

# Elixir tests
test-elixir:
    mix test

# Elm tests
test-elm:
    cd frontend && npx elm-test

# Rust tests
test-rust:
    cd apps/scraper && cargo test

# Python tests
test-python:
    cd apps/vision && pytest

# Run all linters (check only — no modifications)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    mix format --check-formatted && mix credo --strict && mix dialyzer
    (cd frontend && npx elm-format --validate src/)
    (cd apps/scraper && cargo fmt --check && cargo clippy -- -D warnings)
    (cd apps/vision && ruff check . && ruff format --check . && mypy app/)
    buf lint proto/
    # jinja templater: works offline, no dbt profile/DB required
    (cd dbt && sqlfluff lint models/ --templater jinja)

# Auto-fix all fixable lint and formatting issues
format:
    #!/usr/bin/env bash
    set -euo pipefail
    mix format
    (cd frontend && npx elm-format --yes src/)
    (cd apps/scraper && cargo fmt)
    # ruff check --fix handles auto-fixable lint violations; ruff format handles style
    (cd apps/vision && ruff check --fix . && ruff format .)
    (cd dbt && sqlfluff fix models/ --templater jinja)

# Create database
db-create:
    mix ecto.create

# Run database migrations
db-migrate:
    mix ecto.migrate

# Verify all migrations are reversible
db-rollback-check:
    mix ecto.rollback --all --quiet && mix ecto.migrate --quiet

# Reset database (drop + create + migrate)
db-reset:
    mix ecto.reset

# Run dbt run + test (staging layer only)
# Resets the DB, loads Ecto seeds, then validates dbt staging models.
test-dbt:
    #!/usr/bin/env bash
    set -euo pipefail
    mix ecto.drop --quiet
    mix ecto.create --quiet
    mix ecto.migrate --quiet
    mix run apps/core/priv/repo/seeds.exs
    (cd dbt && dbt run --select staging && dbt test --select staging)

# Security scans (SAST + secrets + deps)
test-security:
    mix deps.audit
    (cd apps/scraper && cargo audit)
    mix sobelow --config
    gitleaks detect --source . --no-git

# Lint protobuf schemas
buf-lint:
    buf lint proto/

# Generate code from protobuf schemas
buf-generate:
    buf generate proto/
