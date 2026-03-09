# The Stacks — Task Runner

# Start all available services for local development.
# Compiles Elm, runs migrations, then starts Phoenix (always),
# the vision sidecar (if apps/vision/app/main.py exists), and
# the scraper (if apps/scraper/src/main.rs exists).
# Opens http://localhost:3000 in your browser when ready.
# Press Ctrl-C to stop all processes.
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    just db-create 2>/dev/null || true
    just db-migrate

    echo "==> Compiling Elm..."
    (cd frontend && npm run build)

    trap 'kill $(jobs -p) 2>/dev/null; exit 0' EXIT INT TERM

    echo "==> Starting Phoenix on http://localhost:4000"
    mix phx.server &

    echo "==> Serving frontend on http://localhost:4001"
    python3 -m http.server 4001 --directory frontend &

    if command -v uvicorn >/dev/null 2>&1 && [ -f apps/vision/app/main.py ]; then
        echo "==> Starting vision sidecar on http://localhost:8000"
        (cd apps/vision && uvicorn app.main:app --reload --port 8000) &
    else
        echo "==> Vision sidecar not ready — skipping (Issue #003)"
    fi

    if [ -f apps/scraper/src/main.rs ]; then
        echo "==> Starting scraper"
        (cd apps/scraper && cargo run) &
    else
        echo "==> Scraper not built yet — skipping (Phase 2)"
    fi

    echo ""
    echo "    The Stacks is running at http://localhost:4001"
    echo "    Press Ctrl-C to stop."
    echo ""
    sleep 1 && open http://localhost:4001 &
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

# Install Python dev dependencies (pytest, ruff, mypy, pip-audit, etc.)
install-python-dev:
    cd apps/vision && .venv/bin/pip install -r requirements-dev.txt

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

# Run the vision sidecar Atheris fuzz target against the seed corpus (all platforms)
# Pass -- -atheris_runs=N to run the full fuzzer (Linux + atheris installed only)
fuzz-vision *ARGS:
    cd apps/vision && PYTHONPATH=. VISION_ENVIRONMENT=test .venv/bin/python tests/fuzz_image_input.py {{ARGS}}

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
