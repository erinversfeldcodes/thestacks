#!/usr/bin/env bash
# scripts/test-e2e.sh — start all services and run Playwright E2E tests.
#
# In CI (or any fresh environment) this script:
#   1. Starts Phoenix on :4000 with a live DB
#   2. Serves the pre-built Elm frontend on :4001
#   3. Starts the vision sidecar on :8000 (if present)
#   4. Waits for each service to be ready
#   5. Runs `npm test` (playwright) inside e2e/
#   6. Stops all services on exit (trap)
#
# If services are already running on the expected ports the script
# skips starting them and runs the tests against the live stack.
# This makes it safe to call both from `just ci` and interactively.
#
# Env overrides:
#   BASE_URL           Playwright base URL (default: http://localhost:4001)
#   E2E_SERVICES       Set to "none" to skip starting services (use live stack)
#   DATABASE_URL       Override DB connection for Phoenix
#
# Prerequisites: Node (playwright installed in e2e/), Elixir/Mix, Python venv,
#               npx serve, PostgreSQL running.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets (CLOAK_KEY, SECRET_KEY_BASE, etc.) if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# wait_for_health <url> <name> [timeout_seconds]
# Polls the given HTTP health endpoint until it returns HTTP 200.
# Uses curl --fail so any non-2xx response is treated as not-ready.
# This is deterministic: we verify the service is actually serving valid responses,
# not just that a TCP port has been opened (which happens before the app is ready).
wait_for_health() {
    local url="$1"
    local name="$2"
    local timeout="${3:-60}"
    local deadline=$(( $(date +%s) + timeout ))

    until curl -sf --max-time 2 "$url" > /dev/null 2>&1; do
        if [[ $(date +%s) -ge $deadline ]]; then
            echo "ERROR: $name did not become healthy at $url within ${timeout}s." >&2
            echo "       Last log output:" >&2
            case "$name" in
                Phoenix) tail -20 /tmp/stacks-phoenix.log >&2 ;;
                Frontend) tail -5 /tmp/stacks-frontend.log >&2 ;;
                Vision) tail -20 /tmp/stacks-vision.log >&2 ;;
            esac
            exit 1
        fi
        # No sleep — curl itself has a 2s timeout, so we're polling at most every 2s
        # without any artificial delay between attempts.
    done
    echo "  $name healthy at $url"
}

# port_open is kept for the "already running" pre-checks only.
port_open() {
    nc -z localhost "$1" 2>/dev/null
}

# ── Install E2E deps if needed ─────────────────────────────────────────────────
if [[ ! -d "$REPO_ROOT/e2e/node_modules" ]]; then
    echo "==> Installing E2E dependencies..."
    (cd "$REPO_ROOT/e2e" && npm install)
fi

# Install Playwright browsers if needed
if [[ ! -d "$HOME/.cache/ms-playwright" && ! -d "$HOME/Library/Caches/ms-playwright" ]]; then
    echo "==> Installing Playwright browsers..."
    (cd "$REPO_ROOT/e2e" && npx playwright install --with-deps chromium)
fi

# ── Start services unless already running ────────────────────────────────────
SERVICES_STARTED=()
STARTED_PIDS=()

if [[ "${E2E_SERVICES:-}" != "none" ]]; then
    ensure_postgres

    # Phoenix on :4000
    if port_open 4000; then
        echo "  Phoenix already running on :4000 — skipping start"
    else
        echo "==> Starting Phoenix on :4000..."
        (
            cd "$REPO_ROOT"
            MIX_ENV=dev mix phx.server
        ) &>/tmp/stacks-phoenix.log &
        STARTED_PIDS+=($!)
        SERVICES_STARTED+=(phoenix)
    fi

    # Frontend on :4001
    if port_open 4001; then
        echo "  Frontend already running on :4001 — skipping start"
    else
        echo "==> Serving frontend on :4001..."
        (
            cd "$REPO_ROOT"
            npx serve -s frontend -l 4001 --no-clipboard
        ) &>/tmp/stacks-frontend.log &
        STARTED_PIDS+=($!)
        SERVICES_STARTED+=(frontend)
    fi

    # Vision sidecar on :8000 (optional)
    if [[ -f "$REPO_ROOT/apps/vision/app/main.py" ]]; then
        if port_open 8000; then
            echo "  Vision sidecar already running on :8000 — skipping start"
        else
            echo "==> Starting vision sidecar on :8000..."
            (
                cd "$REPO_ROOT/apps/vision"
                .venv/bin/uvicorn app.main:app --port 8000
            ) &>/tmp/stacks-vision.log &
            STARTED_PIDS+=($!)
            SERVICES_STARTED+=(vision)
        fi
    fi
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    if [[ ${#STARTED_PIDS[@]} -gt 0 ]]; then
        echo ""
        echo "==> Stopping services started by this script..."
        for pid in "${STARTED_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        # Ensure ports are freed
        lsof -ti :4000 | xargs kill -9 2>/dev/null || true
        lsof -ti :4001 | xargs kill -9 2>/dev/null || true
        lsof -ti :8000 | xargs kill -9 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Wait for services ─────────────────────────────────────────────────────────
if [[ "${E2E_SERVICES:-}" != "none" ]]; then
    # Check the actual HTTP health endpoints, not just TCP port availability.
    # Phoenix opens its socket early but isn't ready to handle requests until
    # the DB pool is connected and routes are compiled — the health endpoint
    # returns 200 only when the app is fully initialised.
    wait_for_health "http://localhost:4000/api/health" "Phoenix" 120
    wait_for_health "http://localhost:4001" "Frontend" 30
    if [[ -f "$REPO_ROOT/apps/vision/app/main.py" ]]; then
        wait_for_health "http://localhost:8000/health" "Vision" 30
    fi
fi

# ── Run Playwright ────────────────────────────────────────────────────────────
echo ""
echo "==> Running Playwright E2E tests..."
(
    cd "$REPO_ROOT/e2e"
    BASE_URL="${BASE_URL:-http://localhost:4001}" npm test
)
