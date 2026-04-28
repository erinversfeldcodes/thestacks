#!/usr/bin/env bash
# scripts/probe-production.sh — synthetic probes for the SLO gate.
#
# Runs a bounded loop against the given base URL, issuing probes in
# parallel every PROBE_INTERVAL_SECONDS for PROBE_WINDOW_SECONDS total:
#   GET  /api/health
#   GET  /api/catalogue?per_page=20
#   POST /api/auth/login          (seed user)
#   GET  /api/bookshelves/library (authenticated; exercises Core.Repo
#                                  via multi-table join to generate the
#                                  sample volume that the gate's
#                                  db_pool_queue_p95_ms SLI needs to
#                                  clear its min_samples floor)
#   POST /api/upload (×6)         six canary images fired in parallel
#                                 per iteration, exercising the full
#                                 identification-path matrix:
#                                  - barcode:         clean ISBN barcode
#                                                     (local_ocr fast path;
#                                                     fires ONCE on the
#                                                     first iteration only —
#                                                     one sample is enough
#                                                     to confirm the fast
#                                                     path still works)
#                                  - not_a_book:      non-book image
#                                                     (Modal classify → reject)
#                                  - reversed:        mirror-reversed cover
#                                  - reversed_cutoff: reversed + cut-off title
#                                  - obscured:        cover with overlay text
#                                  - mixed_text:      multi-book text post
#                                 The 5 extraction canaries rotate to fill
#                                 all 6 slots every iteration (one doubles
#                                 per iteration). Over the gate window
#                                 each extraction class gets ~48 samples;
#                                 barcode gets 1. All terminal outcomes
#                                 feed the upload SLIs.
#   GET  /internal/deps-check     (bearer-gated in-cluster SearXNG probe —
#                                  skipped if METRICS_SCRAPE_TOKEN is unset,
#                                  e.g. in local smoke runs)
#
# Emits a JSON summary to stdout on completion:
#   {
#     "availability": 1.0,
#     "p95_ms": {"health": 180, "catalogue": 240, "login": 320, "bookshelf": 220, "upload": 1700},
#     "synthetic_probes": {
#         "total": 20, "succeeded": 20, "p95_ms": 310,
#         "http_5xx_count": 0, "timeout_count": 0
#     },
#     "upload_outcome": "resolved | rejected | timeout | error"
#   }
#
# Exit 0 iff availability >= 0.99 AND at least one /api/health probe returned 200.
# Exit non-zero otherwise.
#
# Environment variables:
#   PROBE_WINDOW_SECONDS   default 600
#   PROBE_INTERVAL_SECONDS default 15 (halved from 30 to double Core.Repo
#                                      sample count per window — the
#                                      db_pool_queue_p95_ms SLI requires
#                                      50+ samples before gating)
#   METRICS_SCRAPE_TOKEN   bearer for /internal/deps-check. When unset,
#                          the deps-check probe is silently skipped so the
#                          script stays usable in local dev / smoke runs
#                          that don't need the dependency probe.
#   PROBE_SEED_EMAIL       default owner@thestacks.app
#   PROBE_SEED_PASSWORD    default dev-password-123
#
# Usage:
#   scripts/probe-production.sh https://stacks-core.fly.dev

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
# Canary image pool. Each iteration picks TWO canaries (round-robin
# through the pool) and fires them in parallel. Exercising the full
# range of real-world book-identification inputs makes `upload_p95_ms`
# reflect user-perceived latency, not just the best/worst-case pair.
#
# Fixed inputs (each fire once across the loop):
#   - barcode_isbn_clean.jpg          — clean ISBN barcode. Hits
#                                       local_ocr fast path, ~500ms.
#   - not_a_book.jpg                  — non-book image. Modal
#                                       classifies as not_book, ~3s.
#   - screenshot_image_reversed.jpg   — book cover held mirror-
#                                       reversed ("FLYBOYS"). VLM
#                                       must read reversed text.
#   - screenshot_image_reversed_and_cut_off.jpg — reversed + partial
#                                       title ("THE TRAIN to CRYSTAL
#                                       CITY"). Tests cut-off fallback
#                                       in ISBNResolver.search_by_title.
#   - screenshot_mildly_obscured.jpg  — cover with caption overlay
#                                       ("BORN AGAIN BODIES by Marie
#                                       Griffith"). VLM must read
#                                       around obstructions.
#   - screenshot_mixed_text.jpg       — Instagram post with multiple
#                                       books named in text. VLM
#                                       extracts all, pipeline resolves
#                                       each via ISBNResolver.
#
# The "real book" canary used to be `images/photo.PNG` which turned
# out to be a HEIF file mislabelled with a `.PNG` extension; PIL on the
# vision service can't read HEIF without `pillow-heif` so every upload
# 502'd. Tracked in Issue #141.
# Barcode is the "fast-path" canary — it hits local_ocr and never touches
# Modal. One sample is enough to prove the fast path still works; burning
# a slot on it every iteration wastes Modal-bound capacity.
BARCODE_CANARY="${REPO_ROOT}/images/barcode_isbn_clean.jpg|barcode"

# Extraction canaries — all exercise Modal + ISBNResolver paths, which is
# what `upload_p95_ms` actually measures. These fill every slot on every
# iteration so we get ~50 samples per canary class over the gate window
# (40 iterations × 6 slots / 5 canaries ≈ 48 each).
EXTRACTION_POOL=(
    "${REPO_ROOT}/images/not_a_book.jpg|not_a_book"
    "${REPO_ROOT}/images/screenshot_image_reversed.jpg|reversed"
    "${REPO_ROOT}/images/screenshot_image_reversed_and_cut_off.jpg|reversed_cutoff"
    "${REPO_ROOT}/images/screenshot_mildly_obscured.jpg|obscured"
    "${REPO_ROOT}/images/screenshot_mixed_text.jpg|mixed_text"
)
EXTRACTION_POOL_SIZE=${#EXTRACTION_POOL[@]}

# Back-compat overrides — respected if set, used only for tests that
# want to pin the canary choice.
if [[ -n "${PROBE_CANARY_REAL_BOOK:-}" ]] || [[ -n "${PROBE_CANARY_NOT_A_BOOK:-}" ]]; then
    BARCODE_CANARY="${PROBE_CANARY_REAL_BOOK:-${REPO_ROOT}/images/barcode_isbn_clean.jpg}|barcode"
    EXTRACTION_POOL=(
        "${PROBE_CANARY_NOT_A_BOOK:-${REPO_ROOT}/images/not_a_book.jpg}|not_a_book"
    )
    EXTRACTION_POOL_SIZE=${#EXTRACTION_POOL[@]}
fi

# Number of canary slots fired in parallel per iteration. 6 matches
# `max_inputs=8` on Modal's VisionModel with room for retries.
CANARIES_PER_ITERATION=6

# Short per-probe timeouts so a hung backend cannot stretch a single iteration
# beyond the interval. The upload outcome poll has its own longer budget.
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

# Records one sample as: "<status>\t<duration_ms>\t<kind>"
# kind ∈ ok | http_5xx | http_4xx | timeout | error
_record_sample() {
    local log="$1" status="$2" duration="$3" kind="$4"
    printf '%s\t%s\t%s\n' "$status" "$duration" "$kind" >> "$log"
}

# Classify a curl outcome. curl exit 28 = timeout. Non-zero exit without 28
# is a connection error. HTTP 5xx is a server error. Otherwise ok.
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

# Millisecond wall clock via Python (portable across macOS/Linux where
# `date +%s%N` is unreliable on BSD date).
_now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

# ── Probe: GET /api/health ───────────────────────────────────────────────────
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

# ── Probe: GET /api/catalogue?per_page=20 ────────────────────────────────────
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

# ── Probe: POST /api/auth/login ──────────────────────────────────────────────
# Writes the token to WORK_DIR/last_token so the upload probe can reuse it.
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

# ── Probe: GET /api/bookshelves/library ──────────────────────────────────────
# Authenticated read that exercises op.bookshelves + op.bookshelf_placements
# + op.books joins. Each call issues several Core.Repo queries — the main
# lever for keeping the db_pool_queue_p95_ms SLI above its min_samples
# floor across the 10-min gate window. Skipped when no login token has
# landed yet (the probe can still record "error" so availability accounts
# for token outages instead of silently dropping the sample).
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

# ── Probe: POST /api/upload (canary) ─────────────────────────────────────────
# Measures the POST's latency + status. The final outcome (resolved /
# rejected / timeout) is streamed via SSE and stored per-canary in
# WORK_DIR/last_upload_outcome_<name> for the summary. If no image or no
# token, outcome is "error".
_probe_upload_canary() {
    local canary="$1"
    local canary_name="$2"
    local t0 t1 http_code exit_code kind body_file body token image_id
    token=""
    if [[ -f "$WORK_DIR/last_token" ]]; then
        token="$(cat "$WORK_DIR/last_token")"
    fi

    if [[ -z "$token" ]] || [[ ! -f "$canary" ]]; then
        # Record as error but still account for it — the gate may still pass
        # if availability across all probes is high enough.
        t0="$(_now_ms)"
        t1="$t0"
        _record_sample "$UPLOAD_LOG" "000" "0" "error"
        echo "error" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    # Per-canary body file so parallel uploads don't clobber each other.
    body_file="$WORK_DIR/upload_${canary_name}.body"
    t0="$(_now_ms)"
    http_code="$(curl -4 -s -o "$body_file" -w '%{http_code}' \
        --max-time "$UPLOAD_POST_TIMEOUT" \
        -X POST "$BASE_URL/api/upload" \
        -H "Authorization: Bearer ${token}" \
        -F "image=@${canary}" \
        2>/dev/null)" || true
    exit_code=$?
    t1="$(_now_ms)"
    kind="$(_classify "$exit_code" "${http_code:-000}")"
    _record_sample "$UPLOAD_LOG" "${http_code:-000}" "$((t1 - t0))" "$kind"

    body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"
    image_id="$(printf '%s' "$body" | python3 -c \
        "import json,sys
try: print(json.load(sys.stdin).get('image_id','') or '')
except: pass" 2>/dev/null || true)"

    if [[ -z "$image_id" ]] || [[ "$kind" != "ok" ]]; then
        echo "${kind}" > "$WORK_DIR/last_upload_outcome_${canary_name}"
        return
    fi

    # Stream the final outcome. SSE lines are `data: {...}`; the final
    # message's status is our outcome (resolved | rejected | timeout).
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

# Round-robin cursor through EXTRACTION_POOL so samples are spread
# evenly across the 5 canary classes over the gate window.
EXTRACTION_CURSOR=0

# Each iteration fires CANARIES_PER_ITERATION canaries in parallel:
#   * The FIRST iteration fires the barcode canary once (proves the
#     local_ocr fast path still works) + extraction canaries for the
#     remaining slots.
#   * Every subsequent iteration fires extraction canaries only,
#     advancing the cursor by CANARIES_PER_ITERATION per iteration so
#     the pool is rotated cleanly.
#
# Net per 600s / 15s / 40-iteration window:
#   * barcode: 1 sample (smoke test only)
#   * each extraction canary: ~48 samples
# That's enough per-class volume for the upload_p95 to converge while
# keeping Oban's :vision queue (concurrency 5) productively busy — 6
# simultaneous arrivals means 1 queues per iteration, realistic stress.
probe_upload() {
    local pids=()
    local slot=0
    local entry path name

    if [[ "$ITERATION_NUM" -eq 1 ]]; then
        # Fire barcode once, in the first slot of the first iteration.
        path="${BARCODE_CANARY%%|*}"
        name="${BARCODE_CANARY##*|}"
        _probe_upload_canary "$path" "$name" &
        pids+=($!)
        slot=1
    fi

    # Fill remaining slots from the extraction pool, advancing the cursor.
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

# ── Probe: GET /internal/deps-check ──────────────────────────────────────────
# Synchronously exercises in-cluster dependencies that the other probes don't
# reach (currently just SearXNG; the endpoint is extensible). Short-circuits
# when METRICS_SCRAPE_TOKEN is unset so local smoke runs without the token
# don't record spurious 401s against availability.
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

# ── Main sampling loop ───────────────────────────────────────────────────────
START_TS="$(date +%s)"
END_TS=$((START_TS + WINDOW))

# Initial outcome: will be overwritten by the first successful upload probe.
echo "error" > "$WORK_DIR/last_upload_outcome"

# 1-indexed iteration counter, read by probe_upload to decide whether
# to fire the barcode canary (only on the first iteration).
ITERATION_NUM=0

while :; do
    ITERATION_NUM=$(( ITERATION_NUM + 1 ))
    iter_start="$(date +%s)"

    # Fire all four probes in parallel. Login runs first to populate the token,
    # but we still race it with the others — upload uses the token from the
    # PREVIOUS iteration (or the current if it races ahead). That is fine for
    # a constant-denominator synthetic probe — we just need consistent counts.
    probe_health &
    pid_h=$!
    probe_catalogue &
    pid_c=$!
    probe_login &
    pid_l=$!
    probe_deps_check &
    pid_d=$!
    # Wait for login so the upload + bookshelf probes have a fresh token.
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

    # Sleep up to the interval boundary; if the probes took longer than the
    # interval, proceed immediately (best-effort — a stuck backend shouldn't
    # pile up sleeps).
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

# ── Summarise ────────────────────────────────────────────────────────────────
# Roll up per-canary last-seen outcomes into a compact string for the
# observation blob. Format: `name1=outcome1,name2=outcome2,...` in the
# order: barcode (if fired) first, then extraction canaries. Downstream
# consumers treat this as opaque human-readable text — the authoritative
# success signal is `stacks_upload_terminal_count_total` scraped from
# metrics, not this string.
UPLOAD_OUTCOME_PARTS=()
for entry in "$BARCODE_CANARY" "${EXTRACTION_POOL[@]}"; do
    name="${entry##*|}"
    outcome="$(cat "$WORK_DIR/last_upload_outcome_${name}" 2>/dev/null || echo "-")"
    UPLOAD_OUTCOME_PARTS+=("${name}=${outcome}")
done
# Join with commas. `printf` + parameter trim avoids tampering with the
# shell-global IFS (semgrep bash.lang.security.ifs-tampering); a stray
# IFS leak into a later subshell would silently corrupt unquoted-array
# expansions or `read` calls elsewhere in the script.
UPLOAD_OUTCOME="$(printf '%s,' "${UPLOAD_OUTCOME_PARTS[@]}")"
UPLOAD_OUTCOME="${UPLOAD_OUTCOME%,}"

# Emit the final JSON via Python for correctness (quoting, nan handling, etc.)
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
    # Rank-interpolation: position = 0.95 * (N-1).
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
# Availability treats 1xx/2xx/3xx as success; 4xx AND 5xx as failure. Timeouts
# and connection errors also count as failures. The prior implementation only
# penalised 5xx, which let a wave of 401s (seed creds rotated, token expired)
# silently pass the gate — reviewer P1 #3.
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

# Human-readable banner before the JSON blob so CI logs show availability at a
# glance without requiring JSON tooling to parse.
print(
    f"probe summary: availability={availability * 100:.1f}% "
    f"total={total} 4xx={http_4xx_count} 5xx={http_5xx_count} "
    f"timeouts={timeout_count} upload_outcome={upload_outcome}"
)
# Emit the full structured summary for programmatic consumers (the gate
# reads it via PROBE_SUMMARY_FIXTURE, not by parsing stdout).
print("probe-summary-json:", json.dumps(summary))

# Emit a flat final blob whose outermost `{` is the LAST `{` in stdout — so
# the brace-balanced heuristic used by the test harness extracts the whole
# object (not one of the nested sub-objects). The flat blob has no nested
# objects and no escaped `{` inside string values, so its outer `{` is truly
# the final `{` in stdout. Required substrings — "availability", "p95_ms",
# "synthetic_probes", "timeout" — all appear as key names.
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

# Gate for exit code: require ≥99% availability AND at least one 200 health.
any_health_ok = any(k == "ok" for _, _, k in health)
if availability >= 0.99 and any_health_ok:
    sys.exit(0)
sys.exit(1)
PY
