#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
export RENDER_GATE_VM="${RENDER_GATE_VM:-http://localhost:8428}"
export DASHBOARD_DIR="${DASHBOARD_DIR:-${REPO_ROOT}/apps/core/priv/grafana}"

vm_ready=""
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "${RENDER_GATE_VM}/health" 2>/dev/null; then
    vm_ready=1
    break
  fi
  sleep 1
done
if [ -z "$vm_ready" ]; then
  echo "FATAL: VictoriaMetrics not reachable at ${RENDER_GATE_VM} after 30s." >&2
  echo "       Start the local stack first:  just observe" >&2
  exit 2
fi

python3 <<'PYGATE'
import glob, json, os, re, sys, time, urllib.request, urllib.parse, urllib.error

VM = os.environ["RENDER_GATE_VM"].rstrip("/")
DASH_DIR = os.environ["DASHBOARD_DIR"]
APP = "rendergate"
RATE_INTERVAL = "1m"

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

SEL = re.compile(r'\b((?:stacks|fly)_[a-zA-Z0-9_]+)\b(?:\s*\{([^}]*)\})?')
MATCH = re.compile(r'(\w+)\s*(=~|!~|!=|=)\s*"([^"]*)"')

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
        note(name, labels)

T = int(time.time())
QT = T - 50                                  # instant-query evaluation time
OFFSETS = [150, 130, 110, 90, 70, 50]        # seconds before T → 6 points, newest at QT
STEPS = list(range(len(OFFSETS)))            # 0..5, monotonically increasing
HIST_BUCKETS = ["0.005", "0.05", "0.5", "1", "5", "+Inf"]

def labelset(base):
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
