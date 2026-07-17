#!/usr/bin/env bash
# Dashboard RENDER gate (ADR-021 / Epic #249 completion requirement).
#
# The drift + label-validation tests are STRUCTURAL — they never evaluate a query,
# so they pass while every panel is blank. This gate closes that: it evaluates
# EVERY dashboard panel's real PromQL against a live VictoriaMetrics and asserts a
# non-empty result. It fails the build on any blank panel or malformed PromQL.
#
# How it stays deterministic (no app, no scrape timing): it parses each panel's
# query, harvests the metric names + label matchers + histogram structure the
# panels themselves declare, synthesizes minimally well-formed series (≥2 timepoints
# so rate()/increase() evaluate; _bucket/_sum/_count with `le` for histograms),
# imports them to VM, then runs every panel query. This proves the PromQL is valid
# and renders given data shaped the way the panel asks for. (Emission FIDELITY —
# that the app emits those exact label values — is covered by the *_telemetry_test
# suites + label-validation, and by the CI preview VM emission smoke against the real VM.)
#
# Usage:
#   just observe                 # bring up the local VM+Grafana stack first
#   scripts/dashboard-render-gate.sh
#
# Env:
#   RENDER_GATE_VM   VictoriaMetrics base URL. Default http://localhost:8428.
#   DASHBOARD_DIR    Dashboard JSON dir. Default apps/core/priv/grafana.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
export RENDER_GATE_VM="${RENDER_GATE_VM:-http://localhost:8428}"
export DASHBOARD_DIR="${DASHBOARD_DIR:-${REPO_ROOT}/apps/core/priv/grafana}"

# Preflight: VM reachable?
if ! curl -sf -o /dev/null "${RENDER_GATE_VM}/health" 2>/dev/null; then
  echo "FATAL: VictoriaMetrics not reachable at ${RENDER_GATE_VM}." >&2
  echo "       Start the local stack first:  just observe" >&2
  exit 2
fi

python3 <<'PYGATE'
import glob, json, os, re, sys, time, urllib.request, urllib.parse, urllib.error

VM = os.environ["RENDER_GATE_VM"].rstrip("/")
DASH_DIR = os.environ["DASHBOARD_DIR"]
APP = "rendergate"
RATE_INTERVAL = "1m"

# ── extract (dashboard, panel, refId, expr) ───────────────────────────────────
def walk(node, out):
    if isinstance(node, dict):
        if node.get("type") not in (None, "row", "text"):
            for t in node.get("targets", []) or []:
                e = t.get("expr")
                if e:
                    out.append((node.get("title") or "?", t.get("refId") or "A", e))
        for v in node.values():
            walk(v, out)
    elif isinstance(node, list):
        for x in node:
            walk(x, out)

def subst(expr):
    expr = expr.replace("$__rate_interval", RATE_INTERVAL).replace("$__interval", RATE_INTERVAL)
    expr = expr.replace("$app", APP).replace("${app}", APP)
    return expr

panels = []
for path in sorted(glob.glob(os.path.join(DASH_DIR, "*.json"))):
    d = json.load(open(path))
    raw = []
    walk(d.get("panels", []), raw)
    for title, refid, expr in raw:
        panels.append({"dash": os.path.basename(path), "panel": title,
                       "refId": refid, "expr": subst(expr)})

if not panels:
    print("FATAL: no panel queries found under", DASH_DIR); sys.exit(2)

# ── harvest metrics + matchers from the queries ───────────────────────────────
# metric name: stacks_* / fly_*, optionally followed by {label="v",label=~"a|b"}.
SEL = re.compile(r'\b((?:stacks|fly)_[a-zA-Z0-9_]+)\b(?:\s*\{([^}]*)\})?')
MATCH = re.compile(r'(\w+)\s*(=~|!~|!=|=)\s*"([^"]*)"')

# per base-metric → {label: set(values)} and whether it's a histogram (has _bucket)
metrics = {}          # base_name -> {"labels": {k:set()}, "hist": bool}
def note(name, labels_str):
    base = name
    hist = False
    if name.endswith("_bucket"):
        base, hist = name[:-7], True
    elif name.endswith("_sum") or name.endswith("_count"):
        base = name.rsplit("_", 1)[0]
    m = metrics.setdefault(base, {"labels": {}, "hist": False})
    if hist:
        m["hist"] = True
    for lk, op, lv in MATCH.findall(labels_str or ""):
        if lk in ("le",):  # synthesized ourselves for histograms
            continue
        val = lv
        if op in ("=~", "!~"):        # regex matcher → pick first literal alternative
            val = re.split(r'[|(]', lv)[0].strip("^$()") or "v"
        m["labels"].setdefault(lk, set())
        if op in ("=", "=~"):
            m["labels"][lk].add(val)

for p in panels:
    for name, labels in SEL.findall(p["expr"]):
        # skip promql function-ish tokens that can't be metrics (none start with stacks_/fly_)
        note(name, labels)

# ── synthesize well-formed series & import to VM ──────────────────────────────
# Seed a DENSE series over the 2 min BEFORE a fixed instant T, then evaluate every
# panel at time=T. Dense (every 20s) so rate()/increase() over [1m] always has ≥2
# points strictly inside the (T-60s, T] half-open window. Fixed T (not wall-clock
# now) so the 52-query loop's duration and any staleness are irrelevant.
# Seed points at T-150..T-50 and evaluate at QT=T-50. Everything is ≥50s in the
# past so VM's default 30s -search.latencyOffset never hides it; the newest 3
# points sit inside the (QT-60, QT] window so rate()/increase() over [1m] compute.
T = int(time.time())
QT = T - 50                                  # instant-query evaluation time
OFFSETS = [150, 130, 110, 90, 70, 50]        # seconds before T → 6 points, newest at QT
STEPS = list(range(len(OFFSETS)))            # 0..5, monotonically increasing
HIST_BUCKETS = ["0.005", "0.05", "0.5", "1", "5", "+Inf"]

def labelset(base):
    # one representative value per label the panels filter on; always app=APP.
    ls = {"app": APP}
    for k, vs in metrics[base]["labels"].items():
        ls[k] = sorted(vs)[0] if vs else "v"
    return ls

def fmt(name, ls, val, off):
    lbl = ",".join(f'{k}="{v}"' for k, v in ls.items())
    return f'{name}{{{lbl}}} {val} {(T - off) * 1000}'

lines = []
for base, meta in metrics.items():
    ls = labelset(base)
    if meta["hist"]:
        for bi, le in enumerate(HIST_BUCKETS):         # cumulative over le, rising over time
            for off, step in zip(OFFSETS, STEPS):
                lines.append(fmt(f"{base}_bucket", {**ls, "le": le}, (bi + 1) * (5 + step * 4), off))
        for off, step in zip(OFFSETS, STEPS):
            lines.append(fmt(f"{base}_sum", ls, 2.0 + step * 1.5, off))
            lines.append(fmt(f"{base}_count", ls, 20 + step * 12, off))
    else:                                              # counter/gauge — monotonically rising
        for off, step in zip(OFFSETS, STEPS):
            lines.append(fmt(base, ls, 10 + step * 13, off))

body = ("\n".join(lines) + "\n").encode()
req = urllib.request.Request(f"{VM}/api/v1/import/prometheus", data=body, method="POST")
with urllib.request.urlopen(req, timeout=15) as r:
    if r.status not in (200, 204):
        print("FATAL: VM import failed:", r.status); sys.exit(2)
print(f"seeded {len(metrics)} metric families ({len(lines)} samples) into VM")
time.sleep(11)  # VM buffers imports in memory and flushes on a ~5–10s interval

# ── evaluate every panel query, assert non-empty ──────────────────────────────
def query(expr):
    url = f"{VM}/api/v1/query?" + urllib.parse.urlencode({"query": expr, "time": QT})
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read()[:160]!r}"
    if d.get("status") != "success":
        return None, f"{d.get('status')}: {d.get('error','')[:160]}"
    return (d.get("data") or {}).get("result") or [], None

failures = []
cur = None
for p in panels:
    if p["dash"] != cur:
        cur = p["dash"]; print(f"\n{cur}")
    res, err = query(p["expr"])
    if err is not None:
        print(f"  [ERROR] {p['panel']} ({p['refId']}) — {err}"); failures.append((p, err))
    elif not res:
        print(f"  [BLANK] {p['panel']} ({p['refId']})"); failures.append((p, "empty result"))
    else:
        print(f"  [ OK  ] {p['panel']} ({p['refId']})")

print(f"\nSUMMARY: {len(panels)-len(failures)}/{len(panels)} panels render non-empty.")
if failures:
    print("\nFAILED panels (malformed PromQL or blank given well-formed data):")
    for p, why in failures:
        print(f"  • [{p['dash']}] {p['panel']} ({p['refId']}): {why}")
        print(f"      {p['expr']}")
    sys.exit(1)
print("RENDER GATE: PASS")
PYGATE
