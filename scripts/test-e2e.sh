#!/usr/bin/env bash
# scripts/test-e2e.sh — start all services and run Playwright E2E tests.
#
# In CI (or any fresh environment) this script:
#   1. Starts Phoenix on :4000 with a live DB
#   2. Serves the pre-built Elm frontend on :4001
#   3. Starts the vision service locally on :8000 (if present; in production this is Modal)
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

# ── Modal app name resolution ─────────────────────────────────────────────────
# The local vision service calls a Modal deployment for GPU inference.
# MODAL_APP_NAME must point at a live Modal deployment — typically the ephemeral
# preview app that matches the current branch. If not set, derive it from the
# current git branch using the same sanitization logic as deploy-stack.sh.
if [[ -z "${MODAL_APP_NAME:-}" ]]; then
    _BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
    _SANITISED="$(echo "$_BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | cut -c1-28)"
    export MODAL_APP_NAME="thestacks-vision-${_SANITISED}"
    echo "  MODAL_APP_NAME not set — derived from branch: ${MODAL_APP_NAME}"
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

# warm_remote_preview
# Guard against cold-start 502s on the deployed preview (Issue #175). The preview
# core app runs with auto_stop_machines = true and can go cold between the deploy
# warmup and Playwright's `setup` project (auth.setup.ts) making its first login —
# yielding an HTTP 502 that fails the whole E2E gate.
#
# The gate is purely "is there a remote URL to warm?": when BASE_URL is set we
# poll the preview's health endpoint until it returns 200 (reusing
# wait_for_health, which fails fast with a clear message and non-zero exit after
# the bound). When BASE_URL is unset there is nothing remote to warm — regardless
# of E2E_SERVICES (including the "run against an already-running local stack"
# mode, E2E_SERVICES=none with no BASE_URL) — so this is a strict no-op. This
# matches the globalSetup guard, which is likewise BASE_URL-only.
warm_remote_preview() {
    # No remote target to warm (local run) → strict no-op.
    if [[ -z "${BASE_URL:-}" ]]; then
        return 0
    fi
    echo "==> Remote mode: warming ${BASE_URL}/api/health before setup..."
    wait_for_health "${BASE_URL}/api/health" "Preview" 60
}

# ── Install E2E deps if needed ─────────────────────────────────────────────────
if [[ ! -d "$REPO_ROOT/e2e/node_modules" ]]; then
    echo "==> Installing E2E dependencies..."
    (cd "$REPO_ROOT/e2e" && npm ci)
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

    # Phoenix on :4000 (serves both API and the pre-built Elm frontend via Plug.Static)
    if port_open 4000; then
        echo "  Phoenix already running on :4000 — skipping start"
    else
        echo "==> Starting Phoenix on :4000..."
        (
            cd "$REPO_ROOT"
            # Age-gating ships dark (ADR-020) — default OFF outside :test. The
            # age-gate E2E specs exercise ENFORCEMENT, which reads
            # Stacks.FeatureFlags.age_gating_enabled? (env AGE_GATING_ENABLED).
            # Turn it on for this local/CI Phoenix so the age-gate suite is live.
            #
            # STACKS_E2E_TEST_HELPERS=1 exposes the /api/test/* helper endpoints
            # (confirmation-token, sent-emails, age-verification) the full-flow
            # specs need — without it every helper-gated spec silently test.skips
            # (confirm-email full flow, password-reset). The preview stack sets
            # this via deploy-stack.sh; the local Phoenix must set it too.
            AGE_GATING_ENABLED=true STACKS_E2E_TEST_HELPERS=1 MIX_ENV=dev mix phx.server
        ) &>/tmp/stacks-phoenix.log &
        STARTED_PIDS+=($!)
        SERVICES_STARTED+=(phoenix)
    fi

    # Vision service on :8000 (optional — local dev only; in CI/production this is Modal)
    # Always kill any existing process on :8000 before starting — a stale process may be
    # running with a different VISION_HMAC_SECRET and would cause every upload to 401.
    if [[ -f "$REPO_ROOT/apps/vision/app/main.py" ]]; then
        if port_open 8000; then
            echo "  Killing stale process on :8000 before starting fresh vision service..."
            lsof -ti :8000 | xargs kill -9 2>/dev/null || true
            sleep 1
        fi
        echo "==> Starting vision service on :8000..."
        (
            cd "$REPO_ROOT/apps/vision"
            .venv/bin/uvicorn app.main:app --port 8000
        ) &>/tmp/stacks-vision.log &
        STARTED_PIDS+=($!)
        SERVICES_STARTED+=(vision)
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
    if [[ -f "$REPO_ROOT/apps/vision/app/main.py" ]]; then
        wait_for_health "http://localhost:8000/health" "Vision" 30
    fi
fi

# ── Clear stale auth storage state ───────────────────────────────────────────
# Auth storage state files (.auth/*.json) are keyed to the origin (base URL).
# If a previous run targeted a different URL (e.g. fly.dev preview), the stale
# files will have the wrong origin and all authenticated tests will fail.
# Always delete them so auth.setup.ts generates fresh files for the current URL.
echo ""
echo "==> Clearing stale auth storage state..."
rm -rf "$REPO_ROOT/e2e/.auth/"
mkdir -p "$REPO_ROOT/e2e/.auth"

# ── Warm the remote preview before the setup project runs ────────────────────
# No-op locally; in remote mode this blocks until the (possibly cold) preview
# returns 200 so auth.setup.ts's first login doesn't hit a 502.
warm_remote_preview

# ── Run Playwright ────────────────────────────────────────────────────────────
echo ""
echo "==> Running Playwright E2E tests..."
(
    cd "$REPO_ROOT/e2e"
    BASE_URL="${BASE_URL:-http://localhost:4000}" npm test
)
