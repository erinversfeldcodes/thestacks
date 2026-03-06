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

# Bootstrap the full development environment (idempotent)
setup:
    bash setup.sh

# Install git hooks (symlinks scripts/hooks/* into .git/hooks/)
install-hooks:
    bash scripts/install-hooks.sh

# Run every CI check locally in CI order (sequential, all groups)
# Optionally pass group names to run a subset: just ci elixir dbt
ci *GROUPS:
    scripts/ci.sh {{GROUPS}}

# Run all tests
test: test-elixir test-elm test-rust test-python test-dbt

# Elixir tests
test-elixir:
    scripts/test-elixir.sh

# Elm tests
test-elm:
    scripts/test-elm.sh

# Rust tests
test-rust:
    scripts/test-rust.sh

# Python tests
test-python:
    scripts/test-python.sh

# Run all linters (check only — no modifications)
lint: lint-elixir lint-elm lint-rust lint-python lint-proto lint-sql

# Elixir lint
lint-elixir:
    scripts/lint-elixir.sh

# Elm lint
lint-elm:
    scripts/lint-elm.sh

# Rust lint
lint-rust:
    scripts/lint-rust.sh

# Python lint
lint-python:
    scripts/lint-python.sh

# Protobuf lint
lint-proto:
    scripts/lint-proto.sh

# SQL lint
lint-sql:
    scripts/lint-sql.sh

# Auto-fix all fixable lint and formatting issues
format:
    scripts/format.sh

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
    scripts/test-dbt.sh

# Security scans (SAST + secrets + deps + IaC)
test-security:
    scripts/security.sh

# Lint protobuf schemas (alias for lint-proto)
buf-lint:
    scripts/lint-proto.sh

# Generate code from protobuf schemas
buf-generate:
    buf generate proto/
