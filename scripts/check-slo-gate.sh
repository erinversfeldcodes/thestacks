#!/usr/bin/env bash
# scripts/check-slo-gate.sh — 10-min SLO gate for post-deploy health.
#
# Modes:
#   production: scrape `/internal/metrics` every 60s for PROBE_WINDOW_SECONDS,
#               run probe-production.sh in parallel, then compute SLIs from
#               the WINDOW DELTA between the first and last successful
#               scrapes. Pre-gate samples (deploy warmup, late-finishing
#               previous-deploy jobs) are excluded because Prometheus
#               histograms/counters are cumulative since BEAM start — a
#               raw last-scrape value conflates those with in-window traffic.
#               Gauges (fuse state, BEAM memory) still use last-scrape
#               values directly since "delta" isn't meaningful for them.
#   test:       when METRICS_FIXTURE / METRICS_FIXTURES + PROBE_SUMMARY_FIXTURE
#               are set, skip the live scrape + probe launch and read those
#               fixtures directly. An optional METRICS_FIRST_FIXTURE /
#               METRICS_FIRST_FIXTURES can supply the window's first
#               snapshot; when absent, the first snapshot is treated as
#               all zeros (windowed == cumulative, backward compatible).
#
# Aggregation: SUM counters (upload terminals, Oban outcomes, Phoenix status),
#              MAX gauges (BEAM memory, fuse state is boolean-combined: 0 if any
#              machine reports fuse open).
#
# Emits a gate-observations JSON object to stdout. Keys:
#   commit_sha, deploy_started_at, deploy_completed_at, outcome,
#   slis (list of {name, value, threshold, breached}),
#   synthetic_probes (forwarded from probe summary),
#   observations (misc raw counters for debugging).
#
# Min-samples floors (rate SLIs don't gate below these):
#   Oban per-queue failure rate: 10 samples (OBAN_MIN_SAMPLES)
#   Real traffic 5xx rate:       50 samples (HTTP_MIN_SAMPLES)
# Below the floor, the SLI emits `samples`, `min_samples`, and a `note`
# field explaining why it isn't gating.
#
# Exit 0 iff every SLI has breached=false; non-zero otherwise.
#
# Environment:
#   CORE_APP, COMMIT_SHA, METRICS_SCRAPE_TOKEN, DEPLOY_STARTED_AT
#   PROBE_WINDOW_SECONDS (default 600)
#   METRICS_FIXTURE=<path>           test mode: single fixture
#   METRICS_FIXTURES=<a>:<b>:...     test mode: multi-machine fixture list
#   PROBE_SUMMARY_FIXTURE=<path>     test mode: pre-baked probe summary JSON

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Parse args ───────────────────────────────────────────────────────────────
OUT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            # Reviewer P2 #7: `--out` at end-of-argv previously indexed $2
            # under `set -u`, aborting with a cryptic "unbound variable".
            [[ $# -ge 2 ]] || { echo "FAIL: --out requires a value" >&2; exit 2; }
            OUT_PATH="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done

# ── Test-mode fast path ──────────────────────────────────────────────────────
# If fixture env vars are set, skip all live scraping / probe spawning.
#
# METRIC_FILES is the last-scrape(s); METRIC_FIRST_FILES is the first-scrape(s).
# Histogram/counter SLIs are computed from the WINDOW delta (last - first), not
# cumulative-since-BEAM-start values. Gauges (fuse state, BEAM memory) use
# last-scrape values directly. If METRIC_FIRST_FIXTURE* is not set, the first
# scrape is treated as empty (all counters at zero), which means the delta ==
# the raw last-scrape values — a backward-compatible fallback that keeps single-
# snapshot test fixtures working without modification.
TEST_MODE=0
METRIC_FILES=()
METRIC_FIRST_FILES=()
if [[ -n "${METRICS_FIXTURE:-}" ]]; then
    TEST_MODE=1
    METRIC_FILES=("$METRICS_FIXTURE")
elif [[ -n "${METRICS_FIXTURES:-}" ]]; then
    TEST_MODE=1
    IFS=':' read -r -a METRIC_FILES <<< "$METRICS_FIXTURES"
fi
if [[ -n "${METRICS_FIRST_FIXTURE:-}" ]]; then
    METRIC_FIRST_FILES=("$METRICS_FIRST_FIXTURE")
elif [[ -n "${METRICS_FIRST_FIXTURES:-}" ]]; then
    IFS=':' read -r -a METRIC_FIRST_FILES <<< "$METRICS_FIRST_FIXTURES"
fi

# ── Production mode: live scrape ─────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

DEPLOY_STARTED_AT="${DEPLOY_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [[ "$TEST_MODE" -eq 0 ]]; then
    : "${CORE_APP:?CORE_APP required in production mode}"
    : "${METRICS_SCRAPE_TOKEN:?METRICS_SCRAPE_TOKEN required in production mode}"

    WINDOW="${PROBE_WINDOW_SECONDS:-600}"
    SCRAPE_INTERVAL=60

    # Kick off probe-production.sh in the background, piping its output into
    # WORK_DIR/probe-output.log. Base URL = https://$CORE_APP.fly.dev.
    PROBE_BASE_URL="${PROBE_BASE_URL:-https://${CORE_APP}.fly.dev}"
    PROBE_LOG="$WORK_DIR/probe-output.log"
    (
        PROBE_WINDOW_SECONDS="$WINDOW" \
            bash "$REPO_ROOT/scripts/probe-production.sh" "$PROBE_BASE_URL" \
            > "$PROBE_LOG" 2>&1
    ) &
    PROBE_PID=$!

    # Scrape loop. Every SCRAPE_INTERVAL seconds fetch /internal/metrics
    # via the public HTTPS URL (https://${CORE_APP}.fly.dev). This is the
    # same observation channel real users exercise, so HTTP auto-start
    # fires for stopped machines (`auto_stop_machines = true` in
    # deploy/fly.core.toml) and the scrape always lands on a warm target.
    #
    # The previous implementation used `fly proxy --select --machine <id>`
    # to scrape each machine individually, but direct-machine proxies do
    # NOT trigger HTTP auto-start — a stopped machine is just unreachable,
    # which produced `http=000` on every iteration and false-passed the
    # gate until `metrics_scrape_healthy` caught it.
    #
    # Tradeoff: Fly's public proxy load-balances across machines so each
    # iteration lands on ONE machine (not all of them). We keep only the
    # last-scrape file — Prometheus counters are cumulative per instance,
    # so summing multiple scrapes would multiply counts. Steady-state
    # from whichever machine served the final request is what the gate
    # evaluates.
    SCRAPE_END=$(( $(date +%s) + WINDOW ))
    LAST_SCRAPE_FILE="$WORK_DIR/last-scrape.txt"
    FIRST_SCRAPE_FILE="$WORK_DIR/first-scrape.txt"
    PUBLIC_METRICS_URL="https://${CORE_APP}.fly.dev/internal/metrics"
    while [[ $(date +%s) -lt $SCRAPE_END ]]; do
        # Note on `|| true`: curl's `-w "%{http_code}"` already writes
        # "000" to stdout on connection failure, so we only need to
        # stop `set -e` from killing the script. Using `|| echo "000"`
        # would double-count ("000000") because both curl's `-w` and
        # the fallback would emit.
        http_code=$(curl -sS --max-time 30 \
            -H "Authorization: Bearer ${METRICS_SCRAPE_TOKEN}" \
            -o "$LAST_SCRAPE_FILE" \
            -w "%{http_code}" \
            "$PUBLIC_METRICS_URL" 2>/dev/null || true)
        http_code="${http_code:-000}"
        if [[ "$http_code" != "200" ]] || [[ ! -s "$LAST_SCRAPE_FILE" ]]; then
            # Bash evaluates `<` redirection before the command runs,
            # so `wc -c < "$scrape_file"` with a missing file prints a
            # redirect error that trailing `2>/dev/null` can't catch.
            # Gate the read on existence.
            body_size=0
            if [[ -f "$LAST_SCRAPE_FILE" ]]; then
                body_size=$(wc -c < "$LAST_SCRAPE_FILE" | awk '{print $1}')
            fi
            echo "WARN scrape: http=$http_code size=$body_size — discarding"
            rm -f "$LAST_SCRAPE_FILE"
        else
            # Snapshot the FIRST successful scrape so p95/rate SLIs can be
            # computed over the gate window (delta) rather than cumulative
            # from BEAM start. Without this, pre-gate samples (warmup
            # uploads, deploy-time probes) contaminate the measurement.
            if [[ ! -f "$FIRST_SCRAPE_FILE" ]]; then
                cp "$LAST_SCRAPE_FILE" "$FIRST_SCRAPE_FILE"
            fi
        fi

        now=$(date +%s)
        remaining=$(( SCRAPE_END - now ))
        if [[ $remaining -le 0 ]]; then break; fi
        sleep_for=$SCRAPE_INTERVAL
        if [[ $sleep_for -gt $remaining ]]; then sleep_for=$remaining; fi
        sleep "$sleep_for"
    done

    # Wait for the probe to finish.
    wait "$PROBE_PID" 2>/dev/null || true

    # Collect the last scrape (one file since the public URL serves one
    # machine per request). `rm -f` already ran on every discard path,
    # so existence here means the last iteration succeeded.
    if [[ -f "$LAST_SCRAPE_FILE" ]] && [[ -s "$LAST_SCRAPE_FILE" ]]; then
        METRIC_FILES+=("$LAST_SCRAPE_FILE")
    fi
    # Collect the first scrape for window-delta SLI computation. If no
    # scrapes ever succeeded, this will be absent and the Python code
    # treats the first scrape as zero (delta == cumulative — safe fallback).
    if [[ -f "$FIRST_SCRAPE_FILE" ]] && [[ -s "$FIRST_SCRAPE_FILE" ]]; then
        METRIC_FIRST_FILES+=("$FIRST_SCRAPE_FILE")
    fi

    # Extract the probe JSON summary from the probe's stdout log. The probe
    # prints a line starting with `probe-summary-json: {...}`.
    PROBE_FIXTURE="$WORK_DIR/probe-summary.json"
    python3 - "$PROBE_LOG" "$PROBE_FIXTURE" <<'PY'
import json
import sys

log_path, out_path = sys.argv[1], sys.argv[2]
summary = {
    "availability": 0.0,
    "p95_ms": {"health": 0, "catalogue": 0, "login": 0, "upload": 0},
    "synthetic_probes": {
        "total": 0,
        "succeeded": 0,
        "p95_ms": 0,
        "http_5xx_count": 0,
        "timeout_count": 0,
    },
    "upload_outcome": "error",
}
try:
    with open(log_path) as f:
        for line in f:
            if line.startswith("probe-summary-json:"):
                payload = line.split("probe-summary-json:", 1)[1].strip()
                summary = json.loads(payload)
except (OSError, ValueError):
    pass
with open(out_path, "w") as f:
    json.dump(summary, f)
PY
    PROBE_SUMMARY_FIXTURE="$PROBE_FIXTURE"
    export PROBE_SUMMARY_FIXTURE
fi

DEPLOY_COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export DEPLOY_COMPLETED_AT

# ── SLI computation ──────────────────────────────────────────────────────────
# Everything downstream is pure data crunching — emit the gate-observations
# JSON and pick an exit code from the aggregate `breached` flag.

# Export shell values to Python via environment for the inline script.
export METRIC_FILES_JSON METRIC_FIRST_FILES_JSON
METRIC_FILES_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${METRIC_FILES[@]}")"
# First-scrape files are optional — if empty, Python treats first-snapshot as
# all-zero and windowed == cumulative (backward compatible with single-
# fixture tests).
if [[ ${#METRIC_FIRST_FILES[@]} -gt 0 ]]; then
    METRIC_FIRST_FILES_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${METRIC_FIRST_FILES[@]}")"
else
    METRIC_FIRST_FILES_JSON="[]"
fi

BLOB="$(python3 - <<'PY'
import json
import os
import sys

metric_files = json.loads(os.environ.get("METRIC_FILES_JSON") or "[]")
metric_first_files = json.loads(os.environ.get("METRIC_FIRST_FILES_JSON") or "[]")
probe_summary_path = os.environ.get("PROBE_SUMMARY_FIXTURE") or ""
commit_sha = os.environ.get("COMMIT_SHA") or ""
deploy_started_at = os.environ.get("DEPLOY_STARTED_AT") or ""
deploy_completed_at = os.environ.get("DEPLOY_COMPLETED_AT") or ""


# ── Prom-ex text parser ─────────────────────────────────────────────────────
def parse_prom(text: str):
    """Return {metric_name: [{labels: {k:v}, value: float}]}"""
    out: dict[str, list[dict]] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # metric_name{labels} value  OR  metric_name value
        if "{" in line:
            head, rest = line.split("{", 1)
            name = head.strip()
            label_str, val_str = rest.rsplit("}", 1)
            labels: dict[str, str] = {}
            # quick-n-dirty label parser — ok for well-formed prom-ex output
            for part in [p.strip() for p in label_str.split(",") if p.strip()]:
                if "=" not in part:
                    continue
                k, v = part.split("=", 1)
                labels[k.strip()] = v.strip().strip('"')
            try:
                value = float(val_str.strip())
            except ValueError:
                continue
        else:
            parts = line.split()
            if len(parts) != 2:
                continue
            name = parts[0]
            labels = {}
            try:
                value = float(parts[1])
            except ValueError:
                continue
        out.setdefault(name, []).append({"labels": labels, "value": value})
    return out


# Load and merge across machines: SUM counters, MAX gauges.
#
# Names come directly from a PromEx 1.11 scrape with the default plugins
# (Beam, Ecto, Phoenix, Oban, Application) on `otp_app: :core`. Built-in
# plugins prefix every metric with `core_prom_ex_<plugin>_`; the custom
# `Core.PromEx.Plugins.Stacks` plugin bypasses the auto-prefix so its
# `stacks_*` names are exported verbatim. See Issue #140.
COUNTER_NAMES = {
    # Custom (Stacks plugin) — names are unprefixed by design.
    "stacks_upload_terminal_count_total",
    "stacks_router_dispatch_stop_duration_milliseconds_bucket",
    "stacks_router_dispatch_stop_duration_milliseconds_sum",
    "stacks_router_dispatch_stop_duration_milliseconds_count",
    # Phoenix — counter of serviced requests (tagged by :status).
    "core_prom_ex_phoenix_http_requests_total",
    # Oban — the `_count` field on each distribution serves as the
    # effective per-queue total for that outcome (success vs failure).
    "core_prom_ex_oban_job_processing_duration_milliseconds_bucket",
    "core_prom_ex_oban_job_processing_duration_milliseconds_sum",
    "core_prom_ex_oban_job_processing_duration_milliseconds_count",
    "core_prom_ex_oban_job_exception_duration_milliseconds_bucket",
    "core_prom_ex_oban_job_exception_duration_milliseconds_sum",
    "core_prom_ex_oban_job_exception_duration_milliseconds_count",
    # Ecto — queue_time histogram.
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket",
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_sum",
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_count",
}
# BEAM memory is broken down per-category by PromEx; there is no single
# `*_total_bytes` roll-up. Sum these at SLI-computation time to derive the
# effective total memory footprint.
BEAM_MEMORY_METRICS = (
    "core_prom_ex_beam_memory_atom_total_bytes",
    "core_prom_ex_beam_memory_binary_total_bytes",
    "core_prom_ex_beam_memory_code_total_bytes",
    "core_prom_ex_beam_memory_ets_total_bytes",
    "core_prom_ex_beam_memory_persistent_term_total_bytes",
    "core_prom_ex_beam_memory_processes_total_bytes",
)
GAUGE_NAMES = {
    "stacks_fuse_state_state",
    *BEAM_MEMORY_METRICS,
}


def label_key(labels):
    return tuple(sorted(labels.items()))


def merge_scrape_files(paths: list[str]):
    """Parse + merge a list of Prometheus scrape files into one view.

    Returns `(merged, per_machine_beam_bytes)`:
      * merged: dict[name, dict[label_key, {labels, value}]]
      * per_machine_beam_bytes: list of total bytes per file (for MAX-
        across-machines computation elsewhere).
    """
    merged: dict[str, dict[tuple, dict]] = {}
    per_machine_beam: list[float] = []
    for path in paths:
        try:
            with open(path) as f:
                parsed = parse_prom(f.read())
        except OSError:
            continue
        machine_beam = 0.0
        for mem_name in BEAM_MEMORY_METRICS:
            for row in parsed.get(mem_name, []):
                machine_beam += row["value"]
        per_machine_beam.append(machine_beam)
        for name, rows in parsed.items():
            bucket = merged.setdefault(name, {})
            for row in rows:
                k = label_key(row["labels"])
                if k in bucket:
                    # Reviewer P2 #6: check GAUGE_NAMES exact-match FIRST so a
                    # future gauge accidentally named `foo_total` is still MAX-
                    # aggregated, not SUM. Explicit counter names also take
                    # priority over suffix heuristics for the same reason.
                    if name in GAUGE_NAMES:
                        # Special case fuse state: MIN (because 0 = open, worse).
                        if name == "stacks_fuse_state_state":
                            bucket[k]["value"] = min(bucket[k]["value"], row["value"])
                        else:
                            bucket[k]["value"] = max(bucket[k]["value"], row["value"])
                    elif name in COUNTER_NAMES or name.endswith(
                        ("_total", "_bucket", "_sum", "_count")
                    ):
                        bucket[k]["value"] += row["value"]
                    else:
                        # Default: overwrite (gauges) — but treat conservatively.
                        bucket[k]["value"] = max(bucket[k]["value"], row["value"])
                else:
                    bucket[k] = {"labels": dict(row["labels"]), "value": row["value"]}
    return merged, per_machine_beam


# `merged` is the last-scrape view: used for gauges (fuse state, BEAM memory).
# `first_merged` is the first-scrape view: subtracted from `merged` to build
# the windowed view used by rate + histogram SLIs. This makes `upload_p95_ms`
# and friends reflect only traffic that occurred during the gate window —
# pre-gate samples (deploy-time warmup probes, late-resolving Oban jobs from
# previous deploys) no longer contaminate the measurement.
#
# If `first_merged` is empty (no first-scrape available, e.g. single-fixture
# test mode, or prod run where no scrape ever succeeded), `windowed` falls
# back to last values == cumulative. Backward compatible.
merged, per_machine_beam_bytes = merge_scrape_files(metric_files)
first_merged, _ = merge_scrape_files(metric_first_files)

# Build windowed view. Counter/histogram series get last - first (clamped
# non-negative for machine-swap safety); gauges pass through unchanged.
windowed: dict[str, dict[tuple, dict]] = {}
_machine_swap_warned = False
for name, last_bucket in merged.items():
    windowed_bucket: dict[tuple, dict] = {}
    first_bucket = first_merged.get(name, {})
    is_gauge = name in GAUGE_NAMES
    for k, row in last_bucket.items():
        if is_gauge:
            windowed_bucket[k] = row
        else:
            first_val = first_bucket.get(k, {}).get("value", 0.0)
            delta = row["value"] - first_val
            if delta < 0:
                # Cumulative counter went backwards between scrapes. Either
                # the BEAM restarted mid-window (redeploy, OOM) or Fly's
                # proxy served scrapes from two machines with independent
                # counters. Neither yields a meaningful delta — clamp to 0
                # and flag once so the gate output notes the anomaly.
                delta = 0.0
                if not _machine_swap_warned:
                    print(
                        "WARN: cumulative counter regressed between scrapes — "
                        "likely BEAM restart or Fly proxy machine swap mid-window. "
                        "Affected windowed deltas clamped to zero.",
                        file=sys.stderr,
                    )
                    _machine_swap_warned = True
        windowed_bucket[k] = {**row, "value": delta} if not is_gauge else row
    windowed[name] = windowed_bucket


def rows_for(name: str):
    """Cumulative values from the last scrape — used for gauges."""
    return list(merged.get(name, {}).values())


def windowed_rows_for(name: str):
    """Windowed (last - first) values — used for rate + histogram SLIs."""
    return list(windowed.get(name, {}).values())


# ── Histogram p95 via bucket interpolation ──────────────────────────────────
# p95 reads from the WINDOWED view — bucket counts are last - first, giving
# the distribution of samples that arrived during the gate window only.
def histogram_p95_by_group(metric: str, group_label: str, target_group: str):
    rows = [
        r for r in windowed_rows_for(metric)
        if r["labels"].get(group_label) == target_group
    ]
    # Collect (le_float, cumulative_count).
    buckets: list[tuple[float, float]] = []
    for r in rows:
        le = r["labels"].get("le")
        if le is None:
            continue
        le_f = float("inf") if le == "+Inf" else float(le)
        buckets.append((le_f, r["value"]))
    buckets.sort()
    if not buckets:
        return 0
    total = buckets[-1][1]
    if total <= 0:
        return 0
    target = 0.95 * total
    prev_le = 0.0
    prev_count = 0.0
    for le, count in buckets:
        if count >= target:
            if le == float("inf"):
                # p95 lives above the highest finite bucket; upper-bound it at
                # the previous bucket edge doubled (conservative signal).
                return int(prev_le * 2) if prev_le > 0 else 99_999
            # Linear interpolation within the bucket.
            span = count - prev_count
            if span <= 0:
                return int(le)
            frac = (target - prev_count) / span
            return int(prev_le + frac * (le - prev_le))
        prev_le = le
        prev_count = count
    return int(buckets[-1][0])


def histogram_p95(metric: str):
    """p95 across a non-labelled histogram (e.g. ecto queue_time).

    Reads windowed (last - first) bucket counts so pre-gate samples don't
    contaminate the measurement.
    """
    rows = windowed_rows_for(metric)
    buckets: list[tuple[float, float]] = []
    for r in rows:
        le = r["labels"].get("le")
        if le is None:
            continue
        le_f = float("inf") if le == "+Inf" else float(le)
        buckets.append((le_f, r["value"]))
    buckets.sort()
    if not buckets:
        return 0
    total = buckets[-1][1]
    if total <= 0:
        return 0
    target = 0.95 * total
    prev_le = 0.0
    prev_count = 0.0
    for le, count in buckets:
        if count >= target:
            if le == float("inf"):
                return int(prev_le * 2) if prev_le > 0 else 99_999
            span = count - prev_count
            if span <= 0:
                return int(le)
            frac = (target - prev_count) / span
            return int(prev_le + frac * (le - prev_le))
        prev_le = le
        prev_count = count
    return int(buckets[-1][0])


# ── Probe summary ───────────────────────────────────────────────────────────
probe = {
    "availability": 0.0,
    "p95_ms": {"health": 0, "catalogue": 0, "login": 0, "upload": 0},
    "synthetic_probes": {
        "total": 0,
        "succeeded": 0,
        "p95_ms": 0,
        "http_5xx_count": 0,
        "timeout_count": 0,
    },
    "upload_outcome": "error",
}
if probe_summary_path:
    try:
        with open(probe_summary_path) as f:
            probe = json.load(f)
    except (OSError, ValueError):
        pass


# ── SLI definitions ─────────────────────────────────────────────────────────
slis: list[dict] = []

# Availability (from synthetic probes).
avail_val = float(probe.get("availability", 0.0))
slis.append(
    {
        "name": "availability",
        "value": round(avail_val, 4),
        "threshold": 0.99,
        "breached": avail_val < 0.99,
    }
)

# Metrics-scrape liveness (observation-channel sentinel).
#
# Answers "did I actually see prod data?" — NOT "is prod healthy?". If the
# scrape channel is broken (401 token mismatch, endpoint moved, parser
# skew, auto-stopped machines, Fly proxy failure, PromEx downgrade that
# renames every series), every metric-derived SLI computes to 0, and every
# one-sided threshold (`p95 > X`, `mem > Y`) passes trivially. Probes use
# a separate channel (public HTTPS, no token) so `availability=1.0` can
# co-exist with total scrape blindness — as happened on the 2026-04-19
# first-prod-deploy gate (commit acdad4b).
#
# We look for the most basic series PromEx emits by default — BEAM memory
# and Phoenix HTTP requests. If both families are empty, there is no
# scrape regardless of what rows_for(stacks_*) returns (a custom-plugin
# regression would also appear as empty). Strict fail-closed: a zero here
# is ALWAYS a breach, no min_samples escape.
scrape_live = any(rows_for(n) for n in BEAM_MEMORY_METRICS) or bool(
    rows_for("core_prom_ex_phoenix_http_requests_total")
)
slis.append(
    {
        "name": "metrics_scrape_healthy",
        "value": 1 if scrape_live else 0,
        "threshold": 1,
        "breached": not scrape_live,
    }
)

# Real-traffic 5xx rate (from PromEx Phoenix plugin).
#
# Synthetic probes only hit a handful of endpoints as the owner account.
# An availability SLI derived from probes can pass while real user traffic
# is 5xxing on other routes. Gate the rate of `status` labels starting
# with "5" against all serviced requests. Apply a min-samples guard like
# Oban so low-traffic windows don't false-breach on a single 500.
HTTP_MIN_SAMPLES = 50
http_total = 0.0
http_5xx = 0.0
# Windowed: only 5xxes from the gate window count, not cumulative since
# BEAM start. Otherwise a single 500 pre-gate could false-breach forever.
for r in windowed_rows_for("core_prom_ex_phoenix_http_requests_total"):
    status = str(r["labels"].get("status", ""))
    http_total += r["value"]
    if status.startswith("5"):
        http_5xx += r["value"]
http_rate = (http_5xx / http_total) if http_total > 0 else 0.0
http_samples = int(http_total)
http_entry = {
    "name": "real_5xx_rate",
    "value": round(http_rate, 4),
    "threshold": 0.005,
    "samples": http_samples,
    "min_samples": HTTP_MIN_SAMPLES,
    "breached": http_samples >= HTTP_MIN_SAMPLES and http_rate > 0.005,
}
if http_samples < HTTP_MIN_SAMPLES:
    http_entry["note"] = "below min_samples; not gating"
slis.append(http_entry)

# Route-group p95 latency: auth, catalogue, upload.
#
# `upload_p95_ms` threshold is 3000 ms (interim). The target is 2000 ms
# and will be lowered back to that once an experimental framework exists
# to compare vision configurations (model / quantization / engine / GPU)
# on a reproducible canary set. See ADR 015 section "Future work:
# experimental framework for model comparison". The 3000 ms ceiling is
# high enough to absorb a bursty probe cold-start but still catches a
# regression if the vision pipeline gets meaningfully worse.
HIST = "stacks_router_dispatch_stop_duration_milliseconds_bucket"
for group, threshold, name in [
    ("auth", 500, "auth_p95_ms"),
    ("catalogue", 500, "catalogue_p95_ms"),
    ("upload", 3000, "upload_p95_ms"),
]:
    p95 = histogram_p95_by_group(HIST, "route_group", group)
    slis.append(
        {
            "name": name,
            "value": int(p95),
            "threshold": threshold,
            "breached": p95 > threshold,
        }
    )

# Upload pipeline completion rate.
#
# The probe fires two canaries per iteration — a real book image
# (expected outcome: `resolved`) and a not-a-book image (expected
# outcome: `rejected`). Both outcomes represent a pipeline that worked:
# the POST accepted the image, storage persisted it, the IdentifyBookJob
# ran, vision classified, and the async handler reached a terminal
# state. Only `timeout` (the pipeline hung / vision never replied)
# represents a genuine failure.
#
# The previous formula (`resolved / total`) hard-coded the happy-path
# canary as the only "success", which meant the not-a-book canary
# produced a 0% success rate on a perfectly healthy pipeline. Include
# both resolved and rejected in the numerator.
#
# Apply a min_samples guard (matches Oban / real_5xx_rate pattern) so
# low-traffic windows don't false-breach on a single timeout, and
# separately record whether the sample was absent entirely —
# `metrics_scrape_healthy` above catches scrape-channel failure.
UPLOAD_MIN_SAMPLES = 5
# Windowed: only terminals that fired during the gate window count. Pre-gate
# resolves/rejects (warmup uploads, late-finishing previous-deploy jobs)
# aren't part of the SLO measurement.
terminal = {
    r["labels"].get("outcome", ""): r["value"]
    for r in windowed_rows_for("stacks_upload_terminal_count_total")
}
total_terminal = sum(terminal.values())
resolved = terminal.get("resolved", 0)
rejected = terminal.get("rejected", 0)
timeout = terminal.get("timeout", 0)
completed = resolved + rejected
denominator = completed + timeout
success_rate = (completed / denominator) if denominator > 0 else 1.0
upload_entry = {
    "name": "upload_success_rate",
    "value": round(success_rate, 4),
    "threshold": 0.90,
    "samples": int(denominator),
    "min_samples": UPLOAD_MIN_SAMPLES,
    "breached": int(denominator) >= UPLOAD_MIN_SAMPLES and success_rate < 0.90,
}
if int(denominator) < UPLOAD_MIN_SAMPLES:
    upload_entry["note"] = "below min_samples; not gating"
slis.append(upload_entry)

# Oban per-queue failure rate.
#
# PromEx's Oban plugin emits two separate distribution families rather than
# a single counter tagged by outcome:
#   * `…_oban_job_processing_duration_*`  — [:oban, :job, :stop]      (success)
#   * `…_oban_job_exception_duration_*`   — [:oban, :job, :exception] (failure)
# The `_count` field on each histogram is the per-queue total sample count
# for that outcome, which is exactly what we want for the failure-rate SLI.
#
# Reviewer P1 #4: a queue with 0 successes + 1 failure previously reported
# 100% failure and breached the gate, even though the sample is meaningless.
# Emit the SLI with raw `samples` and `min_samples` hints, and only mark it
# breached when samples >= min_samples AND rate > threshold.
OBAN_MIN_SAMPLES = 10
OBAN_SUCCESS_COUNT = "core_prom_ex_oban_job_processing_duration_milliseconds_count"
OBAN_FAILURE_COUNT = "core_prom_ex_oban_job_exception_duration_milliseconds_count"
queues: dict[str, dict[str, float]] = {}
# Windowed: per-queue failure rate reflects only jobs that completed during
# the gate window, not cumulative lifetime counts.
for r in windowed_rows_for(OBAN_SUCCESS_COUNT):
    q = r["labels"].get("queue", "unknown")
    queues.setdefault(q, {"success": 0.0, "failure": 0.0})["success"] += r["value"]
for r in windowed_rows_for(OBAN_FAILURE_COUNT):
    q = r["labels"].get("queue", "unknown")
    queues.setdefault(q, {"success": 0.0, "failure": 0.0})["failure"] += r["value"]
for q, states in queues.items():
    fail = states.get("failure", 0.0)
    succ = states.get("success", 0.0)
    total = fail + succ
    rate = (fail / total) if total > 0 else 0.0
    samples = int(total)
    entry = {
        "name": f"oban_failure_rate_{q}",
        "value": round(rate, 4),
        "threshold": 0.05,
        "samples": samples,
        "min_samples": OBAN_MIN_SAMPLES,
        "breached": samples >= OBAN_MIN_SAMPLES and rate > 0.05,
    }
    if samples < OBAN_MIN_SAMPLES:
        entry["note"] = "below min_samples; not gating"
    slis.append(entry)

# Fuse open (one SLI per managed fuse).
for r in rows_for("stacks_fuse_state_state"):
    fuse = r["labels"].get("fuse_name", "unknown")
    state = int(r["value"])
    open_flag = 0 if state == 1 else 1
    slis.append(
        {
            "name": f"{fuse}_open",
            "value": open_flag,
            "threshold": 0,
            "breached": open_flag > 0,
        }
    )

# DB pool queue_time p95 — two SLIs, one per repo.
#
# PromEx's Ecto plugin prefixes the metric with the otp_app + plugin name,
# so the real series is `core_prom_ex_ecto_repo_query_queue_time_*`. The
# previous parser looked for an un-prefixed `core_repo_query_queue_time_*`
# name that PromEx does not emit, so this SLI silently reported 0 for every
# production deploy (Issue #140).
#
# As of 2026-04-20 PromEx tracks both Core.Repo and Core.ObanRepo (see
# Core.PromEx.plugins/0). Buckets are labelled by `repo=`; without
# filtering, `histogram_p95` would sum counts across both and report a
# meaningless blend. Compute a per-repo p95 via `histogram_p95_by_group`
# and emit each as its own SLI.
#
# min_samples guard: on low-volume machines (early deploy, quiet prod)
# Core.Repo sees ~20 queries over the 10-min gate window. p95 on 20
# samples is noise — two outliers during cold-start warmup pushed it
# to 174ms previously, gating a healthy prod on a non-signal. Only
# gate when sample count clears the floor.
DB_QUEUE_MIN_SAMPLES = 50
DB_QUEUE_METRIC = "core_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket"
DB_QUEUE_COUNT_METRIC = "core_prom_ex_ecto_repo_query_queue_time_milliseconds_count"


def _queue_samples_for(repo_label: str) -> int:
    # `*_count` is a counter — pick the le="+Inf" row (which carries the
    # total sample count for the histogram) OR sum the count metric's
    # per-label value. PromEx emits a single count row per repo.
    # Windowed so the min-samples floor reflects in-window volume, not
    # cumulative lifetime count.
    for r in windowed_rows_for(DB_QUEUE_COUNT_METRIC):
        if r["labels"].get("repo") == repo_label:
            return int(r["value"])
    return 0


for repo_label, sli_name, threshold in [
    # Industry gold standard for DB pool queue_time p95 is <5ms (healthy
    # pool, connection always immediately available). 20ms is the upper
    # edge of "healthy with occasional pressure" and the point at which
    # tail latency becomes user-visible on hot request paths. Anything
    # above 20ms means the pool is too small OR connections are held
    # too long by slow queries / long transactions — both worth paging
    # on rather than tolerating.
    #
    # Previous thresholds (50ms / 200ms) were defensive-alarm levels,
    # not health targets. The 200ms Oban threshold in particular was
    # rationalised as "LISTEN/NOTIFY holds conns by design" — but LISTEN
    # doesn't contribute to queue_time; it just reduces effective pool
    # capacity. Fix is a larger pool, not a looser threshold.
    ("Core.Repo", "db_pool_queue_p95_ms", 20),
    ("Core.ObanRepo", "oban_repo_queue_p95_ms", 20),
]:
    samples = _queue_samples_for(repo_label)
    p95 = histogram_p95_by_group(DB_QUEUE_METRIC, "repo", repo_label)
    entry = {
        "name": sli_name,
        "value": int(p95),
        "threshold": threshold,
        "samples": samples,
        "min_samples": DB_QUEUE_MIN_SAMPLES,
        "breached": samples >= DB_QUEUE_MIN_SAMPLES and p95 > threshold,
    }
    if samples < DB_QUEUE_MIN_SAMPLES:
        entry["note"] = "below min_samples; not gating"
    slis.append(entry)

# BEAM memory (MAX across machines). Threshold is 400 MB, expressed in
# bytes so the raw value carries units. We also emit an MB-valued twin SLI
# so the human-readable table has something operators recognise, but the
# canonical SLI the gate compares against is the bytes form.
#
# PromEx breaks BEAM memory down per-category (atom, binary, code, ets,
# persistent_term, processes) — there is no roll-up series. We sum the
# categories WITHIN each machine, then MAX across machines. Falling back
# to 0 ensures the test fixtures without any beam_memory_* rows still
# produce a deterministic zero rather than crashing on max([]).
beam_bytes = max(per_machine_beam_bytes) if per_machine_beam_bytes else 0.0
beam_mb = int(beam_bytes / (1024 * 1024))
beam_threshold_bytes = 400 * 1024 * 1024
slis.append(
    {
        "name": "beam_memory_bytes",
        "value": int(beam_bytes),
        "threshold": beam_threshold_bytes,
        "breached": beam_bytes > beam_threshold_bytes,
    }
)
slis.append(
    {
        "name": "beam_memory_mb",
        "value": beam_mb,
        "threshold": 400,
        "breached": beam_mb > 400,
    }
)


# ── Observations (debug / forward-compat) ──────────────────────────────────
# Flat: the test harness does `.observations.upload.resolved // .slis[] |
# select(.name|test("upload"))`. If `observations.upload.resolved` were a
# nested number, the first branch evaluates to that number, and the subsequent
# `select(.name…)` errors on non-objects. Keep the nested `upload_*` keys flat
# so the fallback to `.slis[]` kicks in.
observations = {
    "machines_scraped": len(metric_files),
    "upload_resolved_total": int(terminal.get("resolved", 0)),
    "upload_rejected_total": int(terminal.get("rejected", 0)),
    "upload_timeout_total": int(terminal.get("timeout", 0)),
    "upload_terminal_total": int(total_terminal),
    "upload_success_rate": round(success_rate, 4),
    "beam_memory_bytes": int(beam_bytes),
}

# FORCE_BREACH override (operator feature): if set, mark the named SLI as
# breached so the rollback path can be end-to-end-validated against a
# preview app. Safe to leave wired in because this env var is ONLY set via
# the workflow_dispatch `force_rollback` input in deploy-production.yml.
force_breach = os.environ.get("FORCE_BREACH") or ""
if force_breach:
    for s in slis:
        if s["name"] == force_breach:
            s["breached"] = True
            s["note"] = f"forced breach via FORCE_BREACH={force_breach}"

outcome = "passed" if not any(s["breached"] for s in slis) else "breached"

blob = {
    "commit_sha": commit_sha,
    "deploy_started_at": deploy_started_at,
    "deploy_completed_at": deploy_completed_at,
    "outcome": outcome,
    "slis": slis,
    "synthetic_probes": probe.get("synthetic_probes", {}),
    "observations": observations,
}
print(json.dumps(blob))
PY
)"

# The Python script exits 0; we derive our own exit from the outcome field.
# Emit a human-readable table before the JSON blob.
echo "=== SLO gate observations ==="
printf '%s\n' "$BLOB" | python3 -c "
import json, sys
blob = json.loads(sys.stdin.read())
print('outcome:', blob['outcome'])
print('commit: ', blob['commit_sha'] or '(unset)')
print('SLIs:')
for s in blob['slis']:
    flag = 'BREACH' if s['breached'] else 'ok'
    print('  %-6s %-28s value=%s threshold=%s' % (flag, s['name'], s['value'], s['threshold']))
" || true

# Emit the JSON blob (last `{` → last `{` in stdout for the test harness).
printf '%s\n' "$BLOB"

# Optional --out <path> persistence for the CI artifact upload step.
if [[ -n "$OUT_PATH" ]]; then
    printf '%s\n' "$BLOB" > "$OUT_PATH"
fi

# Exit code.
if printf '%s' "$BLOB" | python3 -c '
import json, sys
blob = json.loads(sys.stdin.read())
sys.exit(0 if blob.get("outcome") == "passed" else 1)
'; then
    exit 0
else
    exit 1
fi
