#!/usr/bin/env bash
# scripts/dashboard-smoke.sh — deploy-time "would the dashboards render?" gate.
#
# The fear this closes (owner's words): "avoid finding that Grafana's
# connectivity to Prometheus is down when I go and find an empty dashboard."
#
# After the preview E2E run has emitted every metric family and Fly's managed
# Prometheus has scraped the preview app, this script proves TWO things live,
# before anyone opens Grafana:
#
#   1. CONNECTIVITY — Grafana can actually reach its Prometheus datasource.
#      Asserted via Grafana's datasource health endpoint
#      (GET ${GRAFANA_HOST}/api/datasources/uid/<uid>/health). A dead datasource
#      fails here, loudly, with the datasource uid named.
#
#   2. PANELS RENDER DATA — for every data panel in apps/core/priv/grafana/*.json
#      we take the panel's real PromQL (`targets[].expr`), substitute the `$app`
#      template var with THIS preview app, and evaluate it — PREFERABLY through
#      Grafana's own datasource-proxy (POST ${GRAFANA_HOST}/api/ds/query, i.e. the
#      exact Grafana→Prometheus path a panel uses), falling back to Fly's
#      managed-Prometheus HTTP API (GET .../api/v1/query, the #241 endpoint) only
#      if the Grafana query path is unreachable. A NON-EMPTY result means the
#      panel would render real data, not a blank.
#
# Scoping: every query is pinned to `{app="<preview-app>"}` (via the `$app`
# substitution) so a preview panel that emitted nothing can NOT be masked by
# prod / other-preview series living in the same org-wide Prometheus.
#
# Scrape/ingest lag: Fly's scrape is periodic and `rate(...[5m])` needs >=2
# samples, so an empty result right after E2E is expected-transient. Each still-
# empty query is retried with a bounded backoff (default ~90s total budget,
# shared across panels) before it is declared a real EMPTY failure.
#
# Exit code: non-zero if connectivity fails OR any panel is still empty after
# retries. A clear per-panel PASS/EMPTY summary is always printed.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   scripts/dashboard-smoke.sh <preview-app-name>
#   scripts/dashboard-smoke.sh --dry-run [<app-name>]     # no network; prints
#                                                           # the substituted,
#                                                           # app-scoped queries
#
# App name resolution (first non-empty wins): positional arg → $PREVIEW_CORE_APP
# → $CORE_APP. Dry-run defaults the app to "DRYRUN_APP" if none is given.
#
# ── Env ──────────────────────────────────────────────────────────────────────
#   GRAFANA_HOST              Base URL of the org Grafana (fly-metrics.net).
#   GRAFANA_AUTH_TOKEN        Grafana service-account token (Bearer).
#   FLY_PROMETHEUS_READ_TOKEN Fly managed-Prometheus read token (raw `FlyV1 …`
#                             macaroon from `fly tokens create readonly`; sent
#                             as the whole Authorization value, not `Bearer`).
#   FLY_PROMETHEUS_ORG        Fly org slug (path component of the query URL).
#   GRAFANA_DATASOURCE_UID    Datasource uid the panels query. Default
#                             "prometheus" — MUST match the `uid` the dashboard
#                             JSON hard-codes (Core.PromEx dashboard_assigns/0),
#                             else the dashboards render blank regardless of
#                             connectivity, which this check will surface.
#   DASHBOARD_DIR             Dir of dashboard JSON. Default apps/core/priv/grafana.
#   DASHBOARD_SMOKE_RETRY_SECONDS  Total retry budget in seconds. Default 90.
#   DASHBOARD_SMOKE_RATE_INTERVAL  Concrete value substituted for
#                             $__rate_interval / $__interval. Default 5m.
#   FLY_PROMETHEUS_BASE_URL   Override the Fly Prometheus base (tests). Default
#                             https://api.fly.io/prometheus.

set -uo pipefail

# ── Arg / env resolution (bash side; the heavy lifting is the python worker) ──
MODE="live"
APP_ARG=""

while (($#)); do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      ;;
    -h | --help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
      exit 0
      ;;
    --*)
      echo "FATAL: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      APP_ARG="$1"
      ;;
  esac
  shift
done

APP_NAME="${APP_ARG:-${PREVIEW_CORE_APP:-${CORE_APP:-}}}"

if [[ "${MODE}" == "dry-run" ]]; then
  APP_NAME="${APP_NAME:-DRYRUN_APP}"
else
  if [[ -z "${APP_NAME}" ]]; then
    echo "FATAL: no target app name (pass as arg or set PREVIEW_CORE_APP / CORE_APP)" >&2
    exit 2
  fi
  # Required-secret preflight for live mode. Fail before any network call so the
  # operator gets one clear message, not N confusing per-panel errors.
  missing=()
  for var in GRAFANA_HOST GRAFANA_AUTH_TOKEN FLY_PROMETHEUS_READ_TOKEN FLY_PROMETHEUS_ORG; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if ((${#missing[@]})); then
    echo "FATAL: missing required env for live smoke: ${missing[*]}" >&2
    echo "       (run with --dry-run to validate query extraction offline)" >&2
    exit 2
  fi
fi

# Resolve dashboard dir relative to the repo root (this script's ../).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DASHBOARD_DIR="${DASHBOARD_DIR:-${REPO_ROOT}/apps/core/priv/grafana}"

if [[ ! -d "${DASHBOARD_DIR}" ]]; then
  echo "FATAL: dashboard dir not found: ${DASHBOARD_DIR}" >&2
  exit 2
fi

export DASHBOARD_SMOKE_MODE="${MODE}"
export DASHBOARD_SMOKE_APP="${APP_NAME}"
export DASHBOARD_DIR
export GRAFANA_DATASOURCE_UID="${GRAFANA_DATASOURCE_UID:-prometheus}"
export DASHBOARD_SMOKE_RETRY_SECONDS="${DASHBOARD_SMOKE_RETRY_SECONDS:-90}"
export DASHBOARD_SMOKE_RATE_INTERVAL="${DASHBOARD_SMOKE_RATE_INTERVAL:-5m}"
export FLY_PROMETHEUS_BASE_URL="${FLY_PROMETHEUS_BASE_URL:-https://api.fly.io/prometheus}"

# The whole extract → substitute → query → retry → report pipeline lives in
# python3 (guaranteed in the deploy-preview job via actions/setup-python; stdlib
# only — urllib + json, no pip installs). It reads its config from the exported
# env above and returns 0 (all good), 1 (a real failure), or 2 (bad config).
python3 <<'PYWORKER'
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MODE = os.environ["DASHBOARD_SMOKE_MODE"]
APP = os.environ["DASHBOARD_SMOKE_APP"]
DASH_DIR = os.environ["DASHBOARD_DIR"]
DS_UID = os.environ.get("GRAFANA_DATASOURCE_UID", "prometheus")
RATE_INTERVAL = os.environ.get("DASHBOARD_SMOKE_RATE_INTERVAL", "5m")
RETRY_BUDGET = float(os.environ.get("DASHBOARD_SMOKE_RETRY_SECONDS", "90"))

GRAFANA_HOST = (os.environ.get("GRAFANA_HOST") or "").rstrip("/")
GRAFANA_TOKEN = os.environ.get("GRAFANA_AUTH_TOKEN") or ""
FLY_TOKEN = os.environ.get("FLY_PROMETHEUS_READ_TOKEN") or ""
FLY_ORG = os.environ.get("FLY_PROMETHEUS_ORG") or ""
FLY_BASE = (os.environ.get("FLY_PROMETHEUS_BASE_URL") or "https://api.fly.io/prometheus").rstrip("/")

HTTP_TIMEOUT = 15


# ── Dashboard → panel → query extraction ──────────────────────────────────────
def walk_panels(node):
    """Every panel, including panels nested inside collapsed 'row' panels."""
    out = []
    for panel in node.get("panels", []) or []:
        out.append(panel)
        out.extend(walk_panels(panel))
    return out


def substitute(expr):
    """Make a panel's PromQL concrete + app-scoped.

    - $app / ${app}                → the target (preview) app name, so the query
      is pinned to {app="<app>"} and can't be masked by other apps' series.
    - $__rate_interval / $__interval (and ${...} forms) → a concrete window, so
      the query is valid outside Grafana's macro interpolation and rate() has a
      real lookback.
    """
    replacements = [
        ("${app}", APP),
        ("$app", APP),
        ("${__rate_interval}", RATE_INTERVAL),
        ("$__rate_interval", RATE_INTERVAL),
        ("${__interval}", RATE_INTERVAL),
        ("$__interval", RATE_INTERVAL),
    ]
    out = expr
    for needle, value in replacements:
        out = out.replace(needle, value)
    return out


def collect_queries():
    """List of {dashboard, panel, refId, raw_expr, query} for every data panel."""
    queries = []
    paths = sorted(glob.glob(os.path.join(DASH_DIR, "*.json")))
    if not paths:
        print(f"FATAL: no dashboard JSON found in {DASH_DIR}", file=sys.stderr)
        sys.exit(2)
    for path in paths:
        name = os.path.basename(path)
        with open(path) as fh:
            dashboard = json.load(fh)
        for panel in walk_panels(dashboard):
            if panel.get("type") == "row":
                continue  # row separators render no data
            title = panel.get("title") or f"id={panel.get('id')}"
            for target in panel.get("targets", []) or []:
                expr = target.get("expr")
                if not isinstance(expr, str) or not expr.strip():
                    continue
                queries.append(
                    {
                        "dashboard": name,
                        "panel": title,
                        "refId": target.get("refId", "?"),
                        "raw_expr": expr,
                        "query": substitute(expr),
                    }
                )
    return queries


# ── HTTP helpers (stdlib only) ────────────────────────────────────────────────
def _request(url, *, headers, data=None, method="GET"):
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def grafana_datasource_health():
    """Assert Grafana reports the Prometheus datasource healthy.

    Returns (ok: bool, detail: str). ok=False means Grafana can't reach
    Prometheus (or the uid the dashboards use doesn't exist) — the exact
    'blank dashboard' cause the owner wants caught before it bites.
    """
    url = f"{GRAFANA_HOST}/api/datasources/uid/{urllib.parse.quote(DS_UID)}/health"
    headers = {"Authorization": f"Bearer {GRAFANA_TOKEN}", "Accept": "application/json"}
    try:
        status, body = _request(url, headers=headers)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False, _explain_missing_datasource()
        return False, f"HTTP {exc.code} from datasource health endpoint: {exc.read()[:300]!r}"
    except urllib.error.URLError as exc:
        return False, f"could not reach Grafana at {GRAFANA_HOST}: {exc.reason}"
    if status != 200:
        return False, f"unexpected HTTP {status} from datasource health endpoint"
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return False, f"non-JSON health response: {body[:300]!r}"
    # Grafana health payload: {"status":"OK"|"ERROR","message":"..."}
    ds_status = str(payload.get("status", "")).upper()
    message = payload.get("message", "")
    if ds_status == "OK":
        return True, message or "OK"
    return False, f"datasource '{DS_UID}' reports {ds_status or 'no status'}: {message}"


def _explain_missing_datasource():
    """404 on the health endpoint → the uid the dashboards hard-code is absent.
    List the org's datasources so the operator sees what uid to use instead."""
    detail = (
        f"Grafana has no datasource with uid '{DS_UID}'. The dashboard JSON "
        f"(apps/core/priv/grafana/*.json) hard-codes this uid, so every panel "
        f"would render blank until it matches the org's real Prometheus "
        f"datasource uid."
    )
    try:
        _, body = _request(
            f"{GRAFANA_HOST}/api/datasources",
            headers={"Authorization": f"Bearer {GRAFANA_TOKEN}", "Accept": "application/json"},
        )
        found = [
            f"{ds.get('name')!r} (type={ds.get('type')}, uid={ds.get('uid')!r})"
            for ds in json.loads(body)
        ]
        if found:
            detail += " Datasources present: " + "; ".join(found)
    except Exception:  # discovery is best-effort; the primary failure stands
        pass
    return detail


def query_via_grafana(query):
    """Evaluate an instant query THROUGH Grafana's datasource proxy — the real
    Grafana→Prometheus path a panel uses.

    Returns (state, detail) where state is one of:
      "nonempty" — data present,
      "empty"    — query ran, no series,
      "transport"— Grafana query path unusable (fall back to Fly-direct).
    """
    url = f"{GRAFANA_HOST}/api/ds/query"
    body = json.dumps(
        {
            "queries": [
                {
                    "refId": "A",
                    "datasource": {"type": "prometheus", "uid": DS_UID},
                    "expr": query,
                    "instant": True,
                    "range": False,
                    "maxDataPoints": 1,
                }
            ],
            "from": "now-15m",
            "to": "now",
        }
    ).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {GRAFANA_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    try:
        _, raw = _request(url, headers=headers, data=body, method="POST")
    except urllib.error.HTTPError as exc:
        # A 4xx/5xx on the query MECHANISM (not a normal empty result) → the
        # Grafana query path is impractical; signal a fall back to Fly-direct.
        return "transport", f"HTTP {exc.code}: {exc.read()[:200]!r}"
    except urllib.error.URLError as exc:
        return "transport", f"{exc.reason}"
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return "transport", f"non-JSON: {raw[:200]!r}"
    result = (payload.get("results") or {}).get("A") or {}
    if result.get("error") or result.get("status", 200) >= 400:
        return "transport", f"result error: {result.get('error') or result.get('status')}"
    for frame in result.get("frames") or []:
        for column in (frame.get("data") or {}).get("values") or []:
            if column:  # any non-empty column ⇒ at least one sample
                return "nonempty", "grafana"
    return "empty", "grafana"


def query_via_fly(query):
    """Fallback: evaluate the instant query against Fly's managed-Prometheus
    HTTP API directly (the #241 Stacks.Transparency.Prometheus endpoint)."""
    url = f"{FLY_BASE}/{FLY_ORG}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    # Fly's managed-Prometheus proxy expects the macaroon token as the whole
    # Authorization value — `fly tokens create readonly` mints `FlyV1 fm2_…`,
    # where `FlyV1` is itself the auth scheme. Wrapping it in `Bearer ` is
    # rejected with 401. Only fall back to `Bearer ` for a non-macaroon PAT.
    auth = FLY_TOKEN if FLY_TOKEN.startswith("FlyV1") else f"Bearer {FLY_TOKEN}"
    headers = {"Authorization": auth, "Accept": "application/json"}
    try:
        _, raw = _request(url, headers=headers)
    except urllib.error.HTTPError as exc:
        return "transport", f"HTTP {exc.code}: {exc.read()[:200]!r}"
    except urllib.error.URLError as exc:
        return "transport", f"{exc.reason}"
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return "transport", f"non-JSON: {raw[:200]!r}"
    if payload.get("status") != "success":
        return "transport", f"prometheus status: {payload.get('status')} {payload.get('error','')}"
    result = (payload.get("data") or {}).get("result") or []
    return ("nonempty", "fly") if result else ("empty", "fly")


# ── Dry-run: print the app-scoped queries, no network ─────────────────────────
def run_dry():
    queries = collect_queries()
    print(f"[dry-run] app-scoped queries for app={APP!r} "
          f"($__rate_interval→{RATE_INTERVAL}) across {DASH_DIR}\n")
    current = None
    for q in queries:
        if q["dashboard"] != current:
            current = q["dashboard"]
            print(f"── {current} ──")
        print(f"  [{q['refId']}] {q['panel']}")
        print(f"      {q['query']}")
    print(f"\n[dry-run] {len(queries)} panel queries extracted; "
          "no API calls made. Live validation needs a preview deploy.")
    return 0


# ── Live: connectivity + per-panel data, with a shared retry budget ───────────
def run_live():
    print(f"== Dashboard render + connectivity smoke ==")
    print(f"   app={APP}  datasource-uid={DS_UID}  grafana={GRAFANA_HOST}")
    print(f"   fly-prometheus-org={FLY_ORG}  retry-budget={RETRY_BUDGET:.0f}s\n")

    # (1) Connectivity — the dead-datasource fear.
    print("[1/2] Grafana → Prometheus connectivity ...")
    ok, detail = grafana_datasource_health()
    if not ok:
        print(f"  FAIL: {detail}")
        print("\nSUMMARY: connectivity check FAILED — Grafana cannot reach "
              "Prometheus (dashboards would be blank). Not proceeding to panels.")
        return 1
    print(f"  PASS: datasource '{DS_UID}' healthy ({detail})\n")

    # (2) Panels render data — prefer through-Grafana, fall back to Fly-direct.
    queries = collect_queries()
    print(f"[2/2] {len(queries)} data-panel queries (app-scoped to {APP!r}) ...")

    # Probe once through Grafana; if the query PATH is unusable, do the whole
    # run against Fly-direct (connectivity is already proven above).
    backend = "grafana"
    if queries:
        state, why = query_via_grafana(queries[0]["query"])
        if state == "transport":
            print(f"  note: Grafana /api/ds/query path unusable ({why}); "
                  "falling back to Fly managed-Prometheus direct for all panels.")
            backend = "fly"

    def evaluate(query):
        if backend == "grafana":
            state, why = query_via_grafana(query)
            if state == "transport":
                # Per-query Grafana hiccup — try Fly-direct rather than fail hard.
                return query_via_fly(query)
            return state, why
        return query_via_fly(query)

    # First pass.
    pending = []
    for q in queries:
        state, why = evaluate(q["query"])
        q["state"], q["why"] = state, why
        if state != "nonempty":
            pending.append(q)

    # Retry only the still-empty ones, sharing the total budget with a bounded
    # backoff (scrape lag + rate() needing >=2 samples means early-empty is
    # expected-transient).
    deadline = time.monotonic() + RETRY_BUDGET
    delay = 5.0
    while pending and time.monotonic() < deadline:
        wait = min(delay, max(0.0, deadline - time.monotonic()))
        print(f"  {len(pending)} panel(s) still empty — retrying in {wait:.0f}s "
              f"({max(0.0, deadline - time.monotonic()):.0f}s budget left) ...")
        time.sleep(wait)
        still = []
        for q in pending:
            state, why = evaluate(q["query"])
            q["state"], q["why"] = state, why
            if state != "nonempty":
                still.append(q)
        pending = still
        delay = min(delay * 1.5, 20.0)

    # Report.
    print("\n── Per-panel result ──")
    failures = []
    current = None
    for q in queries:
        if q["dashboard"] != current:
            current = q["dashboard"]
            print(f"  {current}")
        mark = "PASS " if q["state"] == "nonempty" else "EMPTY"
        print(f"    [{mark}] {q['panel']} ({q['refId']}) — via {q.get('why','')}")
        if q["state"] != "nonempty":
            failures.append(q)

    total = len(queries)
    passed = total - len(failures)
    print(f"\nSUMMARY: connectivity PASS · panels {passed}/{total} rendered data "
          f"via {backend}.")
    if failures:
        print("Empty panels after retries (would render blank for this preview):")
        for q in failures:
            print(f"  • [{q['dashboard']}] {q['panel']} ({q['refId']}): {q['state']} "
                  f"— {q.get('why','')}")
            print(f"      query: {q['query']}")
        return 1
    return 0


if __name__ == "__main__":
    if MODE == "dry-run":
        sys.exit(run_dry())
    sys.exit(run_live())
PYWORKER
