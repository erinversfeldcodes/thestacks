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
test: test-elixir test-elm test-rust test-python

# Elixir tests
test-elixir:
    cd apps/core && mix test

# Elm tests
test-elm:
    cd frontend && npx elm-test

# Rust tests
test-rust:
    cd apps/scraper && cargo test

# Python tests
test-python:
    cd apps/vision && pytest

# Run all linters
lint:
    cd apps/core && mix format --check-formatted && mix credo --strict
    cd frontend && npx elm-format --validate src/
    cd apps/scraper && cargo fmt --check && cargo clippy -- -D warnings
    cd apps/vision && ruff check . && ruff format --check .
    buf lint proto/

# Format all code
format:
    cd apps/core && mix format
    cd frontend && npx elm-format --yes src/
    cd apps/scraper && cargo fmt
    cd apps/vision && ruff format .

# Create database
db-create:
    cd apps/core && mix ecto.create

# Run database migrations
db-migrate:
    cd apps/core && mix ecto.migrate

# Reset database (drop + create + migrate)
db-reset:
    cd apps/core && mix ecto.reset

# Lint protobuf schemas
buf-lint:
    buf lint proto/

# Generate code from protobuf schemas
buf-generate:
    buf generate proto/
