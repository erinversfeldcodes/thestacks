# The Stacks — Task Runner
set dotenv-load

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

    echo "==> Building assets (Elm + CSS via esbuild)..."
    (cd apps/core/assets && npm run deploy)

    # Kill any stale processes from a previous dev session on our ports.
    echo "==> Cleaning up stale dev processes..."
    lsof -ti :4000 | xargs kill -9 2>/dev/null || true
    lsof -ti :8000 | xargs kill -9 2>/dev/null || true
    pkill -f "stacks-scraper" 2>/dev/null || true
    sleep 0.5

    trap 'kill $(jobs -p) 2>/dev/null; exit 0' EXIT INT TERM

    echo "==> Starting Phoenix on http://localhost:4000"
    mix phx.server &

    if [ -f apps/vision/app/main.py ]; then
        if [ ! -f apps/vision/.venv/bin/uvicorn ]; then
            echo "==> Installing vision sidecar dependencies..."
            python3 -m venv apps/vision/.venv
            apps/vision/.venv/bin/pip install -q -r apps/vision/requirements.txt
        fi
        echo "==> Starting vision sidecar on http://localhost:8000"
        (cd apps/vision && .venv/bin/uvicorn app.main:app --reload --port 8000) &
    else
        echo "==> Vision sidecar not built yet — skipping (Phase 1D)"
    fi

    if [ -f apps/scraper/src/main.rs ]; then
        echo "==> Starting scraper"
        (cd apps/scraper && cargo run) &
    else
        echo "==> Scraper not built yet — skipping (Phase 2)"
    fi

    echo ""
    echo "    The Stacks is running at http://localhost:4000"
    echo "    Press Ctrl-C to stop."
    echo ""
    sleep 1 && open http://localhost:4000 &
    wait

# Bootstrap the full development environment (idempotent)
setup:
    bash setup.sh

# Install git hooks and ensure Claude Code hook scripts are executable.
# Claude Code hooks (.claude/settings.json) activate automatically — this
# just ensures execute bits are set after a fresh clone.
install-hooks:
    bash scripts/install-hooks.sh

# Install or update flyctl from GitHub releases (superfly/homebrew-tap is abandoned)
install-flyctl:
    bash scripts/install-flyctl.sh

# Check if flyctl update is available
check-flyctl:
    bash scripts/install-flyctl.sh --check

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
lint: lint-elixir lint-elm lint-rust lint-python lint-proto lint-sql lint-dbt

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

# dbt-checkpoint quality gates (requires dbt/target/manifest.json)
lint-dbt:
    scripts/lint-dbt.sh

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

# Reset database (drop + create + migrate + seed)
# Seeds are run explicitly here because Mix alias chaining doesn't reliably
# start the full application context needed by Repo.insert_all.
db-reset:
    mix ecto.reset
    mix run apps/core/priv/repo/seeds.exs

# Run Playwright E2E tests (requires just dev to be running on :4000/:4001)
test-e2e:
    cd e2e && npm test

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

# Generate Ecto schemas + dbt models from proto definitions
proto-sync:
    cd apps/core && mix proto.sync

# Check proto-to-schema drift (CI mode — no writes)
proto-sync-check:
    cd apps/core && mix proto.sync --check

# Run E2E tests with service lifecycle management
test-e2e-ci:
    scripts/test-e2e.sh

# Check licence compliance
check-licenses:
    scripts/check-licenses.sh

# Lint changed migrations with squawk
squawk:
    scripts/security-squawk.sh

# Deploy ephemeral preview + run E2E against it + destroy
deploy-preview:
    scripts/deploy-preview.sh
