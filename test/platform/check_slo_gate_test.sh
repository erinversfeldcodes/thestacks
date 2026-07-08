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
test_case "latency_breach_fails" "upload p95 > 30000ms → gate exits non-zero"
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

# ── db_pool_queue_p95_ms min_samples guard + per-repo split ─────────────────
# Same min_samples pattern as Oban: on low-volume deploys (~20 Core.Repo
# queries over the 10-min gate window) p95 noise should not gate the deploy.
# Two SLIs now — one per repo — with per-repo thresholds.
test_case "db_pool_queue_per_repo_split" \
    "db_pool_queue_p95_ms and oban_repo_queue_p95_ms both emit with samples + min_samples"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
# Core.Repo SLI — fixture has 3000 samples, well above min_samples=50.
# All samples fall into le<=10 so p95 interpolates to ≤10ms (not breached).
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select(.name == "db_pool_queue_p95_ms") | .samples] | first? == 3000' \
        >/dev/null 2>&1; then
    _record_pass "db_pool_queue_p95_ms reports Core.Repo samples=3000"
else
    _record_fail "db_pool_queue_p95_ms did not report Core.Repo samples=3000"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select(.name == "db_pool_queue_p95_ms") | .min_samples] | first? == 50' \
        >/dev/null 2>&1; then
    _record_pass "db_pool_queue_p95_ms carries min_samples=50 hint"
else
    _record_fail "db_pool_queue_p95_ms missing min_samples=50 hint"
fi
# ObanRepo SLI — fixture has no Core.ObanRepo rows, so samples=0 and the
# SLI is marked non-gating under min_samples (not breached).
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select(.name == "oban_repo_queue_p95_ms") | .samples] | first? == 0' \
        >/dev/null 2>&1; then
    _record_pass "oban_repo_queue_p95_ms emitted with samples=0 when fixture has no ObanRepo rows"
else
    _record_fail "oban_repo_queue_p95_ms missing or reporting non-zero samples on Core.Repo-only fixture"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select(.name == "oban_repo_queue_p95_ms") | .breached] | any | not' \
        >/dev/null 2>&1; then
    _record_pass "oban_repo_queue_p95_ms not breached when below min_samples"
else
    _record_fail "oban_repo_queue_p95_ms flagged breached despite samples=0"
fi

# ── Case 8 (Issue #140): real PromEx scrape produces non-zero SLI values ─────
# Anchors the parser against the real metric-name shape that PromEx 1.11
# emits. If a future refactor silently drifts back to a non-existent metric
# name (as #140 did before the fix), these assertions flip to zero and the
# gate false-passes. Guard that by asserting the healthy fixture — which is
# now derived from a real PromEx scrape — produces strictly positive values
# for every SLI that reads a PromEx built-in series.
test_case "real_scrape_produces_nonzero_slis" \
    "healthy real-scrape fixture yields non-zero BEAM memory, DB pool p95, and Oban samples"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
assert_slis_value_gt() {
    # assert_slis_value_gt <sli-name> <threshold> <message>
    local sli="$1" threshold="$2" msg="$3"
    local actual
    actual="$(echo "$BLOB" | jq -r --arg n "$sli" \
        '.slis[] | select(.name == $n) | .value' 2>/dev/null)"
    if [[ -n "$actual" ]] && python3 -c "
import sys
try:
    v = float('$actual')
except ValueError:
    sys.exit(1)
sys.exit(0 if v > $threshold else 1)
" 2>/dev/null; then
        _record_pass "$msg (value=$actual)"
    else
        _record_fail "$msg (value=$actual not > $threshold)"
    fi
}
assert_slis_samples_gt() {
    local sli="$1" threshold="$2" msg="$3"
    local actual
    actual="$(echo "$BLOB" | jq -r --arg n "$sli" \
        '.slis[] | select(.name == $n) | .samples // 0' 2>/dev/null)"
    if [[ -n "$actual" ]] && [[ "$actual" -gt "$threshold" ]]; then
        _record_pass "$msg (samples=$actual)"
    else
        _record_fail "$msg (samples=$actual not > $threshold)"
    fi
}
assert_slis_value_gt "beam_memory_bytes" 0 \
    "BEAM memory bytes is non-zero on real-scrape-shaped fixture"
assert_slis_value_gt "beam_memory_mb" 0 \
    "BEAM memory MB is non-zero on real-scrape-shaped fixture"
# db_pool_queue_p95 could be 0 if every sample is in the first bucket; with
# the baked fixture (50 samples above the le=10 bucket) it interpolates > 0.
assert_slis_value_gt "db_pool_queue_p95_ms" 0 \
    "DB pool queue p95 is non-zero on real-scrape-shaped fixture"
assert_slis_value_gt "auth_p95_ms" 0 \
    "auth route p95 is non-zero on real-scrape-shaped fixture"
assert_slis_value_gt "catalogue_p95_ms" 0 \
    "catalogue route p95 is non-zero on real-scrape-shaped fixture"
assert_slis_value_gt "upload_p95_ms" 0 \
    "upload route p95 is non-zero on real-scrape-shaped fixture"
# Oban queues — `samples` must include both success (processing_duration) and
# failure (exception_duration) counts pulled from the two distinct
# distribution families PromEx emits.
assert_slis_samples_gt "oban_failure_rate_default" 0 \
    "Oban default queue reports non-zero samples on real-scrape-shaped fixture"
assert_slis_samples_gt "oban_failure_rate_uploads" 0 \
    "Oban uploads queue reports non-zero samples on real-scrape-shaped fixture"

# ── Case 9 (Issue #140): verbatim real PromEx capture also parses cleanly ────
# The raw `prom_sample_real_scrape.txt` is the exact (sanitised) output from
# a `PromEx.get_metrics(Core.PromEx)` call — no hand-curation of fixture
# values. If this parses without crashing and surfaces non-zero BEAM memory,
# the parser is aligned with PromEx's live format (including Erlang's
# scientific-notation floats like `1.2e3`).
test_case "real_scrape_raw_capture_parses" \
    "raw PromEx capture parses and produces non-zero BEAM memory"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_real_scrape.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" | jq -e '.outcome' >/dev/null 2>&1; then
    _record_pass "parser processed the raw PromEx scrape without error"
else
    _record_fail "parser failed to process the raw PromEx scrape"
fi
assert_slis_value_gt "beam_memory_bytes" 0 \
    "BEAM memory bytes is non-zero on raw PromEx capture"

# ── Case 10: real 5xx rate SLI gates on Phoenix http_requests_total ──────────
# Fixture adds 60 5xx responses (status=500 + 503) to two routes on top of
# 2600 healthy 200s. Expected rate ≈ 60/2660 = 2.26%, well over the 0.5%
# threshold and above HTTP_MIN_SAMPLES=50. Healthy fixture already covered
# by Case 1 (real_5xx_rate=0 → not breached).
test_case "real_5xx_rate_breach_fails" \
    "≥0.5% 5xx rate over HTTP_MIN_SAMPLES samples → real_5xx_rate breach"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_breached_5xx.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero when real 5xx rate breaches"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '[.slis[] | select(.name=="real_5xx_rate") | .breached] | all' \
        >/dev/null 2>&1; then
    _record_pass "real_5xx_rate SLI flagged as breached"
else
    _record_fail "real_5xx_rate SLI not flagged breached on breached_5xx fixture"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="real_5xx_rate") | .samples >= 50' \
        >/dev/null 2>&1; then
    _record_pass "real_5xx_rate samples clear the min_samples floor"
else
    _record_fail "real_5xx_rate samples below min_samples floor; test fixture too small"
fi

# ── Case 11: healthy real-scrape real_5xx_rate is not flagged ────────────────
# Sanity: the healthy fixture should produce a non-breached real_5xx_rate
# with samples well above HTTP_MIN_SAMPLES and value 0.0.
test_case "real_5xx_rate_healthy_not_breached" \
    "healthy fixture has no 5xxes → real_5xx_rate passes"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="real_5xx_rate") | .value == 0 and .breached == false' \
        >/dev/null 2>&1; then
    _record_pass "real_5xx_rate=0 and not breached on healthy fixture"
else
    _record_fail "real_5xx_rate non-zero or breached on healthy fixture"
fi

# ── Case 12: blind scrape (empty fixture) breaches metrics_scrape_healthy ────
# Reproduces the 2026-04-19 first-prod-deploy false-pass, where a bearer-token
# mismatch caused every /internal/metrics scrape to return 401 → 0-byte file
# → every metric-derived SLI computed to 0 → every one-sided threshold passed.
# The metrics_scrape_healthy sentinel must breach on empty input regardless
# of which specific observation channel broke.
test_case "blind_scrape_breaches_liveness" \
    "empty fixture → metrics_scrape_healthy breach + gate exits non-zero"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
empty_fixture="$(mktemp)"
: > "$empty_fixture"
METRICS_FIXTURE="$empty_fixture" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture" "$empty_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero on empty scrape fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="metrics_scrape_healthy") | .breached == true' \
        >/dev/null 2>&1; then
    _record_pass "metrics_scrape_healthy flagged as breached on empty scrape"
else
    _record_fail "metrics_scrape_healthy did not breach on empty scrape"
fi
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="upload_success_rate") | (.samples == 0 and .breached == false and has("note"))' \
        >/dev/null 2>&1; then
    _record_pass "upload_success_rate stays non-gating below min_samples"
else
    _record_fail "upload_success_rate should not gate with zero samples"
fi

# ── Case 13: healthy fixture satisfies metrics_scrape_healthy ────────────────
test_case "healthy_scrape_liveness_ok" \
    "healthy fixture → metrics_scrape_healthy value=1"
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$METRICS_FIX/prom_sample_healthy.txt" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$probe_fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="metrics_scrape_healthy") | .value == 1 and .breached == false' \
        >/dev/null 2>&1; then
    _record_pass "metrics_scrape_healthy=1 on healthy fixture"
else
    _record_fail "metrics_scrape_healthy should be 1 on healthy fixture"
fi

# ── Case 14: upload SLI treats `rejected` as pipeline-healthy ────────────────
# Reproduces the 2026-04-19 prod false-positive where every upload in the
# gate window was a not-a-book canary (outcome=rejected). The old SLI
# formula (resolved / total) reported 0.0 and breached; the new formula
# ((resolved + rejected) / (resolved + rejected + timeout)) must stay
# green because `rejected` is a healthy pipeline outcome (vision worked,
# correctly classified as not-a-book). Only `timeout` counts as failure.
test_case "upload_rejected_counts_as_healthy" \
    "fixture with rejected>0 and timeout=0 → upload_success_rate green"
rejected_fixture="$(mktemp)"
cat > "$rejected_fixture" <<'EOF'
# HELP stacks_upload_terminal_count_total Upload pipeline terminal outcomes.
# TYPE stacks_upload_terminal_count_total counter
stacks_upload_terminal_count_total{outcome="resolved"} 0
stacks_upload_terminal_count_total{outcome="rejected"} 20
stacks_upload_terminal_count_total{outcome="timeout"} 0
# HELP core_prom_ex_beam_memory_processes_total_bytes Memory allocated to :processes.
# TYPE core_prom_ex_beam_memory_processes_total_bytes gauge
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$rejected_fixture" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$rejected_fixture" "$probe_fixture"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="upload_success_rate") | (.value == 1.0 and .breached == false)' \
        >/dev/null 2>&1; then
    _record_pass "upload_success_rate=1.0 and not breached with only rejected outcomes"
else
    _record_fail "upload_success_rate should be 1.0 when all terminals are rejected (no timeouts)"
fi

# ── Case 15: upload SLI breaches when timeout rate exceeds threshold ─────────
# Positive check — the SLI must still gate on pipeline hangs. Fixture:
# 5 resolved + 5 rejected + 3 timeout → (10 / 13) = 0.77, below the 0.90
# threshold. The SLI should breach loudly.
test_case "upload_timeout_breaches" \
    "fixture with timeout > 10% of terminals → upload_success_rate breaches"
timeout_fixture="$(mktemp)"
cat > "$timeout_fixture" <<'EOF'
# HELP stacks_upload_terminal_count_total Upload pipeline terminal outcomes.
# TYPE stacks_upload_terminal_count_total counter
stacks_upload_terminal_count_total{outcome="resolved"} 5
stacks_upload_terminal_count_total{outcome="rejected"} 5
stacks_upload_terminal_count_total{outcome="timeout"} 3
# HELP core_prom_ex_beam_memory_processes_total_bytes Memory allocated to :processes.
# TYPE core_prom_ex_beam_memory_processes_total_bytes gauge
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF
probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIXTURE="$timeout_fixture" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$timeout_fixture" "$probe_fixture"
assert_exit_nonzero "$RC" "gate exits non-zero when timeout rate breaches"
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="upload_success_rate") | (.breached == true and .value < 0.90)' \
        >/dev/null 2>&1; then
    _record_pass "upload_success_rate correctly breaches on timeout-heavy fixture"
else
    _record_fail "upload_success_rate should breach when (resolved+rejected)/total < 0.90"
fi

# ── Case 17: windowed p95 excludes pre-gate histogram samples ────────────────
# Regression guard for "cumulative-histogram p95 pollutes the gate measurement
# with pre-gate samples" — e.g. 8-minute SSE streams from deploy warmup would
# previously live in the top-5% tail and blow `upload_p95_ms` on an otherwise-
# healthy gate. With windowing, only samples that arrived between the first
# and last gate scrapes count; pre-gate traffic is subtracted out.
#
# Fixture design:
#   first snapshot: 100 slow samples already in the histogram (le=5000), plus
#                   5 very slow samples (le=+Inf).
#   last snapshot:  same 100 slow + 5 very slow (unchanged from first) PLUS
#                   50 fast samples (le=50). During the gate window only fast
#                   traffic landed; the pre-gate tail must NOT pull p95 up.
test_case "windowed_p95_excludes_pre_gate" \
    "first+last scrape delta excludes pre-gate histogram samples"

first_scrape="$(mktemp)"
cat > "$first_scrape" <<'EOF'
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="50"} 0
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="500"} 0
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="2000"} 0
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="5000"} 100
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="+Inf"} 105
stacks_router_dispatch_stop_duration_milliseconds_sum{route_group="upload"} 2000000
stacks_router_dispatch_stop_duration_milliseconds_count{route_group="upload"} 105
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF

last_scrape="$(mktemp)"
cat > "$last_scrape" <<'EOF'
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="50"} 50
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="500"} 50
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="2000"} 50
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="5000"} 150
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="+Inf"} 155
stacks_router_dispatch_stop_duration_milliseconds_sum{route_group="upload"} 2002500
stacks_router_dispatch_stop_duration_milliseconds_count{route_group="upload"} 155
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF

probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIRST_FIXTURE="$first_scrape" \
METRICS_FIXTURE="$last_scrape" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$first_scrape" "$last_scrape" "$probe_fixture"

# Without windowing: p95 is in [2000, 5000] with cumulative=155 → interpolates
# to ~4000ms (blown).
# With windowing: 50 windowed samples, all in [0, 50] → p95 ≤ 50ms.
BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="upload_p95_ms") | .value <= 100' \
        >/dev/null 2>&1; then
    _record_pass "upload_p95_ms reflects windowed delta (≤100ms, fast samples only)"
else
    _record_fail "upload_p95_ms did not reflect windowing (expected ≤100, got $(echo "$BLOB" | jq '.slis[] | select(.name=="upload_p95_ms") | .value'))"
fi
assert_exit_zero "$RC" "gate passes when windowed p95 is fast"

# ── Case 18: machine-swap clamp ──────────────────────────────────────────────
# If last-scrape cumulative < first-scrape cumulative (e.g. Fly proxy served
# scrapes from two machines with independent counters, or BEAM restarted
# mid-window), the raw delta is negative. Python clamps to 0; the resulting
# windowed SLI should not breach on bogus negative counts.
test_case "windowed_machine_swap_clamps_to_zero" \
    "negative delta (machine swap) clamps to zero instead of producing noise"

first_scrape="$(mktemp)"
cat > "$first_scrape" <<'EOF'
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="50"} 200
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="+Inf"} 200
stacks_router_dispatch_stop_duration_milliseconds_sum{route_group="upload"} 4000
stacks_router_dispatch_stop_duration_milliseconds_count{route_group="upload"} 200
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF

last_scrape="$(mktemp)"
cat > "$last_scrape" <<'EOF'
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="50"} 10
stacks_router_dispatch_stop_duration_milliseconds_bucket{route_group="upload",le="+Inf"} 10
stacks_router_dispatch_stop_duration_milliseconds_sum{route_group="upload"} 200
stacks_router_dispatch_stop_duration_milliseconds_count{route_group="upload"} 10
core_prom_ex_beam_memory_processes_total_bytes 100000000
EOF

probe_fixture="$(mktemp)"
write_probe_fixture "$probe_fixture" "1.0" "resolved"
METRICS_FIRST_FIXTURE="$first_scrape" \
METRICS_FIXTURE="$last_scrape" \
PROBE_SUMMARY_FIXTURE="$probe_fixture" \
    run_gate
rm -f "$first_scrape" "$last_scrape" "$probe_fixture"

BLOB="$(last_json)"
if [[ -n "$BLOB" ]] && echo "$BLOB" \
    | jq -e '.slis[] | select(.name=="upload_p95_ms") | .value == 0' \
        >/dev/null 2>&1; then
    _record_pass "windowed p95=0 on machine-swap (negative delta clamped)"
else
    _record_fail "machine-swap clamp failed — got $(echo "$BLOB" | jq '.slis[] | select(.name=="upload_p95_ms") | .value')"
fi

# ── Case 16 (P2 #7): --out without a value exits non-zero ────────────────────
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
