#!/usr/bin/env bash
# scripts/check-slo-gate.sh — 10-min SLO gate for post-deploy health.
#
# Modes:
#   production: scrape `/internal/metrics` on each Fly machine via `fly proxy`
#               every 60s for PROBE_WINDOW_SECONDS, run probe-production.sh in
#               parallel, then compute SLIs from the last scrape per machine.
#   test:       when METRICS_FIXTURE / METRICS_FIXTURES + PROBE_SUMMARY_FIXTURE
#               are set, skip the live scrape + probe launch and read those
#               fixtures directly. This is how the Phase 3 tests exercise the
#               aggregation + SLI math without touching Fly.
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
TEST_MODE=0
METRIC_FILES=()
if [[ -n "${METRICS_FIXTURE:-}" ]]; then
    TEST_MODE=1
    METRIC_FILES=("$METRICS_FIXTURE")
elif [[ -n "${METRICS_FIXTURES:-}" ]]; then
    TEST_MODE=1
    IFS=':' read -r -a METRIC_FILES <<< "$METRICS_FIXTURES"
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

    # Scrape loop. Every SCRAPE_INTERVAL seconds we enumerate machines and
    # fetch /internal/metrics via a short-lived `fly proxy`. The LAST scrape
    # per machine wins — the SLO gate looks at steady-state, not trends.
    SCRAPE_END=$(( $(date +%s) + WINDOW ))
    LAST_SCRAPE_PREFIX="$WORK_DIR/last-scrape"
    while [[ $(date +%s) -lt $SCRAPE_END ]]; do
        machine_ids="$(fly machines list --app "$CORE_APP" --json 2>/dev/null \
            | python3 -c 'import json,sys
for m in json.load(sys.stdin):
    if m.get("state") == "started":
        print(m["id"])
' 2>/dev/null || true)"
        if [[ -z "$machine_ids" ]]; then
            sleep "$SCRAPE_INTERVAL"
            continue
        fi
        while IFS= read -r mid; do
            [[ -z "$mid" ]] && continue
            # Reviewer P2 #8: random high-port per machine (20000–29999)
            # prevents collisions with concurrent gate runs or a lingering
            # proxy from a prior iteration.
            port=$((RANDOM % 10000 + 20000))
            fly proxy "${port}:4000" --app "$CORE_APP" --select --machine "$mid" \
                >/dev/null 2>&1 &
            proxy_pid=$!
            # Wait briefly for the proxy to be ready.
            for _ in 1 2 3 4 5; do
                if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
                sleep 1
            done
            curl -s --max-time 10 \
                -H "Authorization: Bearer ${METRICS_SCRAPE_TOKEN}" \
                "http://127.0.0.1:${port}/internal/metrics" \
                > "${LAST_SCRAPE_PREFIX}-${mid}.txt" 2>/dev/null || true
            kill "$proxy_pid" 2>/dev/null || true
            wait "$proxy_pid" 2>/dev/null || true
        done <<< "$machine_ids"

        now=$(date +%s)
        remaining=$(( SCRAPE_END - now ))
        if [[ $remaining -le 0 ]]; then break; fi
        sleep_for=$SCRAPE_INTERVAL
        if [[ $sleep_for -gt $remaining ]]; then sleep_for=$remaining; fi
        sleep "$sleep_for"
    done

    # Wait for the probe to finish.
    wait "$PROBE_PID" 2>/dev/null || true

    # Collect the last scrape per machine.
    for f in "${LAST_SCRAPE_PREFIX}"-*.txt; do
        [[ -f "$f" ]] || continue
        METRIC_FILES+=("$f")
    done

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
export METRIC_FILES_JSON
METRIC_FILES_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${METRIC_FILES[@]}")"

BLOB="$(python3 - <<'PY'
import json
import os
import sys

metric_files = json.loads(os.environ.get("METRIC_FILES_JSON") or "[]")
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
COUNTER_NAMES = {
    "stacks_upload_terminal_count_total",
    "phoenix_endpoint_stop_total",
    "prom_ex_oban_job_stop_total",
    "stacks_router_dispatch_stop_duration_milliseconds_bucket",
    "stacks_router_dispatch_stop_duration_milliseconds_sum",
    "stacks_router_dispatch_stop_duration_milliseconds_count",
    "core_repo_query_queue_time_milliseconds_bucket",
    "core_repo_query_queue_time_milliseconds_sum",
    "core_repo_query_queue_time_milliseconds_count",
}
GAUGE_NAMES = {
    "stacks_fuse_state_state",
    "beam_memory_total_bytes",
}


def label_key(labels):
    return tuple(sorted(labels.items()))


merged: dict[str, dict[tuple, dict]] = {}
for path in metric_files:
    try:
        with open(path) as f:
            parsed = parse_prom(f.read())
    except OSError:
        continue
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


def rows_for(name: str):
    return list(merged.get(name, {}).values())


# ── Histogram p95 via bucket interpolation ──────────────────────────────────
def histogram_p95_by_group(metric: str, group_label: str, target_group: str):
    rows = [
        r for r in rows_for(metric)
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
    """p95 across a non-labelled histogram (e.g. ecto queue_time)."""
    rows = rows_for(metric)
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

# Route-group p95 latency: auth, catalogue, upload.
HIST = "stacks_router_dispatch_stop_duration_milliseconds_bucket"
for group, threshold, name in [
    ("auth", 500, "auth_p95_ms"),
    ("catalogue", 500, "catalogue_p95_ms"),
    ("upload", 2000, "upload_p95_ms"),
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

# Upload success rate (resolved / total terminal).
terminal = {
    r["labels"].get("outcome", ""): r["value"]
    for r in rows_for("stacks_upload_terminal_count_total")
}
total_terminal = sum(terminal.values())
resolved = terminal.get("resolved", 0)
success_rate = (resolved / total_terminal) if total_terminal > 0 else 1.0
slis.append(
    {
        "name": "upload_success_rate",
        "value": round(success_rate, 4),
        "threshold": 0.90,
        "breached": success_rate < 0.90,
    }
)

# Oban per-queue failure rate.
# Reviewer P1 #4: a queue with 0 successes + 1 failure previously reported
# 100% failure and breached the gate, even though the sample is meaningless.
# Emit the SLI with raw `samples` and `min_samples` hints, and only mark it
# breached when samples >= min_samples AND rate > threshold.
OBAN_MIN_SAMPLES = 10
queues: dict[str, dict[str, float]] = {}
for r in rows_for("prom_ex_oban_job_stop_total"):
    q = r["labels"].get("queue", "unknown")
    state = r["labels"].get("state", "unknown")
    queues.setdefault(q, {})[state] = r["value"]
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

# DB pool queue_time p95.
db_p95 = histogram_p95("core_repo_query_queue_time_milliseconds_bucket")
slis.append(
    {
        "name": "db_pool_queue_p95_ms",
        "value": int(db_p95),
        "threshold": 50,
        "breached": db_p95 > 50,
    }
)

# BEAM memory (MAX across machines). Threshold is 400 MB, expressed in
# bytes so the raw value carries units. We also emit an MB-valued twin SLI
# so the human-readable table has something operators recognise, but the
# canonical SLI the gate compares against is the bytes form.
beam_bytes = 0.0
for r in rows_for("beam_memory_total_bytes"):
    beam_bytes = max(beam_bytes, r["value"])
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
