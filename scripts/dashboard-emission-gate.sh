#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
export EMISSION_GATE_VM="${EMISSION_GATE_VM:-http://localhost:8428}"
export EMISSION_GATE_APP="${EMISSION_GATE_APP:-}"
export DASHBOARD_DIR="${DASHBOARD_DIR:-${REPO_ROOT}/apps/core/priv/grafana}"

if [[ -z "${EMISSION_GATE_APP}" ]]; then
  echo "FATAL: EMISSION_GATE_APP is required (the {app=…} label = core app name)." >&2
  exit 2
fi

if ! curl -sf -o /dev/null "${EMISSION_GATE_VM}/health" 2>/dev/null; then
  echo "FATAL: VictoriaMetrics not reachable at ${EMISSION_GATE_VM}." >&2
  echo "       For a 6PN-only preview VM: fly proxy 18428:8428 <vm-app>.flycast --app <vm-app>" >&2
  exit 2
fi

python3 <<'PYGATE'
import glob, json, os, re, sys, urllib.request, urllib.parse

VM = os.environ["EMISSION_GATE_VM"].rstrip("/")
APP = os.environ["EMISSION_GATE_APP"]
DASH_DIR = os.environ["DASHBOARD_DIR"]

ALWAYS_DRIVEN = {
    "stacks_auth_jwt_issued_count", "stacks_auth_registration_count",
    "stacks_auth_login_failure_count",
    "stacks_gdpr_export_count", "stacks_gdpr_deletion_count", "stacks_gdpr_consent_grant_count",
    "stacks_visibility_recap_count", "stacks_social_block_count", "stacks_view_as_usage_count",
    "stacks_profile_view_count", "stacks_search_people_count", "stacks_handle_claimed_count",
    "stacks_rate_limit_client_ip_count", "stacks_events_emitted_count",
    "stacks_age_gate_enforce_count", "stacks_age_verification_count",
}

SEL = re.compile(r'\b(stacks_[a-zA-Z0-9_]+)\b')
_SUFFIX = re.compile(r'_(bucket|sum|count|total)$')

def base_family(name):
    return _SUFFIX.sub("", name)

def walk(node, out):
    if isinstance(node, dict):
        if node.get("type") not in (None, "row", "text"):
            for t in node.get("targets", []) or []:
                if t.get("expr"):
                    out.append(t["expr"])
        for v in node.values():
            walk(v, out)
    elif isinstance(node, list):
        for x in node:
            walk(x, out)

dashboards = {}
for path in sorted(glob.glob(os.path.join(DASH_DIR, "*.json"))):
    exprs = []
    walk(json.load(open(path)).get("panels", []), exprs)
    fams = set()
    for e in exprs:
        for name in SEL.findall(e):
            fams.add(base_family(name))
    dashboards[os.path.basename(path)] = fams

if not dashboards:
    print("FATAL: no dashboards found under", DASH_DIR); sys.exit(2)

sel = '{app="%s"}' % APP
url = f"{VM}/api/v1/label/__name__/values?" + urllib.parse.urlencode({"match[]": sel})
try:
    with urllib.request.urlopen(url, timeout=20) as r:
        payload = json.loads(r.read())
except Exception as e:  # noqa: BLE001 — any transport/HTTP error is fatal infra
    print(f"FATAL: VM __name__ query failed: {e}"); sys.exit(2)

if payload.get("status") != "success":
    print(f"FATAL: VM query status {payload.get('status')}: {payload.get('error','')}")
    sys.exit(2)

present = {base_family(n) for n in (payload.get("data") or []) if n.startswith("stacks_")}
print(f'VM holds {len(present)} stacks_* families for app="{APP}"\n')

hard_fail = []
dataless_dashboards = []
for dash in sorted(dashboards):
    refs = dashboards[dash]
    live = sorted(f for f in refs if f in present)
    undriven = sorted(f for f in refs if f not in present)
    print(f"{dash}: {len(live)}/{len(refs)} referenced families live")
    if undriven:
        print(f"    undriven (rare/worker/excluded — registered & panel-backed, just not fired): "
              f"{', '.join(f.replace('stacks_','') for f in undriven)}")
    if not live:
        dataless_dashboards.append(dash)

print()
if not present:
    print("EMISSION GATE: FAIL — no stacks_* families present; the push pipeline delivered nothing.")
    sys.exit(1)

if dataless_dashboards:
    print("EMISSION GATE: FAIL — these dashboards received ZERO live families (dataless):")
    for d in dataless_dashboards:
        print(f"  • {d}")
    sys.exit(1)

missing_core = sorted(f for f in ALWAYS_DRIVEN if f not in present)
if missing_core:
    print("EMISSION GATE: FAIL — curated always-driven families missing (emission/pipeline regression):")
    for f in missing_core:
        print(f"  • {f}")
    print("These fire on every standard E2E run; absence means a broken emitter or push, not a rare event.")
    sys.exit(1)

print(f"EMISSION GATE: PASS — every dashboard receives live data and all "
      f"{len(ALWAYS_DRIVEN)} always-driven families landed via the push pipeline.")
PYGATE
