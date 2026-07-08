#!/usr/bin/env bash
# test/platform/probe_production_test.sh
#
# Covers Phase 3 DoD: "`scripts/probe-production.sh` runs against a URL,
# prints structured summary, exits 0/non-zero on health summary".
#
# The probe script must:
#   - loop for PROBE_WINDOW_SECONDS (default 600), every PROBE_INTERVAL_SECONDS
#     (default 30) hit:
#       GET  /api/health
#       GET  /api/catalogue
#       POST /api/auth/login   (owner creds)
#       POST /api/upload       (canary, Bearer-authed from the login token)
#   - on exit, print a JSON summary (machine-readable) containing at minimum:
#       availability  : float 0..1  (non-5xx / total)
#       p95_ms        : per-probe p95 latency map
#       synthetic_probes.total / succeeded
#       per-probe status code counts
#     plus a human-readable banner with availability %.
#   - exit 0 on pass (availability ≥ 99%, login succeeded),
#     non-zero on hard failure (auth never succeeds, health never 200s, or
#     availability falls below 99% across the window).
#
# These tests launch a local Python mock server (test/fixtures/probes/mock_server.py)
# per case and point the probe at 127.0.0.1:<port>.
#
# Will FAIL until the probe script is implemented — the stub exits 0 with no
# output, so every assertion about JSON shape / availability breach will trip.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

PROBE="$REPO_ROOT/scripts/probe-production.sh"
MOCK_SERVER="$REPO_ROOT/test/fixtures/probes/mock_server.py"

# ── Pick a free high port the mock can bind to ───────────────────────────────
# We just pick one in the 40000-49999 range per test to avoid colliding if a
# previous run left a server alive.
_next_port() {
    # shellcheck disable=SC2004
    echo $((40000 + RANDOM % 10000))
}

# Start the mock server in the background, wait for it to be ready (up to 5s),
# and export MOCK_PID for the caller to kill.
_start_mock() {
    local port="$1"
    local mode="$2"
    local ratio="${3:-0.25}"
    python3 "$MOCK_SERVER" --port "$port" --mode "$mode" --fail-ratio "$ratio" \
        >/tmp/mock_stdout.$port 2>/tmp/mock_stderr.$port &
    MOCK_PID=$!
    for _ in $(seq 1 25); do
        if curl -sf --max-time 1 "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
            return 0
        fi
        if [[ "$mode" == "blackhole" ]]; then
            # Even though /api/health never responds, the socket accepts — check lsof/nc.
            if nc -z 127.0.0.1 "$port" 2>/dev/null; then
                return 0
            fi
        fi
        sleep 0.2
    done
    echo "MOCK DID NOT START on port $port (mode=$mode)" >&2
    cat /tmp/mock_stderr.$port >&2 || true
    return 1
}

_stop_mock() {
    if [[ -n "${MOCK_PID:-}" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
        MOCK_PID=""
    fi
}

# Always clean up background servers even on assertion failure / script error.
trap '_stop_mock' EXIT

# Default: short windows so the suite finishes in seconds, not minutes.
export PROBE_WINDOW_SECONDS="${PROBE_WINDOW_SECONDS:-10}"
export PROBE_INTERVAL_SECONDS="${PROBE_INTERVAL_SECONDS:-5}"

run_probe() {
    # run_probe <url>; captures stdout+stderr into $OUT and exit code into $RC.
    OUT="$("$PROBE" "$@" 2>&1)"
    RC=$?
}

# ── Case 1: healthy mock → pass, availability 100% ───────────────────────────
test_case "healthy_mock_passes" "mock returns 200 everywhere → probe exits 0"
PORT="$(_next_port)"
_start_mock "$PORT" "healthy" || { _record_fail "mock did not start"; summarise; exit $?; }
run_probe "http://127.0.0.1:${PORT}"
_stop_mock
assert_exit_zero "$RC" "probe exits 0 against an all-200 mock"
assert_contains "$OUT" "availability" "summary mentions availability"
assert_contains "$OUT" '"availability": 1' "availability is 100% (1.0) in JSON summary"
assert_contains "$OUT" "synthetic_probes" "summary has synthetic_probes block"
assert_contains "$OUT" '"succeeded"' "summary lists succeeded count"

# ── Case 2: 5xx on some requests → fail, breach recorded ─────────────────────
test_case "fail_5xx_fails" "mock returns 500 on 25% of catalogue requests"
PORT="$(_next_port)"
_start_mock "$PORT" "fail-5xx" "0.8" \
    || { _record_fail "mock did not start"; summarise; exit $?; }
run_probe "http://127.0.0.1:${PORT}"
_stop_mock
assert_exit_nonzero "$RC" "probe exits non-zero when >5% of probes 5xx"
assert_contains "$OUT" "5xx" "summary records at least one 5xx"
assert_contains "$OUT" "availability" "summary still contains an availability field"

# ── Case 2b (P1 #3): 4xx AND 5xx count as availability failures ──────────────
# Covers reviewer P1 #3: a wave of 401s must drive availability below 0.99
# just like a wave of 500s would, and both counts must appear in the summary.
test_case "fail_4xx_and_5xx_fails" "mock returns a mix of 401s and 500s on catalogue → probe fails"
PORT="$(_next_port)"
_start_mock "$PORT" "fail-4xx-and-5xx" "0.8" \
    || { _record_fail "mock did not start"; summarise; exit $?; }
run_probe "http://127.0.0.1:${PORT}"
_stop_mock
assert_exit_nonzero "$RC" "probe exits non-zero when availability dips below 0.99"
assert_contains "$OUT" "http_4xx_count" "summary surfaces http_4xx_count field"
assert_contains "$OUT" "http_5xx_count" "summary surfaces http_5xx_count field"
# Availability in the JSON must be strictly less than 1.0 on this fixture.
JSON_LINE="$(printf '%s' "$OUT" | grep -o 'probe-summary-json: {.*}' | head -1 | sed 's/^probe-summary-json: //')"
if [[ -n "$JSON_LINE" ]] \
    && echo "$JSON_LINE" | jq -e '.availability < 1.0' >/dev/null 2>&1; then
    _record_pass "availability dropped below 1.0 on mixed 4xx/5xx"
else
    _record_fail "availability did not drop below 1.0 (JSON: $(echo "$JSON_LINE" | head -c 200))"
fi
# http_4xx_count > 0 in the summary.
if [[ -n "$JSON_LINE" ]] \
    && echo "$JSON_LINE" | jq -e '.synthetic_probes.http_4xx_count > 0' >/dev/null 2>&1; then
    _record_pass "http_4xx_count > 0 in summary"
else
    _record_fail "http_4xx_count was not > 0 in summary (JSON: $(echo "$JSON_LINE" | head -c 200))"
fi

# ── Case 3: blackhole → timeouts → fail ──────────────────────────────────────
test_case "blackhole_fails" "mock never responds → probe exits non-zero with timeouts"
PORT="$(_next_port)"
_start_mock "$PORT" "blackhole" \
    || { _record_fail "mock did not start"; summarise; exit $?; }
run_probe "http://127.0.0.1:${PORT}"
_stop_mock
assert_exit_nonzero "$RC" "probe exits non-zero when every request times out"
assert_contains "$OUT" "timeout" "summary notes the timeouts (word 'timeout' appears)"

# ── Case 4: short-window mode produces ≈3 samples in ~10s ────────────────────
# With PROBE_WINDOW_SECONDS=10 and PROBE_INTERVAL_SECONDS=5, we expect samples
# at t=0, t=5, t=10 → 3 samples per probe (4 probes × 3 = 12 total).
test_case "short_window_samples" "WINDOW=10s INTERVAL=5s produces ≈3 samples"
PORT="$(_next_port)"
_start_mock "$PORT" "healthy" \
    || { _record_fail "mock did not start"; summarise; exit $?; }
START_TIME="$(date +%s)"
PROBE_WINDOW_SECONDS=10 PROBE_INTERVAL_SECONDS=5 run_probe "http://127.0.0.1:${PORT}"
END_TIME="$(date +%s)"
_stop_mock
ELAPSED=$((END_TIME - START_TIME))
assert_exit_zero "$RC" "short-window probe exits 0 against healthy mock"
# Expect the window to be honoured within a couple seconds of slop.
if [[ "$ELAPSED" -ge 8 && "$ELAPSED" -le 18 ]]; then
    _record_pass "short-window ran for ~10s (actual: ${ELAPSED}s)"
else
    _record_fail "short-window elapsed=${ELAPSED}s — expected 8..18s"
fi
# Count hits on the mock's request log. Three samples × four probes = 12.
REQ_LOG="/tmp/mock_stdout.${PORT}"
if [[ -f "$REQ_LOG" ]]; then
    HEALTH_HITS=$(grep -c '"path": "/api/health"' "$REQ_LOG" || echo 0)
    if [[ "$HEALTH_HITS" -ge 2 && "$HEALTH_HITS" -le 4 ]]; then
        _record_pass "health probe fired ~3 times (got ${HEALTH_HITS})"
    else
        _record_fail "health probe fired ${HEALTH_HITS} times — expected 2..4"
    fi
else
    _record_fail "mock stdout log missing at $REQ_LOG"
fi

# ── Case 5: output contract — required JSON keys ─────────────────────────────
test_case "json_contract" "summary JSON has required keys"
PORT="$(_next_port)"
_start_mock "$PORT" "healthy" \
    || { _record_fail "mock did not start"; summarise; exit $?; }
run_probe "http://127.0.0.1:${PORT}"
_stop_mock
# Extract the last JSON object from OUT. The probe is expected to emit its
# final summary either as pretty-printed JSON or a single JSON line. We use
# python3 to find the final brace-balanced object and jq to validate keys.
JSON_EXTRACT="$(printf '%s' "$OUT" | python3 -c '
import sys
text = sys.stdin.read()
best = None
depth = 0
start = -1
for i, ch in enumerate(text):
    if ch == "{":
        if depth == 0:
            start = i
        depth += 1
    elif ch == "}":
        if depth > 0:
            depth -= 1
            if depth == 0 and start >= 0:
                best = text[start:i+1]
                start = -1
if best:
    print(best)
' 2>/dev/null)"
assert_contains "$JSON_EXTRACT" "availability" "final JSON includes availability"
assert_contains "$JSON_EXTRACT" "p95_ms" "final JSON includes per-probe p95_ms"
assert_contains "$JSON_EXTRACT" "synthetic_probes" "final JSON includes synthetic_probes block"
# Also check that jq can parse it as a whole document (catches trailing commas).
if [[ -n "$JSON_EXTRACT" ]] && echo "$JSON_EXTRACT" | jq -e . >/dev/null 2>&1; then
    _record_pass "final JSON blob parses as valid JSON"
else
    _record_fail "final JSON blob does not parse — probe is not emitting valid JSON"
fi

summarise
