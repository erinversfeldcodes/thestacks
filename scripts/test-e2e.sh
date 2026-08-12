#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$REPO_ROOT/scripts/check-e2e-vacuous-guards.sh"

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

if [[ -z "${MODAL_APP_NAME:-}" ]]; then
    _BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
    _SANITISED="$(echo "$_BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | cut -c1-28)"
    export MODAL_APP_NAME="thestacks-vision-${_SANITISED}"
    echo "  MODAL_APP_NAME not set — derived from branch: ${MODAL_APP_NAME}"
fi

# shellcheck source=scripts/lib/postgres.sh
source "$REPO_ROOT/scripts/lib/postgres.sh"

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
    done
    echo "  $name healthy at $url"
}

port_open() {
    nc -z localhost "$1" 2>/dev/null
}

# warm_remote_preview
# Guard against cold-start 502s on the deployed preview. The preview
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
    if [[ -z "${BASE_URL:-}" ]]; then
        return 0
    fi
    echo "==> Remote mode: warming ${BASE_URL}/api/health before setup..."
    wait_for_health "${BASE_URL}/api/health" "Preview" 60

    # A passing GET /api/health does NOT prove the POST path is warm. On a
    # boundary cold-start the machine can answer health while the first login
    # POST still 502s as fly-proxy finishes waking it (stability
    # finding #2 — a plain health warm was insufficient). auth.setup.ts's very
    # first action is a login POST, so warm THAT path here: poll
    # /api/auth/login until it returns any non-502 status (200 or 401 both mean
    # the app actually served the request) so the setup project never races the
    # wake. Bogus credentials are fine — a 401 proves the POST path is up.
    echo "==> Remote mode: warming the login POST path (${BASE_URL}/api/auth/login)..."
    local deadline=$(( $(date +%s) + 60 ))
    local code=""
    while [[ $(date +%s) -lt $deadline ]]; do
        code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -X POST "${BASE_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d '{"email":"warmup@thestacks.test","password":"warmup"}' 2>/dev/null || true)"
        if [[ -n "$code" && "$code" != "502" && "$code" != "000" ]]; then
            echo "  Login POST path warm (HTTP ${code})."
            return 0
        fi
        echo "  Login POST not warm yet (HTTP ${code:-none}) — retrying in 3s..."
        sleep 3
    done
    echo "  WARNING: login POST path still returning ${code:-no response} after 60s —" >&2
    echo "           proceeding; globalSetup re-checks health and Playwright retries the setup project." >&2
}

if [[ ! -d "$REPO_ROOT/e2e/node_modules" ]]; then
    echo "==> Installing E2E dependencies..."
    (cd "$REPO_ROOT/e2e" && npm ci)
fi

if [[ ! -d "$HOME/.cache/ms-playwright" && ! -d "$HOME/Library/Caches/ms-playwright" ]]; then
    echo "==> Installing Playwright browsers..."
    (cd "$REPO_ROOT/e2e" && npx playwright install --with-deps chromium)
fi

SERVICES_STARTED=()
STARTED_PIDS=()

if [[ "${E2E_SERVICES:-}" != "none" ]]; then
    ensure_postgres

    if port_open 4000; then
        echo "  Phoenix already running on :4000 — skipping start"
    else
        echo "==> Starting Phoenix on :4000..."
        (
            cd "$REPO_ROOT"
            AGE_GATING_ENABLED=true STACKS_E2E_TEST_HELPERS=1 MIX_ENV=dev mix phx.server
        ) &>/tmp/stacks-phoenix.log &
        STARTED_PIDS+=($!)
        SERVICES_STARTED+=(phoenix)
    fi

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

cleanup() {
    if [[ ${#STARTED_PIDS[@]} -gt 0 ]]; then
        echo ""
        echo "==> Stopping services started by this script..."
        for pid in "${STARTED_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        lsof -ti :4000 | xargs kill -9 2>/dev/null || true
        lsof -ti :8000 | xargs kill -9 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

echo ""
echo "==> Clearing stale auth storage state..."
rm -rf "$REPO_ROOT/e2e/.auth/"
mkdir -p "$REPO_ROOT/e2e/.auth"

# ── Warm the remote preview before the setup project runs ────────────────────
# No-op locally; in remote mode this blocks until the (possibly cold) preview
# returns 200 so auth.setup.ts's first login doesn't hit a 502.
warm_remote_preview

echo ""
echo "==> Running Playwright E2E tests..."
(
    cd "$REPO_ROOT/e2e"
    BASE_URL="${BASE_URL:-http://localhost:4000}" npm test
)
