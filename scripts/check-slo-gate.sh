#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OUT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            [[ $# -ge 2 ]] || { echo "FAIL: --out requires a value" >&2; exit 2; }
            OUT_PATH="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done

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

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

DEPLOY_STARTED_AT="${DEPLOY_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [[ "$TEST_MODE" -eq 0 ]]; then
    : "${CORE_APP:?CORE_APP required in production mode}"
    : "${METRICS_SCRAPE_TOKEN:?METRICS_SCRAPE_TOKEN required in production mode}"

    WINDOW="${PROBE_WINDOW_SECONDS:-600}"
    SCRAPE_INTERVAL=60

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
        http_code=$(curl -sS --max-time 30 \
            -H "Authorization: Bearer ${METRICS_SCRAPE_TOKEN}" \
            -o "$LAST_SCRAPE_FILE" \
            -w "%{http_code}" \
            "$PUBLIC_METRICS_URL" 2>/dev/null || true)
        http_code="${http_code:-000}"
        if [[ "$http_code" != "200" ]] || [[ ! -s "$LAST_SCRAPE_FILE" ]]; then
            body_size=0
            if [[ -f "$LAST_SCRAPE_FILE" ]]; then
                body_size=$(wc -c < "$LAST_SCRAPE_FILE" | awk '{print $1}')
            fi
            echo "WARN scrape: http=$http_code size=$body_size — discarding"
            rm -f "$LAST_SCRAPE_FILE"
        else
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

    wait "$PROBE_PID" 2>/dev/null || true

    if [[ -f "$LAST_SCRAPE_FILE" ]] && [[ -s "$LAST_SCRAPE_FILE" ]]; then
        METRIC_FILES+=("$LAST_SCRAPE_FILE")
    fi
    if [[ -f "$FIRST_SCRAPE_FILE" ]] && [[ -s "$FIRST_SCRAPE_FILE" ]]; then
        METRIC_FIRST_FILES+=("$FIRST_SCRAPE_FILE")
    fi

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

export METRIC_FILES_JSON METRIC_FIRST_FILES_JSON
METRIC_FILES_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${METRIC_FILES[@]}")"
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

def parse_prom(text: str):
    """Return {metric_name: [{labels: {k:v}, value: float}]}"""
    out: dict[str, list[dict]] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "{" in line:
            head, rest = line.split("{", 1)
            name = head.strip()
            label_str, val_str = rest.rsplit("}", 1)
            labels: dict[str, str] = {}
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

COUNTER_NAMES = {
    "stacks_upload_terminal_count_total",
    "stacks_router_dispatch_stop_duration_milliseconds_bucket",
    "stacks_router_dispatch_stop_duration_milliseconds_sum",
    "stacks_router_dispatch_stop_duration_milliseconds_count",
    "core_prom_ex_phoenix_http_requests_total",
    "core_prom_ex_oban_job_processing_duration_milliseconds_bucket",
    "core_prom_ex_oban_job_processing_duration_milliseconds_sum",
    "core_prom_ex_oban_job_processing_duration_milliseconds_count",
    "core_prom_ex_oban_job_exception_duration_milliseconds_bucket",
    "core_prom_ex_oban_job_exception_duration_milliseconds_sum",
    "core_prom_ex_oban_job_exception_duration_milliseconds_count",
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket",
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_sum",
    "core_prom_ex_ecto_repo_query_queue_time_milliseconds_count",
}
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
                    if name in GAUGE_NAMES:
                        if name == "stacks_fuse_state_state":
                            bucket[k]["value"] = min(bucket[k]["value"], row["value"])
                        else:
                            bucket[k]["value"] = max(bucket[k]["value"], row["value"])
                    elif name in COUNTER_NAMES or name.endswith(
                        ("_total", "_bucket", "_sum", "_count")
                    ):
                        bucket[k]["value"] += row["value"]
                    else:
                        bucket[k]["value"] = max(bucket[k]["value"], row["value"])
                else:
                    bucket[k] = {"labels": dict(row["labels"]), "value": row["value"]}
    return merged, per_machine_beam

merged, per_machine_beam_bytes = merge_scrape_files(metric_files)
first_merged, _ = merge_scrape_files(metric_first_files)

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

def histogram_p95_by_group(metric: str, group_label: str, target_group: str):
    rows = [
        r for r in windowed_rows_for(metric)
        if r["labels"].get(group_label) == target_group
    ]
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

slis: list[dict] = []

avail_val = float(probe.get("availability", 0.0))
slis.append(
    {
        "name": "availability",
        "value": round(avail_val, 4),
        "threshold": 0.99,
        "breached": avail_val < 0.99,
    }
)

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

HTTP_MIN_SAMPLES = 50
http_total = 0.0
http_5xx = 0.0
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
# `upload_p95_ms` threshold is 30000 ms (interim). The `:upload` route
# group includes GET /api/upload/:id/stream — the identification progress
# stream — whose router-dispatch duration is how long the client holds the
# stream open while the vision pipeline resolves (10-20 s by design with
# the current always-VLM path). Run 28931136604 measured p95 = 18108 ms on
# a fully healthy system (upload_success_rate 1.0, 0 timeouts) and rolled
# back an otherwise-green deploy. 30000 ms still catches a hung pipeline
# (streams held to their timeout) while tolerating normal VLM latency.
# Bring-down plan: (1) the identify cascade (barcode -> cover-embedding
# retrieval -> OCR -> VLM fallback) collapses common-case resolution to
# 1-3 s; (2) reclassify the stream route into its own group so this SLI
# measures request latency again — then restore a 2000-3000 ms threshold.
# See ADR 015 section "Future work: experimental framework for model
# comparison".
# `bookshelves_p95_ms` threshold is 500 ms. The `:bookshelves` route group
# serves the shelf-browse read path (GET /api/bookshelves/:name → a bounded
# query with `book: [:author, :editions]` preloads; no N+1 — guarded by
# apps/core/test/stacks/shelving_query_test.exs). Issue #273 measured p95 on a
# healthy deployed preview (stacks-core-pr-feat-e2e-112, 2026-07-22, 100
# authenticated requests across all five shelves, all HTTP 200): server-side
# router-dispatch p95 <= 100 ms (72/100 under 50 ms, 99/100 under 100 ms). 500
# ms matches the other read groups (auth, catalogue) and leaves ~5x headroom
# over the measured p95 — it absorbs cold-start and load variance while still
# catching a real latency regression (an N+1 reintroduction, a lost index, a
# slow preload). Recalibrate if the placements query shape changes.
HIST = "stacks_router_dispatch_stop_duration_milliseconds_bucket"
for group, threshold, name in [
    ("auth", 500, "auth_p95_ms"),
    ("catalogue", 500, "catalogue_p95_ms"),
    ("bookshelves", 500, "bookshelves_p95_ms"),
    ("upload", 30000, "upload_p95_ms"),
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

UPLOAD_MIN_SAMPLES = 5
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

OBAN_MIN_SAMPLES = 10
OBAN_SUCCESS_COUNT = "core_prom_ex_oban_job_processing_duration_milliseconds_count"
OBAN_FAILURE_COUNT = "core_prom_ex_oban_job_exception_duration_milliseconds_count"
queues: dict[str, dict[str, float]] = {}
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

DB_QUEUE_MIN_SAMPLES = 50
DB_QUEUE_METRIC = "core_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket"
DB_QUEUE_COUNT_METRIC = "core_prom_ex_ecto_repo_query_queue_time_milliseconds_count"

def _queue_samples_for(repo_label: str) -> int:
    for r in windowed_rows_for(DB_QUEUE_COUNT_METRIC):
        if r["labels"].get("repo") == repo_label:
            return int(r["value"])
    return 0

for repo_label, sli_name, threshold in [
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

observations = {
    "machines_scraped": len(metric_files),
    "upload_resolved_total": int(terminal.get("resolved", 0)),
    "upload_rejected_total": int(terminal.get("rejected", 0)),
    "upload_timeout_total": int(terminal.get("timeout", 0)),
    "upload_terminal_total": int(total_terminal),
    "upload_success_rate": round(success_rate, 4),
    "beam_memory_bytes": int(beam_bytes),
}

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

printf '%s\n' "$BLOB"

if [[ -n "$OUT_PATH" ]]; then
    printf '%s\n' "$BLOB" > "$OUT_PATH"
fi

if printf '%s' "$BLOB" | python3 -c '
import json, sys
blob = json.loads(sys.stdin.read())
sys.exit(0 if blob.get("outcome") == "passed" else 1)
'; then
    exit 0
else
    exit 1
fi
