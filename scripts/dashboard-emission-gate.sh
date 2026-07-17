#!/usr/bin/env bash
# Dashboard EMISSION / liveness gate (ADR-021 / Epic #249 — dashboards-render-as-expected).
#
# Complements two things that already exist:
#   • dashboard-render-gate.sh — proves each panel's PromQL is VALID against
#     SYNTHETIC data (correctness of the query, not of emission).
#   • DashboardCompletenessTest / *_drift_test — STATICALLY prove displayed ⊆ measured
#     (no panel references an unregistered/removed family → no dead panels) and
#     measured ⊆ displayed (every public metric has a panel). Offline, exhaustive.
#
# What NEITHER proves: that the running app actually PUSHES real samples that reach
# the store, per dashboard. That's this gate — run against a LIVE VictoriaMetrics a
# real app has pushed to (a preview/prod stack driven by the E2E suite). It answers
# "after a real drive, does each dashboard receive live data through the push
# pipeline?" — the end-to-end liveness the static tests can't see.
#
# It is a LIVENESS gate, not a per-panel-non-empty gate. Rare/negative/worker/
# excluded-spec families (refresh-reuse alerts, MFA, image-retention sweeps,
# rate-limit rejections, uploads) legitimately have no samples after a happy-path
# drive — the static tests already prove those families are registered and
# panel-backed, so their absence at runtime is not a dashboard bug. Hard failures
# are reserved for signals that mean the PIPELINE is broken:
#   1. No stacks_* families present at all              → push pipeline dead.
#   2. Any dashboard with ZERO referenced families live → that dashboard is dataless
#      (a family-group routing/label break).
#   3. Any curated ALWAYS-DRIVEN family missing          → a happy-path emission or
#      pipeline regression (these fire on every standard E2E run).
# Everything else is reported as informational (driven vs undriven), never failing.
#
# Only stacks_* families are checked. fly_* come from Fly's scrape, not our push.
#
# Usage (against a 6PN-only preview VM, reached via fly proxy to its FLYCAST addr —
# the .internal proxy resets; .flycast tunnels cleanly):
#   fly proxy 18428:8428 <vm-app>.flycast --app <vm-app>   # in another shell
#   EMISSION_GATE_VM=http://localhost:18428 \
#   EMISSION_GATE_APP=stacks-core-pr-<component> \
#   scripts/dashboard-emission-gate.sh
#
# Env:
#   EMISSION_GATE_VM    VictoriaMetrics base URL. Default http://localhost:8428.
#   EMISSION_GATE_APP   The {app="…"} label the push tags samples with
#                       (FLY_APP_NAME of the core app). Required.
#   DASHBOARD_DIR       Dashboard JSON dir. Default apps/core/priv/grafana.
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

# Families the happy-path E2E suite drives on EVERY run — a broken push or a
# regressed emitter shows up here. Kept small and conservative (only families that
# fire without upload/Modal/rate-limit specs, without background workers, and
# without negative/alert events). Spread across all six dashboards so a per-group
# pipeline break can't hide.
ALWAYS_DRIVEN = {
    # auth_security (#237)
    "stacks_auth_jwt_issued_count", "stacks_auth_registration_count",
    "stacks_auth_login_failure_count",
    # gdpr_data_rights (#238)
    "stacks_gdpr_export_count", "stacks_gdpr_deletion_count", "stacks_gdpr_consent_grant_count",
    # visibility_social (#236)
    "stacks_visibility_recap_count", "stacks_social_block_count", "stacks_view_as_usage_count",
    # discovery (#239)
    "stacks_profile_view_count", "stacks_search_people_count", "stacks_handle_claimed_count",
    # platform_ops (#240)
    "stacks_rate_limit_client_ip_count", "stacks_events_emitted_count",
    # moderation_agegate
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

# ── which stacks_* families does the live VM hold for this app? ───────────────
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

# ── per-dashboard liveness report ─────────────────────────────────────────────
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

# ── hard-gate conditions ──────────────────────────────────────────────────────
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
