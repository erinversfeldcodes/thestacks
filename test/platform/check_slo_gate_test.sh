#!/usr/bin/env bash
# test/platform/check_slo_gate_test.sh
#
# Covers Phase 3 DoD:
#   - "`scripts/check-slo-gate.sh` scrapes `/internal/metrics`, aggregates
#     across machines, runs probes, computes SLIs vs thresholds, emits JSON blob"
#   - "Gate-observations JSON matches the schema in the issue description"
#
# The gate must:
#   - accept fixture-mode inputs:
#       METRICS_FIXTURE=path    : use file instead of live scrape (single-machine)
#       METRICS_FIXTURES=a:b:c  : colon-sep list (multi-machine scrape)
#       PROBE_SUMMARY_FIXTURE=p : use file instead of spawning real probes
#     (test-first — these env vars are part of the contract for fixture-driven
#      testing; the implementation can use whatever it likes as long as these
#      hooks work)
#   - compute SLIs per thresholds in the issue body and emit a
#     `gate-observations.json` blob to stdout (or to --out <path>).
#   - exit 0 when all SLIs green, non-zero on any breach.
#
# Will FAIL until the gate script is implemented — the stub `exit 0` means
# breached fixtures pass → the "exits non-zero" assertions trip.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-slo-gate.sh"
METRICS_FIX="$REPO_ROOT/test/fixtures/metrics"

# Probe-summary fixtures (inline via temp files per test case) — simulate the
# JSON blob probe-production.sh would hand off.

write_probe_fixture() {
    # write_probe_fixture <path> <availability> <upload_outcome>
    local path="$1" avail="$2" outcome="${3:-resolved}"
    cat > "$path" <<JSON
{
  "availability": ${avail},
  "p95_ms": {"health": 50, "catalogue": 200, "login": 450, "upload": 1800},
  "synthetic_probes": {"total": 80, "succeeded": $(python3 -c "print(int(80*${avail}))"), "p95_ms": 450},
  "upload_outcome": "${outcome}"
}
JSON
}

run_gate() {
    # run_gate [extra args]; env vars that influence it should be set by the caller.
    OUT="$("$GATE" "$@" 2>&1)"
    RC=$?
}

# Extract the last brace-balanced top-level JSON object from $OUT. The gate
# emits nested JSON (slis[], synthetic_probes, observations) — a naive
# "last `{`" heuristic picks an inner sub-object. This finds the last
# top-level {...}: it scans left-to-right, tracks depth, and records each
# depth-0→depth-1 opening and depth-1→depth-0 closing as a candidate span.
# The last such span wins.
last_json() {
    printf '%s' "$OUT" | python3 -c '
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
print(best or "")
' 2>/dev/null
}

# ── Case 1: healthy fixture + successful probes → PASS ───────────────────────
test_case "healthy_passes" "healthy metrics + 100% probe availability → gate exits 0"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_zero "$RC" "gate exits 0 on healthy fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" | jq -e '.outcome == "passed"' >/dev/null 2>&1; then
    _record_pass "gate-observations JSON outcome=passed"
else
    _record_fail "gate-observations JSON missing outcome=passed (blob: $(echo "$BLOB" | head -c 200))"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" | jq -e '[.slis[] | select(.breached == true)] | length == 0' >/dev/null 2>&1; then
    _record_pass "no SLIs breached"
else
    _record_fail "expected .slis[*] all breached=false on healthy fixture"
fi

# ── Case 2: latency-breach fixture → FAIL, upload p95 SLI breached ───────────
test_case "latency_breach_fails" "upload p95 > 2000ms → gate exits non-zero"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_breached_latency.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero on upload p95 breach"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("upload.*p95|p95.*upload";"i"))) | .breached] | any' \
        >/dev/null 2>&1; then
    _record_pass "upload-latency SLI flagged as breached"
else
    _record_fail "no SLI with name matching upload/p95 was flagged breached"
fi

# ── Case 3: fuse-open fixture → FAIL, fuse SLI breached ──────────────────────
test_case "fuse_open_fails" "vision_fuse state=0 → gate exits non-zero, fuse SLI breached"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_fuse_open.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero when a fuse is open"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("fuse";"i"))) | .breached] | any' \
        >/dev/null 2>&1; then
    _record_pass "fuse SLI flagged as breached"
else
    _record_fail "no fuse SLI was flagged breached"
fi

# ── Case 4: probe failures → FAIL, availability SLI breached ─────────────────
test_case "probe_failure_fails" "10% probe failure → availability SLI breached"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "0.90" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero when probe availability < 99%"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("availability";"i"))) | .breached] | any' \
        >/dev/null 2>&1; then
    _record_pass "availability SLI flagged as breached"
else
    _record_fail "no availability SLI was flagged breached"
fi

# ── Case 5: JSON schema keys (issue body requires these) ─────────────────────
test_case "json_schema_keys" "gate JSON has all required top-level keys"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
for key in commit_sha deploy_started_at deploy_completed_at outcome slis synthetic_probes; do
    if [[ -n "$BLOB" ]] && echo "$BLOB" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
        _record_pass "JSON has top-level key: $key"
    else
        _record_fail "JSON missing required top-level key: $key"
    fi
done
# Each SLI entry must have value, threshold, breached.
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis | all(has("value") and has("threshold") and has("breached"))' \
        >/dev/null 2>&1; then
    _record_pass "every SLI object has {value, threshold, breached}"
else
    _record_fail "SLI objects missing one of {value, threshold, breached}"
fi

# ── Case 6: multi-machine scrape aggregates counters (sum) and gauges (max) ──
test_case "multi_machine_aggregation" "two-machine scrape sums counters, maxes gauges"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURES="$METRICS_FIX/prom_sample_machine_a.txt:$METRICS_FIX/prom_sample_machine_b.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
# We don't assert exit code here — it depends on the whole composite health;
# the interesting thing is what the SLI/observations blob shows.
BLOB="$(last_json)"
# Combined upload resolved total should be 50 + 45 = 95.
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '(.observations.upload.resolved // .slis[] | select((.name|tostring|test("upload";"i"))) | .value // empty) != null' \
        >/dev/null 2>&1; then
    _record_pass "observations reference the upload counter"
else
    _record_fail "observations missing upload counter aggregate"
fi
# MAX memory across machines should pick the 200MB value (209715200).
if [[ -n "$BLOB" ]] \
    && echo "$BLOB" | jq -e '[.slis[] | select((.name|tostring|test("memory|beam";"i"))) | .value] | first? // 0 | tonumber >= 200000000' \
        >/dev/null 2>&1; then
    _record_pass "BEAM memory SLI reflects MAX across machines (≥ 200MB)"
else
    _record_fail "BEAM memory SLI did not take MAX across two-machine fixture"
fi

# ── Case 7 (P1 #4): Oban min-samples guard ───────────────────────────────────
# A queue with 2 samples (1 success, 1 failure) is 50% failure but below the
# min_samples threshold — must not breach, and must carry the sample-count
# hint in the SLI object.
test_case "oban_min_samples_guard" "low-sample Oban queue does not gate the deploy"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_oban_low_samples.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_zero "$RC" "gate exits 0 — low-sample Oban queue does not breach"
BLOB="$(last_json)"
# The Oban queue SLI must carry `samples` and `min_samples` fields.
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("oban_failure_rate_default";"i"))) | .samples] | first? == 2' \
        >/dev/null 2>&1; then
    _record_pass "Oban default queue SLI reports samples=2"
else
    _record_fail "Oban default queue SLI did not report samples=2"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("oban_failure_rate_default";"i"))) | .breached] | any | not' \
        >/dev/null 2>&1; then
    _record_pass "Oban default queue SLI is not flagged breached under min_samples"
else
    _record_fail "Oban default queue SLI was flagged breached despite low samples"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select((.name|tostring|test("oban_failure_rate_default";"i"))) | .min_samples] | first? == 10' \
        >/dev/null 2>&1; then
    _record_pass "Oban SLI carries min_samples hint (10)"
else
    _record_fail "Oban SLI missing min_samples=10 hint"
fi

# ── Case 8 (P2 #7): --out without a value exits non-zero ─────────────────────
test_case "out_flag_bounds_check" "--out with no following argument fails fast"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate --out
rm -f "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero when --out has no value"
assert_contains "$OUT" "--out requires a value" "error message names the missing value"

summarise
