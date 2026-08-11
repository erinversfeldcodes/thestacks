#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

deploy_with_retry() {
    local name="$1"; shift
    if "$@"; then return 0; fi
    echo "    retry: ${name} failed once; retrying in 5s..."
    sleep 5
    if "$@"; then return 0; fi
    echo "FAIL deploy: ${name} failed twice; aborting" >&2
    return 1
}

neon_branch_id_by_name() {
    local project_id="$1"
    local branch_name="$2"
    local max_attempts=3
    local attempt=0
    local response curl_rc http_code body
    while (( attempt < max_attempts )); do
        attempt=$(( attempt + 1 ))
        response="$(curl -sS -w '\n%{http_code}' \
            -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${project_id}/branches")"
        curl_rc=$?
        http_code="${response##*$'\n'}"
        body="${response%$'\n'*}"

        if (( curl_rc != 0 )) || [[ "$http_code" == 429 || "$http_code" == 5?? ]]; then
            if (( attempt < max_attempts )); then
                sleep "$attempt"
                continue
            fi
            echo "FAIL deploy: Neon API call failed (HTTP ${http_code:-none} / curl rc ${curl_rc}) after ${attempt} attempts querying branches for project ${project_id}" >&2
            return 1
        fi

        if [[ "$http_code" != 2?? ]]; then
            echo "FAIL deploy: Neon API call failed (HTTP ${http_code} / curl rc ${curl_rc}) querying branches for project ${project_id}" >&2
            return 1
        fi

        printf '%s' "$body" | python3 -c '
import json, sys
target = sys.argv[1]
branches = json.load(sys.stdin).get("branches", [])
match = [b["id"] for b in branches if b.get("name") == target]
print(match[0] if match else "")
' "$branch_name"
        return 0
    done
    echo "FAIL deploy: Neon API call exhausted retries querying branches for project ${project_id}" >&2
    return 1
}

ensure_fly_app() {
    fly apps create "$1" 2>&1 | grep -v "^Error" || true
}

fly_machine_ids() {
    fly machines list --app "$1" --json 2>/dev/null \
        | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    print(m['id'])
" 2>/dev/null || true
}

fly_machine_started_id() {
    fly machines list --app "$1" --json 2>/dev/null \
        | python3 -c "
import json,sys
machines = json.load(sys.stdin)
started = [m for m in machines if m.get('state') == 'started']
print(started[0]['id'] if started else '')
" 2>/dev/null || true
}

wait_for_fly_checks() {
    local app="$1"
    local timeout="${2:-90}"
    local deadline=$(( $(date +%s) + timeout ))
    while [[ $(date +%s) -lt $deadline ]]; do
        if fly status --app "$app" --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
machines = data.get("Machines") or data.get("machines") or []
healthy = False
for m in machines:
    state = m.get("state", "")
    checks = m.get("checks") or []
    if state == "started" and checks and all(
        (c.get("status") or "").lower() == "passing" for c in checks
    ):
        healthy = True
        break
sys.exit(0 if healthy else 1)
' 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

if [[ -z "${FLY_API_TOKEN:-}" ]]; then
    echo "SKIP: FLY_API_TOKEN not set — skipping deploy."
    exit 0
fi

if ! command -v fly &>/dev/null; then
    echo "SKIP: flyctl not installed (brew install flyctl)"
    exit 0
fi

BRANCH=""
PROD_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2 ;;
        --production) PROD_MODE=1; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$BRANCH" ]]; then
    BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
fi

# Shared derivation (Issue #170 C): honours the optional PREVIEW_SUFFIX env
# var so CI runs get run-unique names that can't collide with local `just ci`
# previews of the same branch. Behaviour is byte-identical to the old inline
# derivation when PREVIEW_SUFFIX is unset.
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"
derive_preview_names "$BRANCH"
SANITISED="${PREVIEW_COMPONENT}"

if [[ "$PROD_MODE" -eq 1 ]]; then
    CORE_APP="${CORE_APP:-thestacks-core}"
    MODAL_APP="${MODAL_APP:-thestacks-vision}"
    PHX_HOST_VALUE="${PROD_PHX_HOST:-readinginthestacks.com}"
    NEON_STAGING_API_KEY=""
    STACKS_E2E_TEST_HELPERS=""
    # Age-gating ships DARK in production (ADR-020): the enforcement + verification
    # machinery is built and tested but inert until a real age-verification provider
    # (Smile ID / Yoti / Sumsub) is integrated. Force the flag empty here so no stale
    # shell/.env export can promote it onto the prod app — production must launch with
    # age-gating invisible and inert.
    AGE_GATING_ENABLED=""
    RATE_LIMIT_PUBLIC=""
    RATE_LIMIT_E2E_HELPER=""
    SMOKE_TESTS_ENABLED=""
    echo "==> Deploy stack in PRODUCTION mode"
else
    if [[ -z "${NEON_STAGING_PROJECT_ID:-}" ]]; then
        echo "SKIP: NEON_STAGING_PROJECT_ID not set — skipping preview deploy."
        exit 0
    fi
    CORE_APP="${PREVIEW_CORE_APP}"
    MODAL_APP="${PREVIEW_MODAL_APP}"
    STACKS_E2E_TEST_HELPERS="1"
    AGE_GATING_ENABLED="true"
    INVITE_ONLY_REGISTRATION="true"
    RATE_LIMIT_PUBLIC="5000"
    RATE_LIMIT_E2E_HELPER="5000"
    SMOKE_TESTS_ENABLED="true"
    echo "==> Deploy stack for branch: ${BRANCH}"

    if [[ "${STACKS_SKIP_RESOLVER_PREFLIGHT:-0}" != "1" ]]; then
        echo ""
        echo "==> Preflight: external resolver health (OL required, GB advisory)..."
        if ! bash "${REPO_ROOT}/scripts/preflight-resolver-health.sh"; then
            echo "FAIL deploy: Open Library is unreachable — the E2E vision suite cannot pass; aborting before burning a deploy cycle." >&2
            echo "    Override for manual inspection deploys: STACKS_SKIP_RESOLVER_PREFLIGHT=1" >&2
            exit 1
        fi
    fi
fi
VISION_SERVICE_URL=""
NEON_BRANCH_NAME=""

echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"

if [[ -n "${NEON_STAGING_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."

    NEON_PARENT_BRANCH="${NEON_PARENT_BRANCH:-staging}"
    echo "    Parent branch: ${NEON_PARENT_BRANCH}"
    NEON_PARENT_BRANCH_ID="$(neon_branch_id_by_name "${NEON_STAGING_PROJECT_ID}" "${NEON_PARENT_BRANCH}")" || exit 1

    if [[ -z "$NEON_PARENT_BRANCH_ID" ]]; then
        echo "FAIL deploy: Neon parent branch '${NEON_PARENT_BRANCH}' not found in project ${NEON_STAGING_PROJECT_ID}" >&2
        exit 1
    fi
    echo "    Parent branch ID: ${NEON_PARENT_BRANCH_ID}"

    if ! stale_id="$(neon_branch_id_by_name "${NEON_STAGING_PROJECT_ID}" "${PREVIEW_NEON_BRANCH}")"; then
        echo "    WARNING: stale-branch lookup for ${PREVIEW_NEON_BRANCH} failed (see Neon API error above); skipping stale cleanup and continuing." >&2
        stale_id=""
    fi
    if [[ -n "$stale_id" ]]; then
        echo "    Deleting stale branch ${PREVIEW_NEON_BRANCH}..."
        curl -sL -X DELETE \
            -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches/${stale_id}" > /dev/null
    fi

    neon_response="$(curl -sL -X POST \
        -H "Authorization: Bearer ${NEON_STAGING_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"branch\": {\"name\": \"${PREVIEW_NEON_BRANCH}\", \"parent_id\": \"${NEON_PARENT_BRANCH_ID}\"}, \"endpoints\": [{\"type\": \"read_write\"}]}" \
        "https://console.neon.tech/api/v2/projects/${NEON_STAGING_PROJECT_ID}/branches?include_passwords=true")"

    NEON_CONNECTION_URI="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['connection_uris'][0]['connection_uri'])" 2>/dev/null || true)"
    neon_branch_name="$(echo "$neon_response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['branch']['name'])" 2>/dev/null || true)"

    if [[ "$neon_branch_name" != "${PREVIEW_NEON_BRANCH}" ]]; then
        echo "FAIL deploy: Neon branch creation failed" >&2
        echo "$neon_response" | head -5 >&2
        exit 1
    fi
    NEON_BRANCH_NAME="${PREVIEW_NEON_BRANCH}"
    echo "    Neon branch created: ${NEON_BRANCH_NAME}"

    if [[ -n "$NEON_CONNECTION_URI" ]]; then
        if command -v psql > /dev/null 2>&1; then
            echo "    Waking the branch compute before migrations run..."
            neon_awake=0
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                if psql "$NEON_CONNECTION_URI" -tAc 'select 1' > /dev/null 2>&1; then
                    echo "    Branch is awake (attempt ${attempt})."
                    neon_awake=1
                    break
                fi
                sleep 3
            done
            if [[ "$neon_awake" -eq 0 ]]; then
                echo "    WARNING: branch did not answer in ~30s; migrations may race its cold start."
            fi
        else
            echo "    WARNING: psql not found, skipping branch warm-up (Issue #305)."
        fi
    fi
    if [[ -n "$NEON_CONNECTION_URI" ]]; then
        echo "    Connection URI obtained."
    else
        echo "    WARNING: no connection URI returned."
    fi
else
    if [[ "$PROD_MODE" -eq 1 ]]; then
        echo "    No Neon branch creation in production mode (DATABASE_URL is composed upstream)."
    else
        echo "SKIP: NEON_STAGING_API_KEY not set — skipping Neon branch creation."
    fi
    NEON_CONNECTION_URI=""
fi

if [[ -z "${SKIP_VISION:-}" ]] && [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]]; then
    MODAL_PYTHON=""
    if [[ -x "${REPO_ROOT}/apps/vision/.venv/bin/python3" ]] \
        && "${REPO_ROOT}/apps/vision/.venv/bin/python3" -c "import modal" 2>/dev/null; then
        MODAL_PYTHON="${REPO_ROOT}/apps/vision/.venv/bin/python3"
    elif command -v python3 &>/dev/null && python3 -c "import modal" 2>/dev/null; then
        MODAL_PYTHON="$(command -v python3)"
    fi

    if [[ -z "$MODAL_PYTHON" ]]; then
        echo "FAIL deploy: no python with the 'modal' SDK importable" >&2
        echo "    Local dev: run ./setup.sh to populate apps/vision/.venv" >&2
        echo "    CI: the workflow should \`pip install modal\` before invoking this script" >&2
        exit 1
    fi

    echo ""
    echo "==> Syncing Modal secret 'thestacks-vision'..."
    MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        "$MODAL_PYTHON" -m modal secret create thestacks-vision \
            "VISION_HMAC_SECRET=${VISION_HMAC_SECRET:-}" \
            "MODAL_TOKEN_ID=${MODAL_TOKEN_ID}" \
            "MODAL_TOKEN_SECRET=${MODAL_TOKEN_SECRET}" \
            --force 2>&1 || { echo "FAIL deploy: Modal secret sync failed"; exit 1; }

    echo ""
    echo "==> Deploying vision service to Modal (app: ${MODAL_APP})..."
    _modal_deploy_once() {
        MODAL_APP_NAME="${MODAL_APP}" \
        MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
            "$MODAL_PYTHON" -m modal deploy "${REPO_ROOT}/apps/vision/modal_app.py" 2>&1
    }
    if ! modal_deploy_output="$(_modal_deploy_once)"; then
        echo "    retry: Modal vision deploy failed once; retrying in 5s..."
        sleep 5
        if ! modal_deploy_output="$(_modal_deploy_once)"; then
            echo "$modal_deploy_output"
            echo "FAIL deploy: Modal vision deploy failed twice; aborting before core" >&2
            exit 1
        fi
    fi
    echo "$modal_deploy_output"

    VISION_SERVICE_URL="$(MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        "$MODAL_PYTHON" -c "
import modal
f = modal.Function.from_name('${MODAL_APP}', 'vision_api')
print(f.web_url)
" 2>/dev/null || true)"

    if [[ -z "$VISION_SERVICE_URL" || "$VISION_SERVICE_URL" != http* ]]; then
        VISION_SERVICE_URL="$(python3 -c "
import re, sys
text = sys.stdin.read().replace('\n', '')
cleaned = re.sub(r'[│├└─🔨\s]+', '', text)
urls = re.findall(r'https://[^\s(]+\.modal\.run', cleaned)
print(urls[0] if urls else '')
" <<< "$modal_deploy_output" || true)"
        if [[ -n "$VISION_SERVICE_URL" ]]; then
            echo "    (URL from deploy output — SDK lookup was unavailable)"
        fi
    fi
    if [[ -z "$VISION_SERVICE_URL" ]]; then
        echo "FAIL deploy: could not retrieve Modal vision service URL via SDK" >&2
        exit 1
    fi
    echo "    Vision URL: ${VISION_SERVICE_URL}"
    echo "PASS deploy: vision service deployed to Modal"
elif [[ -n "${SKIP_VISION:-}" ]]; then
    echo "SKIP: SKIP_VISION set — skipping Modal vision deploy (no Modal spend). VISION_SERVICE_URL left empty."
else
    echo "WARN: MODAL_TOKEN_ID/MODAL_TOKEN_SECRET not set — skipping Modal vision deploy."
fi

if [[ "$PROD_MODE" -eq 1 ]]; then
    SCRAPER_APP="${SCRAPER_APP:-thestacks-scraper}"
else
    SCRAPER_APP="${PREVIEW_SCRAPER_APP}"
fi
SCRAPER_INTERNAL_URL="http://${SCRAPER_APP}.internal:8080"

if [[ -n "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo ""
    echo "==> Deploying scraper (app: ${SCRAPER_APP})..."
    if [[ "$PROD_MODE" -eq 0 ]]; then
        fly apps destroy "${SCRAPER_APP}" --yes 2>&1 | grep -v "^Error" || true
    fi
    ensure_fly_app "${SCRAPER_APP}"

    fly secrets set \
        SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}" \
        RUST_LOG="info" \
        --app "${SCRAPER_APP}" --stage

    _scraper_deploy_once() {
        (cd "$REPO_ROOT" && fly deploy \
            --app "${SCRAPER_APP}" \
            --config "${REPO_ROOT}/deploy/fly.scraper.toml" \
            --image-label "pr-${SANITISED}" \
            --depot=false)
    }
    if deploy_with_retry "scraper" _scraper_deploy_once; then
        echo "PASS deploy: scraper deployed at ${SCRAPER_INTERNAL_URL}"
    else
        exit 1
    fi
elif [[ -z "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo "WARN: SCRAPER_HMAC_SECRET not set — skipping scraper deploy."
    SCRAPER_INTERNAL_URL=""
fi

if [[ "$PROD_MODE" -eq 1 ]]; then
    SEARXNG_APP="${SEARXNG_APP:-thestacks-searxng}"
else
    SEARXNG_APP="${PREVIEW_SEARXNG_APP}"
fi
SEARXNG_INTERNAL_URL="http://${SEARXNG_APP}.internal:8080"

if [[ -n "${SEARXNG_SECRET_KEY:-}" ]]; then
    echo ""
    echo "==> Deploying SearXNG (app: ${SEARXNG_APP})..."
    if [[ "$PROD_MODE" -eq 0 ]]; then
        fly apps destroy "${SEARXNG_APP}" --yes 2>&1 | grep -v "^Error" || true
    fi
    ensure_fly_app "${SEARXNG_APP}"

    if [[ "$PROD_MODE" -eq 1 ]]; then
        fly apps resume "${SEARXNG_APP}" 2>&1 | grep -v "^Error" || true
    fi

    fly secrets set \
        SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY}" \
        --app "${SEARXNG_APP}" --stage

    SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml"
    SETTINGS_RENDERED="${REPO_ROOT}/deploy/searxng/settings.rendered.yml"
    sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|g" \
        "${SETTINGS_TEMPLATE}" > "${SETTINGS_RENDERED}"
    trap '[[ -f "${SETTINGS_RENDERED:-/dev/null}" ]] && rm -f "${SETTINGS_RENDERED}"' EXIT

    _searxng_deploy_once() {
        (cd "$REPO_ROOT/deploy/searxng" && fly deploy \
            --app "${SEARXNG_APP}" \
            --config "${REPO_ROOT}/deploy/fly.searxng.toml" \
            --yes)
    }

    if ! deploy_with_retry "searxng" _searxng_deploy_once; then
        rm -f "${SETTINGS_RENDERED}"
        echo "FAIL deploy: SearXNG deployment failed after retry — aborting so the gate doesn't run on a polluted SearXNG signal" >&2
        exit 1
    fi

    echo "==> Verifying SearXNG health via fly status (up to 300s)..."
    if ! wait_for_fly_checks "${SEARXNG_APP}" 300; then
        rm -f "${SETTINGS_RENDERED}"
        echo "FAIL deploy: SearXNG deploy returned 0 but fly status never reported started+passing within 300s — aborting" >&2
        exit 1
    fi
    echo "PASS deploy: SearXNG healthy at ${SEARXNG_INTERNAL_URL}"

    rm -f "${SETTINGS_RENDERED}"
else
    echo "WARN: SEARXNG_SECRET_KEY not set — skipping SearXNG deploy."
    SEARXNG_INTERNAL_URL=""
fi

if [[ "$PROD_MODE" -eq 1 ]]; then
    VM_APP="${VM_APP:-thestacks-victoriametrics}"
else
    VM_APP="${PREVIEW_VM_APP}"
fi
# The VM is a 6PN-only `[[services]]` app in BOTH environments. Direct-instance
# `<app>.internal:8428` is connection-refused — the port is only exposed via
# fly-proxy, not on the instance's 6PN address — but the Flycast address routes
# through fly-proxy and works, for the core push (Finch, inet6 pool) and for
# Grafana's datasource alike. A private Flycast IP is allocated below.
#
# ⚠️ This applied to preview only until 2026-07-28, and prod used `.internal`.
# The failure was silent and actively misleading: Mint tries IPv6 first, gets
# `:econnrefused`, then falls back to IPv4 (`inet4: true` is its default), where
# the AAAA-only 6PN name yields `:nxdomain` — so the logged error named DNS while
# the real fault was connectivity. Prod had logged
# `MetricsPusher: push failed: nxdomain` every 15s since the ADR-021 cutover,
# with no metrics ingested at all. Verified on the live node before the fix:
# `getent hosts` resolved, `:inet.getaddr(h, :inet6)` returned the VM's 6PN
# address, `:inet.getaddr(h, :inet)` returned nxdomain, and
# `:gen_tcp.connect(h, 8428, [:inet6])` returned `{:error, :econnrefused}`.
VM_HOST="${VM_APP}.flycast"
VM_INTERNAL_URL="http://${VM_HOST}:8428"
METRICS_PUSH_URL=""

echo ""
echo "==> Deploying metrics store (app: ${VM_APP})..."
if [[ "$PROD_MODE" -eq 0 ]]; then
    fly apps destroy "${VM_APP}" --yes 2>&1 | grep -v "^Error" || true
fi
ensure_fly_app "${VM_APP}"

# Allocate a private Flycast IPv6 so `<app>.flycast` resolves and the
# fly-proxy-routed :8428 service is reachable (VM_HOST above). Idempotent — a
# repeat allocation is a no-op.
#
# ⚠️ This was guarded to preview until 2026-07-28, on the belief that prod
# reached the VM via `.internal`. It did not: prod's VM app had NO IPs allocated
# at all, so neither address worked and the metrics push failed continuously.
# Both environments need this.
fly ips allocate-v6 --private --app "${VM_APP}" 2>&1 | grep -v "^Error" || true

if ! fly volumes list --app "${VM_APP}" --json 2>/dev/null | grep -q '"name"[: ]*"vm_data"'; then
    fly volumes create vm_data --app "${VM_APP}" --region iad --size 1 --yes 2>&1 \
        | grep -v "^Error" || true
fi

_vm_deploy_once() {
    (cd "$REPO_ROOT" && fly deploy \
        --app "${VM_APP}" \
        --config "${REPO_ROOT}/deploy/fly.victoriametrics.toml" \
        --ha=false --depot=false)
}
if deploy_with_retry "victoriametrics" _vm_deploy_once; then
    fly machines list --app "${VM_APP}" --json 2>/dev/null \
        | python3 -c "import json,sys; [print(m['id']) for m in json.load(sys.stdin)]" 2>/dev/null \
        | while read -r mid; do
            [[ -z "$mid" ]] && continue
            fly machine start "$mid" --app "${VM_APP}" 2>/dev/null || true
        done
    METRICS_PUSH_URL="${VM_INTERNAL_URL}"
    echo "PASS deploy: metrics store at ${VM_INTERNAL_URL}"
else
    echo "WARN: VictoriaMetrics deploy failed — core runs without metrics push (non-fatal)."
fi

# ── Deploy Grafana (PROD public + PREVIEW render-check) ──────────────────────
# Human-facing dashboards (ADR-021 / Epic #249 #254). Anonymous, read-only;
# dashboards + datasource are file-provisioned (baked into deploy/grafana/Dockerfile
# from the app's dashboard JSON). The datasource URL is env-driven (STACKS_VM_URL):
#   • PROD    — always-on public dashboards at thestacks-grafana, → the prod VM.
#   • PREVIEW — ephemeral per-PR Grafana → the preview VM, so the browser
#     dashboard-render E2E (e2e/tests/dashboards.spec.ts) can load each dashboard
#     and prove it renders live data. Torn down by cleanup-preview.sh.
# Grafana reaches the 6PN VM via the same Flycast host the core push uses. The
# earlier claim that `.internal` worked here "because Grafana is Go" was wrong:
# the obstacle is that :8428 is not exposed on the instance's 6PN address at all,
# which no resolver can work around. Both clients need fly-proxy.
# Non-fatal: a Grafana hiccup must not break the core deploy. Preview only deploys
# Grafana when the VM came up (nothing to point at otherwise). The preview Grafana
# URL is deterministic (https://${PREVIEW_GRAFANA_APP}.fly.dev) — the CI browser
# render step re-derives it from the shared preview-names, so it is not exported here.
_deploy_grafana=0
if [[ "$PROD_MODE" -eq 1 ]]; then
    GRAFANA_APP="${GRAFANA_APP:-thestacks-grafana}"
    # ⚠️ Was hardcoded to `thestacks-victoriametrics.internal:8428` until
    # 2026-07-28. That address is connection-refused on the instance's 6PN
    # (see VM_HOST above), so prod dashboards had no reachable datasource —
    # the same root cause as the metrics push, and the prior comment here
    # ("Grafana is Go — its resolver handles the IPv6-only name") misread a
    # connectivity failure as a resolver one. Use the same Flycast host.
    GRAFANA_VM_URL="${VM_INTERNAL_URL}"
    _deploy_grafana=1
elif [[ -n "$METRICS_PUSH_URL" ]]; then
    GRAFANA_APP="${PREVIEW_GRAFANA_APP}"
    GRAFANA_VM_URL="${VM_INTERNAL_URL}"
    _deploy_grafana=1
fi

if [[ "$_deploy_grafana" -eq 1 ]]; then
    echo ""
    echo "==> Deploying Grafana (app: ${GRAFANA_APP})..."
    if [[ "$PROD_MODE" -eq 0 ]]; then
        fly apps destroy "${GRAFANA_APP}" --yes 2>&1 | grep -v "^Error" || true
    fi
    ensure_fly_app "${GRAFANA_APP}"
    fly ips allocate-v4 --shared --app "${GRAFANA_APP}" 2>&1 || true

    _grafana_deploy_once() {
        (cd "$REPO_ROOT" && fly deploy "$REPO_ROOT" \
            --app "${GRAFANA_APP}" \
            --config "${REPO_ROOT}/deploy/fly.grafana.toml" \
            --env "STACKS_VM_URL=${GRAFANA_VM_URL}" \
            --env "GF_SERVER_ROOT_URL=https://${GRAFANA_APP}.fly.dev" \
            --ha=false --depot=false)
    }
    if deploy_with_retry "grafana" _grafana_deploy_once; then
        echo "PASS deploy: Grafana at https://${GRAFANA_APP}.fly.dev"
    else
        echo "WARN: Grafana deploy failed — dashboards unavailable (non-fatal)."
    fi
fi

echo ""
echo "==> Creating ephemeral Fly app (if not already exists)..."
ensure_fly_app "${CORE_APP}"

fly ips allocate-v4 --shared --app "${CORE_APP}" 2>&1 || true

# ── Stage core secrets ────────────────────────────────────────────────────────
# DATABASE_URL sourcing:
#   preview: NEON_CONNECTION_URI was populated by the Neon-branch creation block above.
#   prod:    NEON_STAGING_API_KEY is cleared → no branch → caller must provide
#            DATABASE_URL directly in the environment (from a GitHub secret in CI,
#            or an operator export for local prod-mode use).
#
# EMAIL_FROM (REQUIRED for working prod email, Issue #323): the transactional
# sender address. The in-code default is Resend's `onboarding@resend.dev`
# stopgap, which CANNOT deliver to real users (apps/core/config/config.exs) —
# setting EMAIL_FROM to a verified-domain address (e.g. noreply@thestacks.app)
# is the only remaining step for working prod email. Supplied by the caller's
# environment (GitHub secret in CI / operator export), staged via the
# `${EMAIL_FROM:+...}` expansion below like the other prod secrets; the value
# is never committed here. Runbook: docs/runbooks/email-delivery-failure.md.
EFFECTIVE_DATABASE_URL="${NEON_CONNECTION_URI:-${DATABASE_URL:-}}"

if [[ "$PROD_MODE" -eq 1 && -z "${EMAIL_FROM:-}" ]]; then
    echo "WARN: EMAIL_FROM is not set — prod email keeps the onboarding@resend.dev"
    echo "      stopgap sender, which CANNOT deliver to real users. Set it via:"
    echo "      fly secrets set EMAIL_FROM=noreply@thestacks.app -a ${CORE_APP}"
    echo "      (see docs/runbooks/email-delivery-failure.md)"
fi

fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    GUARDIAN_SECRET_KEY="${GUARDIAN_SECRET_KEY:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    VISION_SERVICE_URL="${VISION_SERVICE_URL}" \
    PHX_HOST="${PHX_HOST_VALUE:-${CORE_APP}.fly.dev}" \
    RATE_LIMIT_AUTH="60" \
    ${EFFECTIVE_DATABASE_URL:+DATABASE_URL="${EFFECTIVE_DATABASE_URL}"} \
    ${R2_ACCOUNT_ID:+R2_ACCOUNT_ID="${R2_ACCOUNT_ID}"} \
    ${R2_ACCESS_KEY_ID:+R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"} \
    ${R2_SECRET_ACCESS_KEY:+R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"} \
    ${R2_BUCKET_NAME:+R2_BUCKET_NAME="${R2_BUCKET_NAME}"} \
    ${VISION_TOGETHER_API_KEY:+VISION_TOGETHER_API_KEY="${VISION_TOGETHER_API_KEY}"} \
    ${SCRAPER_HMAC_SECRET:+SCRAPER_HMAC_SECRET="${SCRAPER_HMAC_SECRET}"} \
    ${SCRAPER_INTERNAL_URL:+SCRAPER_SERVICE_URL="${SCRAPER_INTERNAL_URL}"} \
    ${SEARXNG_INTERNAL_URL:+SEARXNG_URL="${SEARXNG_INTERNAL_URL}"} \
    ${BRAVE_SEARCH_API_KEY:+BRAVE_SEARCH_API_KEY="${BRAVE_SEARCH_API_KEY}"} \
    ${GOOGLE_BOOKS_API_KEY:+GOOGLE_BOOKS_API_KEY="${GOOGLE_BOOKS_API_KEY}"} \
    ${RESEND_API_KEY:+RESEND_API_KEY="${RESEND_API_KEY}" EMAIL_PROVIDER="resend"} \
    ${STACKS_APP_DB_PASSWORD:+STACKS_APP_DB_PASSWORD="${STACKS_APP_DB_PASSWORD}"} \
    ${STACKS_DBT_DB_PASSWORD:+STACKS_DBT_DB_PASSWORD="${STACKS_DBT_DB_PASSWORD}"} \
    ${METRICS_SCRAPE_TOKEN:+METRICS_SCRAPE_TOKEN="${METRICS_SCRAPE_TOKEN}"} \
    ${METRICS_PUSH_URL:+STACKS_METRICS_PUSH_URL="${METRICS_PUSH_URL}"} \
    ${PROD_OWNER_EMAIL:+PROD_OWNER_EMAIL="${PROD_OWNER_EMAIL}"} \
    ${PROD_OWNER_PASSWORD:+PROD_OWNER_PASSWORD="${PROD_OWNER_PASSWORD}"} \
    ${STACKS_PROBER_EMAIL:+STACKS_PROBER_EMAIL="${STACKS_PROBER_EMAIL}"} \
    ${STACKS_PROBER_PASSWORD:+STACKS_PROBER_PASSWORD="${STACKS_PROBER_PASSWORD}"} \
    ${STACKS_E2E_TEST_HELPERS:+STACKS_E2E_TEST_HELPERS="${STACKS_E2E_TEST_HELPERS}"} \
    ${AGE_GATING_ENABLED:+AGE_GATING_ENABLED="${AGE_GATING_ENABLED}"} \
    ${INVITE_ONLY_REGISTRATION:+INVITE_ONLY_REGISTRATION="${INVITE_ONLY_REGISTRATION}"} \
    ${RATE_LIMIT_PUBLIC:+RATE_LIMIT_PUBLIC="${RATE_LIMIT_PUBLIC}"} \
    ${RATE_LIMIT_E2E_HELPER:+RATE_LIMIT_E2E_HELPER="${RATE_LIMIT_E2E_HELPER}"} \
    ${SMOKE_TESTS_ENABLED:+SMOKE_TESTS_ENABLED="${SMOKE_TESTS_ENABLED}"} \
    ${EMAIL_FROM:+EMAIL_FROM="${EMAIL_FROM}"} \
    --app "${CORE_APP}" --stage

if [[ "$PROD_MODE" -eq 1 ]]; then
    echo ""
    echo "==> Ensuring test-helper flag is unset on ${CORE_APP} (prod safety)..."
    fly secrets unset STACKS_E2E_TEST_HELPERS --app "${CORE_APP}" --stage 2>/dev/null \
        || echo "    (STACKS_E2E_TEST_HELPERS not present — nothing to unset)"
    echo "==> Ensuring smoke-test flag is unset on ${CORE_APP} (prod safety)..."
    fly secrets unset SMOKE_TESTS_ENABLED --app "${CORE_APP}" --stage 2>/dev/null \
        || echo "    (SMOKE_TESTS_ENABLED not present — nothing to unset)"
fi

if [[ "$PROD_MODE" -eq 0 && -z "${RESEND_API_KEY:-}" ]]; then
    echo ""
    echo "==> Ensuring Resend is unset on ${CORE_APP} (preview uses Swoosh Local mailbox for E2E)..."
    fly secrets unset RESEND_API_KEY EMAIL_PROVIDER --app "${CORE_APP}" --stage 2>/dev/null \
        || echo "    (RESEND_API_KEY/EMAIL_PROVIDER not present — nothing to unset)"
fi

if [[ "$PROD_MODE" -eq 1 ]]; then
    echo ""
    echo "==> Verifying DATABASE_URL was composed for ${CORE_APP}..."
    if [[ -z "${EFFECTIVE_DATABASE_URL:-}" ]]; then
        echo "FAIL deploy: DATABASE_URL is empty." >&2
        echo "  Prod mode requires DATABASE_URL from the calling environment." >&2
        echo "  In CI, verify the 'Compose DATABASE_URL' step in" >&2
        echo "  .github/workflows/deploy-production.yml ran and produced a" >&2
        echo "  non-empty value from the STACKS_PROD_DB_* component secrets." >&2
        exit 1
    fi
    echo "PASS deploy: DATABASE_URL composed (length: ${#EFFECTIVE_DATABASE_URL})"
fi

echo ""
echo "==> Generating Elm proto decoders..."
if [[ -f "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh" \
        || { echo "FAIL deploy: proto Elm generation failed"; exit 1; }
    if [[ ! -d "$REPO_ROOT/proto/gen/elm" ]] || [[ -z "$(ls -A "$REPO_ROOT/proto/gen/elm" 2>/dev/null)" ]]; then
        echo "FAIL deploy: proto/gen/elm/ is empty after generation"; exit 1
    fi
    echo "    proto/gen/elm/ generated"
else
    echo "FAIL deploy: scripts/gen-elm-proto.sh not found"
    exit 1
fi

echo ""
echo "==> Generating Ecto schemas from proto..."
bash "$REPO_ROOT/scripts/gen-ecto-proto.sh" \
    || { echo "FAIL deploy: gen-ecto-proto.sh failed"; exit 1; }
python3 "$REPO_ROOT/scripts/gen_python_proto.py" --language elixir \
    || { echo "FAIL deploy: gen_python_proto.py --language elixir failed"; exit 1; }
if [[ ! -d "$REPO_ROOT/apps/core/lib/stacks/gen" ]] || [[ -z "$(ls -A "$REPO_ROOT/apps/core/lib/stacks/gen" 2>/dev/null)" ]]; then
    echo "FAIL deploy: apps/core/lib/stacks/gen/ is empty after generation"; exit 1
fi
echo "    Ecto schemas generated to apps/core/lib/stacks/gen/"

if [[ "${PROD_MODE}" == 1 ]]; then
    echo ""
    echo "==> Running prod migrations (before image cutover)..."
    if [[ -z "${DATABASE_URL:-}" ]]; then
        echo "FAIL deploy: DATABASE_URL is required for prod migrate (compose it before invoking deploy-stack.sh --production)"
        exit 1
    fi

    # ── Warm up the Neon compute before migrating ──────────────────────────────
    # Prod runs on Neon with autosuspend. The Docker build + deps compile above
    # takes ~8 min, long enough for the compute (last woken by the capture-LSN
    # step) to scale to zero. `mix ecto.migrate`'s pool then can't establish a
    # connection before its ~5s checkout timeout and the migration aborts with
    # `DBConnection.ConnectionError: connection not available ... dropped from
    # queue` (run 29206609072). A cold Neon compute takes a few seconds to wake
    # on first connect, so poll `SELECT 1` with backoff until it answers — this
    # wakes the compute and confirms connectivity before the heavier migrate.
    if command -v psql &>/dev/null; then
        echo "==> Warming up Neon compute (poll SELECT 1, up to 60s)..."
        _warm_ok=0
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            if psql "$DATABASE_URL" -q -t -A -c "SELECT 1" >/dev/null 2>&1; then
                echo "    Neon compute responded on attempt ${attempt}"
                _warm_ok=1
                break
            fi
            echo "    attempt ${attempt}: compute not ready yet, retrying in 6s..."
            sleep 6
        done
        if [[ "${_warm_ok}" != 1 ]]; then
            echo "FAIL deploy: Neon compute did not accept a connection within ~60s — aborting before migrate (old image still serving traffic)"
            exit 1
        fi
    else
        echo "WARN: psql not found — skipping Neon warmup (migrate may hit a cold-start connection timeout)"
    fi

    if ! (cd "$REPO_ROOT/apps/core" && \
            MIX_ENV=prod mix deps.get --only prod && \
            MIX_ENV=prod mix compile && \
            MIX_ENV=prod mix stacks.data.correct --apply && \
            MIX_ENV=prod mix ecto.migrate); then
        echo "FAIL deploy: prod data correction or migration failed — old image still serving traffic"
        exit 1
    fi
    echo "PASS deploy: prod migrations applied"
fi

echo ""
echo "==> Rebuilding frontend assets via esbuild..."
if command -v node &>/dev/null && [[ -f "$REPO_ROOT/apps/core/assets/build.js" ]]; then
    echo "    Clearing Elm incremental build cache (elm-stuff/)..."
    rm -rf "$REPO_ROOT/apps/core/assets/elm/elm-stuff"
    (cd "$REPO_ROOT/apps/core/assets" && node build.js --production) \
        || { echo "FAIL deploy: frontend build failed"; exit 1; }
    echo "    app.js rebuilt"
    if [[ -d "$REPO_ROOT/apps/core/priv/static/textures" ]]; then
        echo "    textures: $(ls "$REPO_ROOT/apps/core/priv/static/textures/" | wc -l | tr -d ' ') files in priv/static/textures/"
    else
        echo "    WARN: priv/static/textures/ not found after build — mix phx.digest will fail"
    fi
else
    echo "    SKIP: node or build.js not found — Docker build will handle it"
fi

CORE_URL="https://${CORE_APP}.fly.dev"

echo ""
echo "==> Deploying ${CORE_APP}..."
ASSET_HASH="$(date +%s)-$(git rev-parse --short HEAD)"

CORE_HA_FLAG=()
if [[ "$PROD_MODE" -eq 0 ]]; then
    CORE_HA_FLAG=(--ha=false --vm-memory 1024)
fi
_core_deploy_once() {
    (cd "$REPO_ROOT" && fly deploy \
        --app "${CORE_APP}" \
        --config "${REPO_ROOT}/deploy/fly.core.toml" \
        --image-label "pr-${SANITISED}" \
        --depot=false \
        ${CORE_HA_FLAG[@]+"${CORE_HA_FLAG[@]}"} \
        --build-arg "ASSET_HASH=${ASSET_HASH}")
}
if ! deploy_with_retry "core" _core_deploy_once; then
    echo "FAIL deploy: core app deployment failed"
    exit 1
fi
echo "PASS deploy: core app deployed"

echo ""
echo "==> Signaling Fly proxy to route traffic..."
fly_machine_ids "${CORE_APP}" | while read -r mid; do
    [[ -z "$mid" ]] && continue
    fly machines start "$mid" --app "${CORE_APP}" 2>/dev/null && \
        echo "    Signaled machine ${mid}" || true
done
sleep 5

echo "==> Waiting for ${CORE_URL}/api/health..."
_PROXY_PORT=14987
fly proxy "${_PROXY_PORT}:4000" --app "${CORE_APP}" >/dev/null 2>&1 &
_PROXY_PID=$!

RETRIES=60
until curl -sf --max-time 10 "http://localhost:${_PROXY_PORT}/api/health" >/dev/null 2>&1 \
   || curl -sf --max-time 10 "${CORE_URL}/api/health" >/dev/null 2>&1; do
    if [[ $RETRIES -le 0 ]]; then
        kill "${_PROXY_PID}" 2>/dev/null || true
        echo "--- Fly app logs (last 30 lines) ---"
        (fly logs --app "${CORE_APP}" 2>&1 & sleep 8; kill %1 2>/dev/null) | tail -30 || true
        echo "--- End logs ---"
        echo "FAIL deploy: health check timed out for ${CORE_URL}"
        exit 1
    fi
    echo "    Not ready — retrying in 5s ($RETRIES attempts left)..."
    sleep 5
    ((RETRIES--))
done
kill "${_PROXY_PID}" 2>/dev/null || true
wait "${_PROXY_PID}" 2>/dev/null || true
echo "PASS deploy: health check passed"

echo ""
echo "==> Running migrations on ${CORE_APP}..."
machine_id="$(fly_machine_started_id "${CORE_APP}")"

if [[ -n "${machine_id}" ]]; then
    deploy_with_retry "in-container data corrections" \
        fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.correct_data(apply: true)'\"" \
        --app "${CORE_APP}" --timeout 60 \
        || { echo "FAIL deploy: data corrections failed"; exit 1; }
    echo "PASS deploy: data corrections applied"

    deploy_with_retry "in-container migrate" \
        fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.migrate()'\"" \
        --app "${CORE_APP}" --timeout 60 \
        || { echo "FAIL deploy: migrations failed"; exit 1; }
    echo "PASS deploy: migrations applied"

    echo "==> Verifying migration integrity (repo migrations vs applied)..."
    applied_versions="$(fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.print_applied_versions()'\"" \
        --app "${CORE_APP}" --timeout 60 2>/dev/null \
        | grep -oE 'APPLIED_VERSION [0-9]+' | awk '{print $2}' | sort -u)"
    repo_versions="$(find "${REPO_ROOT}/apps/core/priv/repo/migrations" -name '*.exs' -type f 2>/dev/null \
        | xargs -n1 basename 2>/dev/null | grep -oE '^[0-9]+' | sort -u)"
    if [[ -z "${applied_versions//[[:space:]]/}" ]]; then
        echo "FAIL deploy: could not read applied migration versions from ${CORE_APP} — cannot verify integrity" >&2
        exit 1
    fi
    unapplied="$(comm -23 <(echo "${repo_versions}") <(echo "${applied_versions}") | grep -E '^[0-9]+' || true)"
    if [[ -n "${unapplied//[[:space:]]/}" ]]; then
        echo "FAIL deploy: migrations present in the repo are NOT applied on ${CORE_APP}'s DB:" >&2
        echo "${unapplied}" | sed 's/^/  - /' >&2
        echo "  The deployed image is missing a migration — most often an uncommitted or" >&2
        echo "  untracked migration file that was absent at image-build time. Commit the" >&2
        echo "  migration (so it is embedded in the image) and redeploy. Deploying with a" >&2
        echo "  schema behind the code causes fail-closed outages." >&2
        exit 1
    fi
    echo "PASS deploy: migration integrity verified ($(echo "${repo_versions}" | grep -cE '^[0-9]+') repo migrations all applied)"

    if [[ "$PROD_MODE" -eq 1 ]]; then
        echo ""
        echo "==> Seeding ${CORE_APP} (prod owner + prober)..."
        deploy_with_retry "prod owner seed" \
            fly machine exec "${machine_id}" \
            "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.seed_prod()'\"" \
            --app "${CORE_APP}" --timeout 60 \
            || { echo "FAIL deploy: prod seed failed"; exit 1; }
        echo "PASS deploy: prod owner seed applied"

        if [[ -n "${STACKS_PROBER_EMAIL:-}" && -n "${STACKS_PROBER_PASSWORD:-}" ]]; then
            deploy_with_retry "prober seed" \
                fly machine exec "${machine_id}" \
                "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.seed_prober()'\"" \
                --app "${CORE_APP}" --timeout 60 \
                || { echo "FAIL deploy: prober seed failed"; exit 1; }
            echo "PASS deploy: prober seed applied"
        fi
    else
        SEEDS_FILE="apps/core/priv/repo/seeds.exs"
        seeds_changed=1  # default-on; flipped to 0 only when we confirm no diff
        if (cd "$REPO_ROOT" && git rev-parse --verify origin/main >/dev/null 2>&1); then
            if (cd "$REPO_ROOT" && git diff --quiet origin/main HEAD -- "$SEEDS_FILE" 2>/dev/null); then
                seeds_changed=0
            fi
        else
            echo "    (origin/main not fetched — will run preview seed unconditionally)"
        fi

        if [[ $seeds_changed -eq 0 ]]; then
            echo ""
            echo "==> Skipping preview seed: ${SEEDS_FILE} matches origin/main"
            echo "    Preview branch inherited fixtures from staging via Neon CoW."
            echo "    (staging is kept fresh by reseed-staging.yml on every push to main)"
        else
            echo ""
            echo "==> Seeding ${CORE_APP} (preview dev fixtures — seeds.exs differs from main)..."
            deploy_with_retry "preview seed" \
                fly machine exec "${machine_id}" \
                "/bin/sh -c \"/app/bin/core rpc 'Stacks.Release.seed_live()'\"" \
                --app "${CORE_APP}" --timeout 180 \
                || { echo "FAIL deploy: preview seed failed"; exit 1; }
            echo "PASS deploy: preview dev fixtures seeded"
        fi
    fi
else
    echo "FAIL deploy: no running machine — migrations and seeds did NOT run." >&2
    echo "       The stack is PARTIAL: on a preview it may still serve 200s, because the Neon branch" >&2
    echo "       inherits staging's schema and data. Do not use it. Tear down and redeploy" >&2
    echo "       (scripts/deploy-preview.sh tears down by default — Issue #305)." >&2
    exit 1
fi

# ── Deploy log shipper (prod only) ────────────────────────────────────────────
# One shipper per Fly org, not per preview. Fly's NATS log broadcast is
# org-scoped (`logs.>` emits every app's stdout/stderr), so a single
# subscriber captures core + vision + scraper + SearXNG + every preview
# app — we'd waste money + burn Axiom quota running one per PR. The
# preview branch of this script therefore skips the shipper entirely;
# preview logs still reach Axiom via the single prod shipper.
#
# Graceful-on-failure: the shipper going down doesn't block a release.
# Logs simply stop flowing to Axiom until the next successful deploy.
# Monitor via Axiom-side "no ingest for N min" alerts (future work).
#
# First-deploy bootstrap: if `thestacks-log-shipper` doesn't exist yet,
# `fly apps create` makes it, secrets stage, `fly deploy` builds the
# image from deploy/log-shipper/Dockerfile. No manual operator step.
if [[ "$PROD_MODE" -eq 1 ]]; then
    if [[ -z "${LOG_SHIPPER_ACCESS_TOKEN:-}" ]]; then
        echo "WARN: LOG_SHIPPER_ACCESS_TOKEN not set — skipping log shipper deploy (logs will not persist beyond Fly's short retention)."
    else
        LOG_SHIPPER_APP="${LOG_SHIPPER_APP:-thestacks-log-shipper}"
        echo ""
        echo "==> Deploying log shipper (app: ${LOG_SHIPPER_APP})..."

        ensure_fly_app "${LOG_SHIPPER_APP}"

        fly secrets set \
            LOG_SHIPPER_ACCESS_TOKEN="${LOG_SHIPPER_ACCESS_TOKEN}" \
            AXIOM_TOKEN="${AXIOM_TOKEN:-}" \
            AXIOM_DATASET="${AXIOM_DATASET:-}" \
            --app "${LOG_SHIPPER_APP}" --stage

        _log_shipper_deploy_once() {
            (cd "$REPO_ROOT/deploy/log-shipper" && fly deploy \
                --app "${LOG_SHIPPER_APP}" \
                --config "${REPO_ROOT}/deploy/fly.log-shipper.toml" \
                --yes)
        }

        if deploy_with_retry "log-shipper" _log_shipper_deploy_once; then
            echo "==> Verifying log shipper health via fly status (up to 300s)..."
            if wait_for_fly_checks "${LOG_SHIPPER_APP}" 300; then
                echo "PASS deploy: log shipper deployed"
            else
                echo "WARN deploy: log shipper deploy returned 0 but fly status never reported passing checks within 300s — logs may not ship until next deploy, core unaffected"
            fi
        else
            echo "WARN deploy: log shipper deployment failed — logs will not ship this cycle, core unaffected"
        fi
    fi
fi

if [[ -n "${SKIP_VISION:-}" ]]; then
    echo "SKIP warmup: SKIP_VISION set — vision not deployed, skipping warmup"
else

WARMUP_EMAIL="${PROBE_SEED_EMAIL:-owner@thestacks.app}"
WARMUP_PASSWORD="${PROBE_SEED_PASSWORD:-dev-password-123}"

warmup_canaries=(
    "${REPO_ROOT}/images/barcode_isbn_clean.jpg"
    "${REPO_ROOT}/images/not_a_book.jpg"
    "${REPO_ROOT}/images/screenshot_image_reversed.jpg"
    "${REPO_ROOT}/images/screenshot_image_reversed_and_cut_off.jpg"
    "${REPO_ROOT}/images/screenshot_mildly_obscured.jpg"
    "${REPO_ROOT}/images/screenshot_mixed_text.jpg"
)

echo ""
echo "==> Vision pipeline warmup against ${CORE_URL}/api/upload..."

echo "    Waiting for external edge routing (${CORE_URL}/api/health)..."
edge_ready=0
for _ in $(seq 1 24); do
    edge_code="$(curl -4 -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "${CORE_URL}/api/health" || true)"
    if [[ "${edge_code}" == "200" ]]; then
        edge_ready=1
        echo "    Edge routing ready (HTTP 200)."
        break
    fi
    sleep 5
done
if [[ $edge_ready -ne 1 ]]; then
    echo "WARN warmup: external edge never returned HTTP 200 (last: ${edge_code}) — skipping vision warmup"
    echo ""
    echo "PASS deploy: stack is live at ${CORE_URL}"
    echo "    Core app:    ${CORE_APP}"
    echo "    Modal app:   ${MODAL_APP}"
    echo "    Neon branch: ${NEON_BRANCH_NAME}"
    exit 0
fi

login_body_file="$(mktemp)"
login_payload_file="$(mktemp)"
python3 -c "import json,sys; json.dump({'email':sys.argv[1],'password':sys.argv[2]}, sys.stdout)" \
    "${WARMUP_EMAIL}" "${WARMUP_PASSWORD}" > "${login_payload_file}"
smoke_login_code="$(curl -4 -s -o "${login_body_file}" -w "%{http_code}" \
    --max-time 30 \
    "${CORE_URL}/api/auth/login" \
    -H "Content-Type: application/json" \
    --data-binary @"${login_payload_file}" \
    || true)"
rm -f "${login_payload_file}"
smoke_login="$(cat "${login_body_file}" 2>/dev/null || true)"
rm -f "${login_body_file}"
smoke_token="$(echo "${smoke_login}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${smoke_token}" ]]; then
    echo "FAIL warmup: could not authenticate as warmup user (HTTP ${smoke_login_code})"
    echo "    Check PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD."
    exit 1
fi

echo "    Uploading ${#warmup_canaries[@]} canaries in parallel (init → PUT → commit)..."
warmup_dir="$(mktemp -d)"
upload_pids=()
for img in "${warmup_canaries[@]}"; do
    (
        img_name="$(basename "$img")"

        init_body="${warmup_dir}/init_${img_name}"
        init_code="$(curl -4 -s -o "${init_body}" -w "%{http_code}" \
            --max-time 15 \
            -X POST "${CORE_URL}/api/upload/init" \
            -H "Authorization: Bearer ${smoke_token}" \
            -H "Content-Type: application/json" \
            -d '{"content_type":"image/jpeg"}' 2>/dev/null || true)"

        if [[ "${init_code}" != "201" ]]; then
            echo "    ${img_name}: init returned ${init_code} — skipping"
            exit 0
        fi

        img_id="$(python3 -c \
            "import json,sys; print(json.load(open('${init_body}')).get('image_id',''))" \
            2>/dev/null || true)"
        upload_url="$(python3 -c \
            "import json,sys; print(json.load(open('${init_body}')).get('upload_url',''))" \
            2>/dev/null || true)"

        if [[ -z "${img_id}" || -z "${upload_url}" ]]; then
            echo "    ${img_name}: init response missing image_id or upload_url — skipping"
            exit 0
        fi

        if [[ "${upload_url}" == /* ]]; then
            upload_url="${CORE_URL}${upload_url}"
        fi

        put_code="$(curl -4 -s -o /dev/null -w "%{http_code}" \
            --max-time 30 \
            -X PUT "${upload_url}" \
            -H "Content-Type: image/jpeg" \
            --data-binary "@${img}" 2>/dev/null || true)"

        if [[ "${put_code}" != "200" ]]; then
            echo "    ${img_name}: PUT to upload_url returned ${put_code} — skipping"
            exit 0
        fi

        commit_body="${warmup_dir}/commit_${img_name}"
        commit_code="$(curl -4 -s -o "${commit_body}" -w "%{http_code}" \
            --max-time 15 \
            -X POST "${CORE_URL}/api/upload/${img_id}/commit" \
            -H "Authorization: Bearer ${smoke_token}" 2>/dev/null || true)"

        if [[ "${commit_code}" == "202" ]]; then
            echo "${img_id}" > "${warmup_dir}/id_${img_name}"
        else
            echo "    ${img_name}: commit returned ${commit_code} — skipping"
        fi
    ) &
    upload_pids+=("$!")
done
for pid in "${upload_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

warmup_ids=()
for img in "${warmup_canaries[@]}"; do
    img_name="$(basename "$img")"
    id_file="${warmup_dir}/id_${img_name}"
    if [[ -f "$id_file" ]] && img_id="$(cat "$id_file")" && [[ -n "$img_id" ]]; then
        warmup_ids+=("$img_id")
        echo "    ${img_name}: accepted (image_id=${img_id})"
    else
        echo "    ${img_name}: upload did not return 202 — skipping"
    fi
done

rm -rf "${warmup_dir}"

if [[ ${#warmup_ids[@]} -eq 0 ]]; then
    echo "WARN warmup: all uploads failed — app may be broken, but the deploy step already passed health checks"
elif [[ ${#warmup_ids[@]} -lt ${#warmup_canaries[@]} ]]; then
    echo "WARN warmup: only ${#warmup_ids[@]}/${#warmup_canaries[@]} canaries accepted — partial queue"
else
    echo "PASS warmup: ${#warmup_ids[@]} canaries queued — Oban vision jobs will scale Modal in parallel with the gate"
fi
fi

if [[ -n "${SKIP_VISION:-}" ]]; then
    echo "SKIP probe: SKIP_VISION set — skipping vision completion probe"
elif [[ ${#warmup_ids[@]} -gt 0 ]]; then
    probe_id="${warmup_ids[0]}"
    echo ""
    echo "==> Vision pipeline completion probe (image_id=${probe_id})..."
    echo "    Waiting up to 180s for terminal status (resolved|rejected)..."

    probe_log="$(mktemp)"
    (curl -4 -sN --max-time 180 \
        -H "Accept: text/event-stream" \
        "${CORE_URL}/api/upload/${probe_id}/stream?token=${smoke_token}" 2>/dev/null \
        > "${probe_log}") &
    probe_pid=$!

    probe_terminal=""
    probe_started=$(date +%s)
    while [[ -z "${probe_terminal}" ]]; do
        if [[ -f "${probe_log}" ]]; then
            if grep -q '"status":"resolved"' "${probe_log}" 2>/dev/null; then
                probe_terminal="resolved"
                break
            fi
            if grep -q '"status":"rejected"' "${probe_log}" 2>/dev/null; then
                probe_terminal="rejected"
                break
            fi
        fi
        if (( $(date +%s) - probe_started >= 180 )); then
            break
        fi
        if ! kill -0 "${probe_pid}" 2>/dev/null; then
            break
        fi
        sleep 2
    done

    kill "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" 2>/dev/null || true

    if [[ "${probe_terminal}" == "resolved" ]]; then
        echo "PASS probe: vision pipeline reached 'resolved' for ${probe_id}"
    elif [[ "${probe_terminal}" == "rejected" ]]; then
        echo "PASS probe: vision pipeline reached 'rejected' for ${probe_id} (pipeline functional)"
    else
        echo "FAIL probe: vision pipeline did NOT reach a terminal status within 180s" >&2
        echo "  Last 20 lines of SSE stream from ${CORE_URL}/api/upload/${probe_id}/stream?token=<JWT>:" >&2
        tail -20 "${probe_log}" >&2 || true
        echo "" >&2
        echo "  Investigate: Modal logs for ${MODAL_APP} (modal app logs --app ${MODAL_APP})," >&2
        echo "  HMAC secret alignment between core (VISION_HMAC_SECRET) and Modal," >&2
        echo "  and recent commits to apps/vision/." >&2
        rm -f "${probe_log}"
        exit 1
    fi
    rm -f "${probe_log}"
fi

sleep 15

echo ""
echo "PASS deploy: stack is live at ${CORE_URL}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"
echo "    Neon branch: ${NEON_BRANCH_NAME}"
