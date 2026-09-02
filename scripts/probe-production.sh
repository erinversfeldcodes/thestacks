#!/usr/bin/env bash

set -euo pipefail

BASE_URL="${1:-}"
if [[ -z "$BASE_URL" ]]; then
    echo "usage: probe-production.sh <base_url>" >&2
    exit 2
fi
BASE_URL="${BASE_URL%/}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WINDOW="${PROBE_WINDOW_SECONDS:-600}"
INTERVAL="${PROBE_INTERVAL_SECONDS:-15}"
SEED_EMAIL="${PROBE_SEED_EMAIL:-owner@thestacks.app}"
SEED_PASSWORD="${PROBE_SEED_PASSWORD:-dev-password-123}"
BARCODE_CANARY="${REPO_ROOT}/images/barcode_isbn_clean.jpg|barcode"

EXTRACTION_POOL=(
    "${REPO_ROOT}/images/not_a_book.jpg|not_a_book"
    "${REPO_ROOT}/images/screenshot_image_reversed.jpg|reversed"
    "${REPO_ROOT}/images/screenshot_image_reversed_and_cut_off.jpg|reversed_cutoff"
    "${REPO_ROOT}/images/screenshot_mildly_obscured.jpg|obscured"
    "${REPO_ROOT}/images/screenshot_mixed_text.jpg|mixed_text"
)
EXTRACTION_POOL_SIZE=${#EXTRACTION_POOL[@]}

if [[ -n "${PROBE_CANARY_REAL_BOOK:-}" ]] || [[ -n "${PROBE_CANARY_NOT_A_BOOK:-}" ]]; then
    BARCODE_CANARY="${PROBE_CANARY_REAL_BOOK:-${REPO_ROOT}/images/barcode_isbn_clean.jpg}|barcode"
    EXTRACTION_POOL=(
        "${PROBE_CANARY_NOT_A_BOOK:-${REPO_ROOT}/images/not_a_book.jpg}|not_a_book"
    )
    EXTRACTION_POOL_SIZE=${#EXTRACTION_POOL[@]}
fi

# Two, down from six. The probe runs 40 iterations (600s window / 15s interval),
# so two per iteration is still 80 vision calls per run and cycles the
# five-image extraction pool sixteen times over — coverage was never the
# constraint. Six meant six A10G containers spun concurrently against a
# max_containers=10 ceiling, on every production deploy, to re-prove a path the
# first iteration has already proven warm.
CANARIES_PER_ITERATION=2

HEALTH_TIMEOUT=10
CATALOGUE_TIMEOUT=10
LOGIN_TIMEOUT=15
BOOKSHELF_TIMEOUT=10
UPLOAD_POST_TIMEOUT=30
UPLOAD_STREAM_TIMEOUT=90
DEPS_CHECK_TIMEOUT=20

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

HEALTH_LOG="$WORK_DIR/health.log"
CATALOGUE_LOG="$WORK_DIR/catalogue.log"
LOGIN_LOG="$WORK_DIR/login.log"
BOOKSHELF_LOG="$WORK_DIR/bookshelf.log"
UPLOAD_LOG="$WORK_DIR/upload.log"
DEPS_CHECK_LOG="$WORK_DIR/deps_check.log"
: > "$HEALTH_LOG" "$CATALOGUE_LOG" "$LOGIN_LOG" "$BOOKSHELF_LOG" "$UPLOAD_LOG" "$DEPS_CHECK_LOG"

_record_sample() {
    local log="$1" status="$2" duration="$3" kind="$4"
    printf '%s\t%s\t%s\n' "$status" "$duration" "$kind" >> "$log"
}

_classify() {
    local exit_code="$1" http_code="$2"
    if [[ "$exit_code" -eq 28 ]]; then
        echo "timeout"
    elif [[ "$exit_code" -ne 0 ]]; then
        echo "error"
    elif [[ "$http_code" =~ ^5[0-9][0-9]$ ]]; then
        echo "http_5xx"
    elif [[ "$http_code" =~ ^4[0-9][0-9]$ ]]; then
        echo "http_4xx"
    elif [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
        echo "ok"
    else
        echo "error"
    fi
}

_now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

probe_health() {
    local t0 t1 http_code exit_code kind
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$HEALTH_TIMEOUT" \
        "$BASE_URL/api/health" 2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$HEALTH_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
}

probe_catalogue() {
    local t0 t1 http_code exit_code kind
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$CATALOGUE_TIMEOUT" \
        "$BASE_URL/api/catalogue?per_page=20" 2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$CATALOGUE_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
}

probe_login() {
    local t0 t1 http_code exit_code kind body_file body token
    body_file="$WORK_DIR/login.body"
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o "$body_file" -w '%{http_code}' \
        --max-time "$LOGIN_TIMEOUT" \
        "$BASE_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${SEED_EMAIL}\",\"password\":\"${SEED_PASSWORD}\"}" \
        2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$LOGIN_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"

    body="$(cat "$body_file" 2>/dev/null || true)"
    token="$(printf '%s' "$body" | python3 -c \
        "import json,sys
try: print(json.load(sys.stdin).get('token','') or '')
except: pass" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
        printf '%s' "$token" > "$WORK_DIR/last_token"
    fi
    rm -f "$body_file"
}

probe_bookshelf() {
    local t0 t1 http_code exit_code kind token
    token=""
    if [[ -f "$WORK_DIR/last_token" ]]; then
        token="$(cat "$WORK_DIR/last_token")"
    fi

    if [[ -z "$token" ]]; then
        t0="$(_now_ms)"
        _record_sample "$BOOKSHELF_LOG" "000" "0" "error"
        return
    fi

    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$BOOKSHELF_TIMEOUT" \
        -H "Authorization: Bearer ${token}" \
        "$BASE_URL/api/bookshelves/library" 2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$BOOKSHELF_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
}

# Drives the presigned upload flow end to end — init, direct PUT, commit —
# and records ONE sample covering the whole chain. Probing a retired
# single-POST endpoint is how the gate once read a healthy launch as 45%
# available: every canary 404'd against a route that no longer existed.
_probe_upload_canary() {
    local canary="$1"
    local canary_name="$2"
    local t0 t1 http_code exit_code kind body_file body token image_id upload_url
    token=""
    if [[ -f "$WORK_DIR/last_token" ]]; then
        token="$(cat "$WORK_DIR/last_token")"
    fi

    if [[ -z "$token" ]] || [[ ! -f "$canary" ]]; then
        t0="$(_now_ms)"
        t1="$t0"
        _record_sample "$UPLOAD_LOG" "000" "0" "error"
        echo "error" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    body_file="$WORK_DIR/upload_${canary_name}.body"
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o "$body_file" -w '%{http_code}' \
        --max-time "$UPLOAD_POST_TIMEOUT" \
        -X POST "$BASE_URL/api/upload/init" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{"content_type":"image/jpeg"}' \
        2>/dev/null)" || true
    exit_code=$?
    kind="$(_classify "$exit_code" "${http_code:-000}")"

    body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"
    image_id="$(printf '%s' "$body" | python3 -c \
        "import json,sys
try: print(json.load(sys.stdin).get('image_id','') or '')
except: pass" 2>/dev/null || true)"
    upload_url="$(printf '%s' "$body" | python3 -c \
        "import json,sys
try: print(json.load(sys.stdin).get('upload_url','') or '')
except: pass" 2>/dev/null || true)"

    if [[ "$kind" != "ok" ]] || [[ -z "$image_id" ]] || [[ -z "$upload_url" ]]; then
        t1="$(_now_ms)"
        _record_sample "$UPLOAD_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
        echo "${kind}" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    # init returns the upload_url RELATIVE (`/api/upload/:id/data` — the
    # app-mediated PUT); resolve it against the base like the SPA does. An
    # absolute URL (a future direct-to-storage presign) passes through.
    if [[ "$upload_url" == /* ]]; then
        upload_url="${BASE_URL}${upload_url}"
    fi

    # Content-Type must match init's or a presigned target rejects the PUT.
    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$UPLOAD_POST_TIMEOUT" \
        -X PUT "$upload_url" \
        -H "Content-Type: image/jpeg" \
        --data-binary "@${canary}" \
        2>/dev/null)" || true
    exit_code=$?
    kind="$(_classify "$exit_code" "${http_code:-000}")"

    if [[ "$kind" != "ok" ]]; then
        t1="$(_now_ms)"
        _record_sample "$UPLOAD_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
        echo "${kind}" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$UPLOAD_POST_TIMEOUT" \
        -X POST "$BASE_URL/api/upload/${image_id}/commit" \
        -H "Authorization: Bearer ${token}" \
        2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$UPLOAD_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"

    if [[ "$kind" != "ok" ]]; then
        echo "${kind}" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    local stream_resp final_status
    stream_resp="$(curl -4 -s --max-time "$UPLOAD_STREAM_TIMEOUT" \
        "$BASE_URL/api/upload/${image_id}/stream?token=${token}" \
        2>/dev/null || true)"
    final_status="$(printf '%s' "$stream_resp" | python3 -c \
        "import json,sys
lines=[l.strip() for l in sys.stdin if l.startswith('data:')]
try:
    d = json.loads(lines[-1][5:]) if lines else {}
    print(d.get('status','timeout'))
except Exception:
    print('timeout')" 2>/dev/null || true)"
    if [[ -z "$final_status" ]]; then
        final_status="timeout"
    fi
    echo "$final_status" > "$WORK_DIR/last_upload_outcome_${canary_name}"
}

EXTRACTION_CURSOR=0

probe_upload() {
    local pids=()
    local slot=0
    local entry path name

    if [[ "$ITERATION_NUM" -eq 1 ]]; then
        path="${BARCODE_CANARY%%|*}"
        name="${BARCODE_CANARY##*|}"
        _probe_upload_canary "$path" "$name" &
        pids+=($!)
        slot=1
    fi

    while [[ "$slot" -lt "$CANARIES_PER_ITERATION" ]]; do
        local idx=$(( EXTRACTION_CURSOR % EXTRACTION_POOL_SIZE ))
        entry="${EXTRACTION_POOL[$idx]}"
        path="${entry%%|*}"
        name="${entry##*|}"
        _probe_upload_canary "$path" "$name" &
        pids+=($!)
        EXTRACTION_CURSOR=$(( EXTRACTION_CURSOR + 1 ))
        slot=$(( slot + 1 ))
    done

    wait "${pids[@]}" 2>/dev/null || true
}

probe_deps_check() {
    if [[ -z "${METRICS_SCRAPE_TOKEN:-}" ]]; then
        return 0
    fi

    local t0 t1 http_code exit_code kind
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o /dev/null -w '%{http_code}' \
        --max-time "$DEPS_CHECK_TIMEOUT" \
        -H "Authorization: Bearer ${METRICS_SCRAPE_TOKEN}" \
        "$BASE_URL/internal/deps-check" 2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$DEPS_CHECK_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"
}

# The invite gate must be ON before anything else is worth measuring. A
# codeless registration must be REFUSED — 403 with "invite_required" — because
# a stack that answers anything else is either misconfigured (gate off: the
# same request would have CREATED an account) or broken in a way that makes the
# latency numbers below meaningless. One-shot assertion, not a sampled probe:
# gate state is a fact, not a distribution.
assert_invite_gate() {
    local http_code body_file body
    body_file="$WORK_DIR/invite_gate.body"
    http_code="$(curl -4 -s -o "$body_file" -w '%{http_code}'         --max-time "$HEALTH_TIMEOUT"         "$BASE_URL/api/auth/register"         -H "Content-Type: application/json"         -d '{"email":"invite-gate-probe@thestacks.test","password":"probe-never-lands"}'         2>/dev/null)" || true
    body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"

    if [[ "$http_code" == "403" ]] && printf '%s' "$body" | grep -q "invite_required"; then
        echo "PASS assert: invite gate is ON (codeless register -> 403 invite_required)"
        return 0
    fi

    # No HTTP answer at all is an OUTAGE, not a gate verdict — and measuring
    # outages is the probe's entire job. Claiming "gate not enforcing" against
    # a black-holed server would be the second misleading message this script
    # family has produced; warn and let the loop do the measuring.
    if [[ -z "$http_code" || "$http_code" == "000" ]]; then
        echo "WARN assert: gate state UNKNOWN — no HTTP answer from the server; continuing so the probe can measure the outage" >&2
        return 0
    fi

    echo "FATAL assert: invite gate is NOT enforcing — codeless register returned" >&2
    echo "       HTTP $http_code: $(printf '%s' "$body" | head -c 200)" >&2
    echo "       A 201 here means the probe just CREATED an account with no invite;" >&2
    echo "       anything but 403/invite_required means the gate is off or broken." >&2
    exit 1
}
assert_invite_gate

START_TS="$(date +%s)"
END_TS=$((START_TS + WINDOW))

echo "error" > "$WORK_DIR/last_upload_outcome"

ITERATION_NUM=0

while :; do
    ITERATION_NUM=$(( ITERATION_NUM + 1 ))
    iter_start="$(date +%s)"

    probe_health &
    pid_h=$!
    probe_catalogue &
    pid_c=$!
    probe_login &
    pid_l=$!
    probe_deps_check &
    pid_d=$!
    wait "$pid_l" 2>/dev/null || true
    probe_bookshelf &
    pid_b=$!
    probe_upload &
    pid_u=$!
    wait "$pid_h" "$pid_c" "$pid_d" "$pid_b" "$pid_u" 2>/dev/null || true

    now="$(date +%s)"
    if [[ "$now" -ge "$END_TS" ]]; then
        break
    fi

    elapsed=$((now - iter_start))
    if [[ "$elapsed" -lt "$INTERVAL" ]]; then
        sleep_for=$((INTERVAL - elapsed))
        remaining=$((END_TS - now))
        if [[ "$sleep_for" -gt "$remaining" ]]; then
            sleep_for="$remaining"
        fi
        if [[ "$sleep_for" -gt 0 ]]; then
            sleep "$sleep_for"
        fi
    fi
done

UPLOAD_OUTCOME_PARTS=()
for entry in "$BARCODE_CANARY" "${EXTRACTION_POOL[@]}"; do
    name="${entry##*|}"
    outcome="$(cat "$WORK_DIR/last_upload_outcome_${name}" 2>/dev/null || echo "-")"
    UPLOAD_OUTCOME_PARTS+=("${name}=${outcome}")
done
UPLOAD_OUTCOME="$(printf '%s,' "${UPLOAD_OUTCOME_PARTS[@]}")"
UPLOAD_OUTCOME="${UPLOAD_OUTCOME%,}"

python3 - "$HEALTH_LOG" "$CATALOGUE_LOG" "$LOGIN_LOG" "$BOOKSHELF_LOG" "$UPLOAD_LOG" "$DEPS_CHECK_LOG" "$UPLOAD_OUTCOME" <<'PY'
import json
import sys

def load(path: str) -> list[tuple[str, int, str]]:
    rows: list[tuple[str, int, str]] = []
    try:
        with open(path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 3:
                    continue
                status, duration, kind = parts
                try:
                    rows.append((status, int(duration), kind))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return rows

def p95(durations: list[int]) -> int:
    if not durations:
        return 0
    s = sorted(durations)
    idx = max(0, min(len(s) - 1, round(0.95 * (len(s) - 1))))
    return int(s[idx])

health = load(sys.argv[1])
catalogue = load(sys.argv[2])
login = load(sys.argv[3])
bookshelf = load(sys.argv[4])
upload = load(sys.argv[5])
deps_check = load(sys.argv[6])
upload_outcome = sys.argv[7] or "error"

all_samples = health + catalogue + login + bookshelf + upload + deps_check
total = len(all_samples)
succeeded = sum(1 for _, _, k in all_samples if k == "ok")
http_5xx_count = sum(1 for _, _, k in all_samples if k == "http_5xx")
http_4xx_count = sum(1 for _, _, k in all_samples if k == "http_4xx")
timeout_count = sum(1 for _, _, k in all_samples if k == "timeout")

availability = (succeeded / total) if total else 0.0

p95_per_probe = {
    "health": p95([d for _, d, k in health if k in ("ok", "http_4xx", "http_5xx")]),
    "catalogue": p95(
        [d for _, d, k in catalogue if k in ("ok", "http_4xx", "http_5xx")]
    ),
    "login": p95([d for _, d, k in login if k in ("ok", "http_4xx", "http_5xx")]),
    "bookshelf": p95(
        [d for _, d, k in bookshelf if k in ("ok", "http_4xx", "http_5xx")]
    ),
    "upload": p95([d for _, d, k in upload if k in ("ok", "http_4xx", "http_5xx")]),
    "deps_check": p95(
        [d for _, d, k in deps_check if k in ("ok", "http_4xx", "http_5xx")]
    ),
}

summary = {
    "availability": round(availability, 4),
    "p95_ms": p95_per_probe,
    "synthetic_probes": {
        "total": total,
        "succeeded": succeeded,
        "p95_ms": p95([d for _, d, _ in all_samples]),
        "http_4xx_count": http_4xx_count,
        "http_5xx_count": http_5xx_count,
        "timeout_count": timeout_count,
    },
    "upload_outcome": upload_outcome,
}

print(
    f"probe summary: availability={availability * 100:.1f}% "
    f"total={total} 4xx={http_4xx_count} 5xx={http_5xx_count} "
    f"timeouts={timeout_count} upload_outcome={upload_outcome}"
)
print("probe-summary-json:", json.dumps(summary))

flat = {
    "availability": summary["availability"],
    "p95_ms_health": summary["p95_ms"]["health"],
    "p95_ms_catalogue": summary["p95_ms"]["catalogue"],
    "p95_ms_login": summary["p95_ms"]["login"],
    "p95_ms_bookshelf": summary["p95_ms"]["bookshelf"],
    "p95_ms_upload": summary["p95_ms"]["upload"],
    "p95_ms_deps_check": summary["p95_ms"]["deps_check"],
    "synthetic_probes_total": summary["synthetic_probes"]["total"],
    "synthetic_probes_succeeded": summary["synthetic_probes"]["succeeded"],
    "synthetic_probes_p95_ms": summary["synthetic_probes"]["p95_ms"],
    "synthetic_probes_http_4xx_count": summary["synthetic_probes"][
        "http_4xx_count"
    ],
    "synthetic_probes_http_5xx_count": summary["synthetic_probes"][
        "http_5xx_count"
    ],
    "synthetic_probes_timeout_count": summary["synthetic_probes"][
        "timeout_count"
    ],
    "upload_outcome": summary["upload_outcome"],
}
print(json.dumps(flat))

any_health_ok = any(k == "ok" for _, _, k in health)
if availability >= 0.99 and any_health_ok:
    sys.exit(0)
sys.exit(1)
PY
