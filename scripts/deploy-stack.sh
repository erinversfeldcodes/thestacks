#!/usr/bin/env bash
# scripts/deploy-stack.sh — deploy an ephemeral preview stack to Fly.io.
#
# Creates Neon branch, deploys Modal vision service, deploys Fly core app,
# runs migrations, seeds the DB, and waits for health. Does NOT run tests
# or clean up — that's the caller's responsibility.
#
# On success, writes the preview URL and metadata to stdout as PASS lines.
# On failure, writes FAIL lines and exits non-zero.
#
# Required env vars:
#   FLY_API_TOKEN           — Fly.io API token
#   NEON_STAGING_PROJECT_ID — Neon project ID for the `thestacks-staging`
#                             project (distinct from the prod project).
#                             Previews branch from `staging` within this
#                             project — zero lineage to production.
#
# Optional env vars:
#   NEON_STAGING_API_KEY    — Neon API key scoped to the staging project
#                             (required when creating a preview branch)
#   MODAL_TOKEN_ID          — Modal API token ID
#   MODAL_TOKEN_SECRET      — Modal API token secret
#   VISION_HMAC_SECRET      — Elixir → vision HMAC auth
#   SECRET_KEY_BASE         — Phoenix secret key base
#   NEON_PARENT_BRANCH      — Name of parent branch within the staging
#                             project (default: `staging`). Previews are
#                             copy-on-write children of this branch, so
#                             they inherit the migrations + dev fixture
#                             set without needing a per-preview seed step.
#                             See docs/deployment/NEON_BRANCH_TOPOLOGY.md.
#   GITHUB_HEAD_REF         — set automatically in GitHub Actions
#   PREVIEW_SUFFIX          — optional uniqueness component appended to every
#                             per-preview resource name (Fly apps, Modal app,
#                             Neon branch). Set by CI ("ci" + last 6 digits of
#                             the workflow run id) so concurrent local + CI
#                             previews of the same branch never share
#                             resources. Unset locally → historical bare
#                             names. See scripts/lib/preview-names.sh.
#   R2_ACCOUNT_ID           — Cloudflare R2 account ID (object storage)
#   R2_ACCESS_KEY_ID        — R2 access key
#   R2_SECRET_ACCESS_KEY    — R2 secret key
#   R2_BUCKET_NAME          — R2 bucket name (default: stacks-images)
#   VISION_TOGETHER_API_KEY — Together AI API key (LLM features)
#   SCRAPER_HMAC_SECRET     — Scraper sidecar HMAC auth
#   BRAVE_SEARCH_API_KEY    — Brave Search API key (source discovery)
#
# Usage:
#   scripts/deploy-stack.sh
#   scripts/deploy-stack.sh --branch my-feature-branch
#
# SKIP_VISION: when set (non-empty), skips the Modal vision deploy, the vision
# warmup, and the vision completion probe — and e2e/tests/upload.spec.ts skips
# itself. Use it to avoid Modal credit spend on changes that don't touch the
# vision path (apps/vision / the upload→vision code path). Unset it to re-enable
# full vision validation when that path changes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local .env for dev secrets if running outside CI.
if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

# ── Helpers ──────────────────────────────────────────────────────────────────
# Run a deploy command, retry once on failure, hard-fail if the retry also
# fails. Used for every non-core component (Modal vision, scraper, SearXNG,
# log-shipper) in both prod and preview modes — transient Fly/Modal/network
# flakes are the common failure, and one retry absorbs them without
# tolerating genuinely-broken deploys. Hard-fail happens BEFORE core deploy,
# so no user-facing code is ever published on a half-upgraded stack.
deploy_with_retry() {
    local name="$1"; shift
    if "$@"; then return 0; fi
    echo "    retry: ${name} failed once; retrying in 5s..."
    sleep 5
    if "$@"; then return 0; fi
    echo "FAIL deploy: ${name} failed twice; aborting" >&2
    return 1
}

# Resolve a Neon branch id by name, distinguishing a genuine "branch absent"
# from a transient/hard Neon API failure (Issue #177). The old inline
# `curl … | python3 … 2>/dev/null || true` collapsed every failure — network
# blip, 5xx/429, expired key, malformed body — into an empty id, which the
# caller then misreported as "branch not found." This helper surfaces the real
# error instead.
#
# Usage: neon_branch_id_by_name <project_id> <branch_name>
#   stdout: the matching branch id, or EMPTY if the name is genuinely absent
#   return 0: API succeeded (branch found OR genuinely absent)
#   return 1: API failed (network error, 5xx/429 after bounded retries, or a
#             non-transient 4xx) — a distinct "Neon API" message goes to stderr
#             and NO id is printed. The caller decides how to react.
#
# Reads NEON_STAGING_API_KEY from the environment (same as the rest of the
# script). Retries transient failures a bounded number of times with backoff;
# `sleep` between attempts keeps this from hammering the API.
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
        # HTTP status is the final line; the JSON body is everything above it.
        http_code="${response##*$'\n'}"
        body="${response%$'\n'*}"

        # Transient: transport error, rate limit (429), or any 5xx → retry.
        if (( curl_rc != 0 )) || [[ "$http_code" == 429 || "$http_code" == 5?? ]]; then
            if (( attempt < max_attempts )); then
                sleep "$attempt"
                continue
            fi
            echo "FAIL deploy: Neon API call failed (HTTP ${http_code:-none} / curl rc ${curl_rc}) after ${attempt} attempts querying branches for project ${project_id}" >&2
            return 1
        fi

        # Non-transient API error (e.g. 401/403/404) — do not retry.
        if [[ "$http_code" != 2?? ]]; then
            echo "FAIL deploy: Neon API call failed (HTTP ${http_code} / curl rc ${curl_rc}) querying branches for project ${project_id}" >&2
            return 1
        fi

        # Success: parse the body and print the matching id (empty if absent).
        # Pass branch_name OUT-OF-BAND as argv[1] (single-quoted python source,
        # no shell interpolation) so a name containing a single quote — e.g. a
        # git ref like preview/foo'bar — can't break the python literal and get
        # silently misclassified as "branch absent".
        printf '%s' "$body" | python3 -c '
import json, sys
target = sys.argv[1]
branches = json.load(sys.stdin).get("branches", [])
match = [b["id"] for b in branches if b.get("name") == target]
print(match[0] if match else "")
' "$branch_name"
        return 0
    done
    # Unreachable in practice (the loop returns on every path), but keep a
    # defensive non-zero so a logic slip can never masquerade as success.
    echo "FAIL deploy: Neon API call exhausted retries querying branches for project ${project_id}" >&2
    return 1
}

# `fly apps create` is idempotent but prints a confusing "App already exists"
# error to stderr with exit code 1 on subsequent calls. Swallow both so the
# script's own failure signals stay legible.
ensure_fly_app() {
    fly apps create "$1" 2>&1 | grep -v "^Error" || true
}

# All machine IDs for an app (one per line). Empty output = no machines.
fly_machine_ids() {
    fly machines list --app "$1" --json 2>/dev/null \
        | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    print(m['id'])
" 2>/dev/null || true
}

# ID of the first started machine for an app, or empty if none started.
fly_machine_started_id() {
    fly machines list --app "$1" --json 2>/dev/null \
        | python3 -c "
import json,sys
machines = json.load(sys.stdin)
started = [m for m in machines if m.get('state') == 'started']
print(started[0]['id'] if started else '')
" 2>/dev/null || true
}

# Verify that a Fly app has at least one started machine with all its
# `[[checks]]` entries passing. Polls `fly status --json` up to the given
# deadline, returns 0 on success, non-zero on timeout.
#
# `fly deploy` already waits for checks before returning 0, but upstream
# images like searxng/searxng lack curl/wget so we can't double-check
# from inside the container via `fly ssh console -C curl ...`. Parsing
# `fly status --json` is tool-agnostic — it asks Fly's proxy for the
# state of the same health checks defined in the app's fly.toml. No
# in-container tooling assumed; works against any image.
#
# Usage: wait_for_fly_checks <app> <timeout_seconds>
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

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ -z "${FLY_API_TOKEN:-}" ]]; then
    echo "SKIP: FLY_API_TOKEN not set — skipping deploy."
    exit 0
fi

if ! command -v fly &>/dev/null; then
    echo "SKIP: flyctl not installed (brew install flyctl)"
    exit 0
fi

# ── Branch name → Fly app name ────────────────────────────────────────────────
BRANCH=""
# Production mode: stable app names + existing prod DB (no Neon branch).
# Driven exclusively by the --production arg (explicit at the call site).
# An earlier version also honoured $STACKS_CORE_PROD=true, but a stale
# export in an operator's shell would silently promote a preview deploy to
# prod — an env-var entry point without a visible invocation cue. Dropped
# 2026-04-24; the GitHub production workflow now passes --production
# directly.
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
    # Prod uses the existing production DB via DATABASE_URL — not a Neon
    # branch. Suppress branch creation by clearing NEON_STAGING_API_KEY
    # locally so the preview-branch block below is a no-op.
    NEON_STAGING_API_KEY=""
    # Test-only helper endpoints (e.g. GET /api/test/confirmation-token,
    # Issue #124) must NEVER be enabled in production — they leak an
    # account-activation token. Force the gate env empty here so no stale
    # shell/.env export can promote it onto the prod app; the prod-only
    # "Purge test-helper flag" block below also unsets any lingering Fly
    # secret as defense-in-depth.
    STACKS_E2E_TEST_HELPERS=""
    # Age-gating ships DARK in production (ADR-020): the enforcement + verification
    # machinery is built and tested but inert until a real age-verification provider
    # (Smile ID / Yoti / Sumsub) is integrated. Force the flag empty here so no stale
    # shell/.env export can promote it onto the prod app — production must launch with
    # age-gating invisible and inert.
    AGE_GATING_ENABLED=""
    # Prod uses the in-code default public rate limit (200/60s/IP). Leave empty
    # so the RATE_LIMIT_PUBLIC secret isn't staged; preview raises it below so the
    # parallel E2E suite (many public reads from one runner IP) isn't 429'd.
    RATE_LIMIT_PUBLIC=""
    RATE_LIMIT_E2E_HELPER=""
    echo "==> Deploy stack in PRODUCTION mode"
else
    # Preview-only preflight: the preview branch-creation block below
    # talks to Neon's API using the staging project ID. Prod mode doesn't
    # touch Neon branching (DATABASE_URL is composed from STACKS_PROD_DB_*
    # in deploy-production.yml), so this check stays scoped to preview
    # mode — gating it unconditionally would silently short-circuit prod
    # deploys with SKIP when the staging secret isn't in the prod env.
    if [[ -z "${NEON_STAGING_PROJECT_ID:-}" ]]; then
        echo "SKIP: NEON_STAGING_PROJECT_ID not set — skipping preview deploy."
        exit 0
    fi
    CORE_APP="${PREVIEW_CORE_APP}"
    MODAL_APP="${PREVIEW_MODAL_APP}"
    # Enable the E2E test-helper endpoints (Issue #124) on PREVIEW apps only.
    # GET /api/test/confirmation-token returns 404 unless this server env
    # == "1"; the confirm-email + onboarding E2E specs need it live on the
    # preview app. This is set ONLY in the preview branch of this
    # conditional — the --production branch above forces it empty so it can
    # never reach the prod app.
    STACKS_E2E_TEST_HELPERS="1"
    # Age-gating ships dark in prod (ADR-020) but its ENFORCEMENT is what the
    # age-gate E2E specs exercise, so it must be ON for the preview stack. Turn it
    # on here (preview branch only) alongside the test-helper flag — the --production
    # branch above forces it empty so it can never reach the prod app.
    AGE_GATING_ENABLED="true"
    # Raise the public rate limit well above the 200/60s default for the preview
    # stack: the E2E suite runs many specs in parallel from one runner IP, all
    # hitting per-IP public endpoints (catalogue/search/profile/config), which
    # otherwise 429s. Preview-only; prod keeps the in-code default.
    RATE_LIMIT_PUBLIC="5000"
    # Same reasoning for the E2E test-helper bucket (confirmation-token /
    # age-verification): its prod default is a deliberately tight 10/60s/IP, but
    # the parallel suite registers/confirms many users from one runner IP and
    # 429s. Raise it for preview only; prod never enables the helpers at all.
    RATE_LIMIT_E2E_HELPER="5000"
    echo "==> Deploy stack for branch: ${BRANCH}"

    # ── Upstream resolver preflight (preview only) ────────────────────────
    # A preview stack exists to run the deployed E2E suite, and the upload
    # tests are meaningless when Open Library is down (EnrichBookJob can
    # never replace the placeholder title). Check the upstreams NOW —
    # before the ~30-min Neon-branch + Fly + Modal cycle — instead of
    # discovering it in a 6-minute E2E poll timeout at the very end.
    # Google Books issues (incl. quota exhaustion) are WARN-only inside
    # the preflight script; only an Open Library outage aborts. Prod
    # deploys skip this: shipping code must not be blocked by OL weather.
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

# ── Create Neon branch ────────────────────────────────────────────────────────
if [[ -n "${NEON_STAGING_API_KEY:-}" ]]; then
    echo ""
    echo "==> Creating Neon DB branch for preview..."

    # Parent branch for preview creation. Default `staging` — a
    # migrations + fixture-data branch in the dedicated `thestacks-staging`
    # Neon project, which has zero copy-on-write lineage to production.
    # Previews therefore never clone production data and inherit the dev
    # fixture set automatically (no per-preview seed step).
    # See docs/deployment/NEON_BRANCH_TOPOLOGY.md.
    NEON_PARENT_BRANCH="${NEON_PARENT_BRANCH:-staging}"
    echo "    Parent branch: ${NEON_PARENT_BRANCH}"
    # A helper non-zero (real Neon API failure) aborts via `|| exit 1` with the
    # helper's distinct "Neon API" stderr; a helper 0 + empty id is a GENUINE
    # absence and gets the "parent branch not found" message. The two are now
    # never conflated (Issue #177).
    NEON_PARENT_BRANCH_ID="$(neon_branch_id_by_name "${NEON_STAGING_PROJECT_ID}" "${NEON_PARENT_BRANCH}")" || exit 1

    if [[ -z "$NEON_PARENT_BRANCH_ID" ]]; then
        echo "FAIL deploy: Neon parent branch '${NEON_PARENT_BRANCH}' not found in project ${NEON_STAGING_PROJECT_ID}" >&2
        exit 1
    fi
    echo "    Parent branch ID: ${NEON_PARENT_BRANCH_ID}"

    # Stale sibling-branch lookup. Unlike the parent lookup, an API failure here
    # is NOT fatal: worst case a stale preview branch lingers (the create step
    # below would then fail loudly on its own). Surface the failure as a WARNING
    # and continue rather than aborting the whole deploy — but never swallow it.
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
        echo "    Connection URI obtained."
    else
        echo "    WARNING: no connection URI returned."
    fi
else
    if [[ "$PROD_MODE" -eq 1 ]]; then
        # Prod deploys never branch Neon; DATABASE_URL is composed from
        # STACKS_PROD_DB_* in deploy-production.yml. The empty
        # NEON_STAGING_API_KEY is set deliberately above (line ~181) to
        # make this block a no-op — not a missing-config error.
        echo "    No Neon branch creation in production mode (DATABASE_URL is composed upstream)."
    else
        echo "SKIP: NEON_STAGING_API_KEY not set — skipping Neon branch creation."
    fi
    NEON_CONNECTION_URI=""
fi

# ── Deploy vision service to Modal ────────────────────────────────────────────
if [[ -z "${SKIP_VISION:-}" ]] && [[ -n "${MODAL_TOKEN_ID:-}" ]] && [[ -n "${MODAL_TOKEN_SECRET:-}" ]]; then
    # Pick a Python that has the `modal` SDK importable.
    #
    # Local dev: the interactive shell's `python3` resolves to
    # .venv-tools/bin/python3 (per flake.nix shellHook). That venv
    # intentionally does NOT carry the heavy `modal` SDK — only
    # sqlfluff, checkov, dbt-checkpoint. The vision app's runtime venv
    # (apps/vision/.venv) does have modal (declared in
    # apps/vision/requirements.txt). Prefer that.
    #
    # CI (deploy-production.yml + deploy-preview.yml): there is no
    # apps/vision/.venv (setup.sh isn't run on the runner). The
    # workflow `pip install modal` directly into the runner's
    # tool-cache python, so falling back to plain `python3` works.
    #
    # Order: vision venv first, plain `python3` second, fail loudly
    # if neither has modal.
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
    # Retry-once + hard-fail for both prod and preview. Unified 2026-04-24 —
    # preview was previously fail-fast to avoid slowing ephemeral stacks on
    # transient flakes, but a broken Modal vision deploy produces a preview
    # where E2E tests flake confusingly rather than fail cleanly. One retry
    # absorbs Modal-side flakes in either environment.
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

    # Try SDK lookup first, fall back to parsing the deploy output.
    # The SDK call can fail if the function isn't registered yet.
    VISION_SERVICE_URL="$(MODAL_TOKEN_ID="${MODAL_TOKEN_ID}" MODAL_TOKEN_SECRET="${MODAL_TOKEN_SECRET}" \
        "$MODAL_PYTHON" -c "
import modal
f = modal.Function.from_name('${MODAL_APP}', 'vision_api')
print(f.web_url)
" 2>/dev/null || true)"

    # Fallback: parse URL from `modal deploy` output. Modal's tree formatter
    # wraps long URLs across lines with multi-byte UTF-8 box chars (│├└─🔨)
    # that sed can't strip reliably. Use Python for portable parsing.
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

# ── Deploy scraper service ──────────────────────────────────────────────────
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
    # Retry-once + hard-fail for both prod and preview. Unified 2026-04-24 —
    # a scraper deploy failure produces a preview where price enrichment is
    # silently degraded, which makes E2E tests flaky in ways unrelated to
    # the PR. Better to fail the deploy and surface the scraper issue
    # directly. Retry-once absorbs transient Fly flakes.
    if deploy_with_retry "scraper" _scraper_deploy_once; then
        echo "PASS deploy: scraper deployed at ${SCRAPER_INTERNAL_URL}"
    else
        exit 1
    fi
elif [[ -z "${SCRAPER_HMAC_SECRET:-}" ]]; then
    echo "WARN: SCRAPER_HMAC_SECRET not set — skipping scraper deploy."
    SCRAPER_INTERNAL_URL=""
fi

# ── Deploy SearXNG (ephemeral per preview; stable in prod) ─────────────────
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

    # If the previous deploy pushed the app into a `suspended` state (N
    # consecutive OOM-kill restart attempts), resume before we try again.
    # `fly apps resume` is idempotent — no-ops if the app isn't suspended.
    if [[ "$PROD_MODE" -eq 1 ]]; then
        fly apps resume "${SEARXNG_APP}" 2>&1 | grep -v "^Error" || true
    fi

    fly secrets set \
        SEARXNG_SECRET_KEY="${SEARXNG_SECRET_KEY}" \
        --app "${SEARXNG_APP}" --stage

    # Render settings.yml into the Docker build context. The Dockerfile
    # COPYs `settings.rendered.yml` into `/etc/searxng/settings.yml`, so
    # the first boot of the container sees our curated 5-engine config
    # instead of the upstream default (which OOM-killed a 256MB VM
    # within seconds). The rendered file is gitignored and cleaned up
    # after the deploy.
    SETTINGS_TEMPLATE="${REPO_ROOT}/deploy/searxng/settings.yml"
    SETTINGS_RENDERED="${REPO_ROOT}/deploy/searxng/settings.rendered.yml"
    sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|g" \
        "${SETTINGS_TEMPLATE}" > "${SETTINGS_RENDERED}"
    trap '[[ -f "${SETTINGS_RENDERED:-/dev/null}" ]] && rm -f "${SETTINGS_RENDERED}"' EXIT

    # CD into the Dockerfile's directory so Fly's remote builder uses it
    # as the build context. Running this from the repo root produced a
    # 2-byte context (root .dockerignore filtered everything) and the
    # COPY settings.rendered.yml failed at build time. See the top
    # comment in deploy/searxng/Dockerfile for the diagnosis.
    _searxng_deploy_once() {
        (cd "$REPO_ROOT/deploy/searxng" && fly deploy \
            --app "${SEARXNG_APP}" \
            --config "${REPO_ROOT}/deploy/fly.searxng.toml" \
            --yes)
    }

    # Retry-once + hard-fail + 300s health check, unified across prod and
    # preview (2026-04-24). SearXNG is in the SLO gate's hot path via
    # /internal/deps-check. If it can't come up healthy, the gate pollutes
    # its measurements: availability drops, real_5xx_rate rises from
    # deps-check 503s, downstream latency SLIs shift because catalogue-
    # path calls touch SearXNG, and db_pool_queue_p95_ms creeps up from
    # retries eating connections. All false signals relative to core's
    # actual health. Hard-fail up front so the rollback path (prod) or PR
    # break (preview) fires on a clean named signal rather than a noisy
    # gate breach on a derived metric.
    #
    # SearXNG's first-passing-check can take 3–4 minutes on a cold deploy:
    # custom image build + 512MB VM allocation + Python startup + engine
    # loading. Observed 234s on the 2026-04-20 run — an earlier 90s
    # timeout cleared SEARXNG_URL on core and broke deps-check. 300s
    # gives room.
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

# ── Deploy metrics store (VictoriaMetrics) ──────────────────────────────────
# Self-hosted metrics store (ADR-021 / Epic #249). The core app PUSHES its
# PromEx metrics here (Core.PromEx.MetricsPusher → /api/v1/import/prometheus over
# 6PN), replacing Fly's managed-Prometheus scrape that never ingested a sample
# (#248). Preview: ephemeral per-PR app, torn down by cleanup-preview.sh. Prod:
# always-on (min_machines_running=1). Non-fatal: a metrics-store hiccup must not
# break a PR's E2E — if it fails we simply don't set the push URL on core.
if [[ "$PROD_MODE" -eq 1 ]]; then
    VM_APP="${VM_APP:-thestacks-victoriametrics}"
else
    VM_APP="${PREVIEW_VM_APP}"
fi
VM_INTERNAL_URL="http://${VM_APP}.internal:8428"
METRICS_PUSH_URL=""

echo ""
echo "==> Deploying metrics store (app: ${VM_APP})..."
if [[ "$PROD_MODE" -eq 0 ]]; then
    fly apps destroy "${VM_APP}" --yes 2>&1 | grep -v "^Error" || true
fi
ensure_fly_app "${VM_APP}"

# VM needs a data volume at /victoria-metrics-data. Preview recreated it fresh
# with the app; prod creates it once. Match fly.core.toml's primary_region.
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
    # 6PN-only app (no public IP): Fly's proxy does not enforce
    # min_machines_running, so explicitly start the machine after deploy — the
    # same idiom the core block uses below. Without this the VM can sit stopped
    # and the core push silently no-ops.
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

# ── Create core app ───────────────────────────────────────────────────────────
# Do NOT destroy the app between deployments. fly deploy replaces machines
# in-place, so destroy+create is redundant and causes a NXDOMAIN DNS cache
# entry on macOS that breaks all subsequent curl/Node DNS lookups for 5+ min.
echo ""
echo "==> Creating ephemeral Fly app (if not already exists)..."
ensure_fly_app "${CORE_APP}"

# Allocate a shared IPv4 address. Fly apps on the Machines platform get IPv6-only
# by default, which means `curl -4` (and GitHub runners, which lack IPv6 connectivity
# to Fly's anycast AAAA edge) cannot reach the app. `--shared` is SNI-routed and
# free; `|| true` because re-allocation on an app that already has one is a noop
# that prints an error.
fly ips allocate-v4 --shared --app "${CORE_APP}" 2>&1 || true

# ── Stage core secrets ────────────────────────────────────────────────────────
# DATABASE_URL sourcing:
#   preview: NEON_CONNECTION_URI was populated by the Neon-branch creation block above.
#   prod:    NEON_STAGING_API_KEY is cleared → no branch → caller must provide
#            DATABASE_URL directly in the environment (from a GitHub secret in CI,
#            or an operator export for local prod-mode use).
EFFECTIVE_DATABASE_URL="${NEON_CONNECTION_URI:-${DATABASE_URL:-}}"

fly secrets set \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    GUARDIAN_SECRET_KEY="${GUARDIAN_SECRET_KEY:-}" \
    VISION_HMAC_SECRET="${VISION_HMAC_SECRET:-}" \
    CLOAK_KEY="${CLOAK_KEY:-}" \
    VISION_SERVICE_URL="${VISION_SERVICE_URL}" \
    PHX_HOST="${CORE_APP}.fly.dev" \
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
    ${RATE_LIMIT_PUBLIC:+RATE_LIMIT_PUBLIC="${RATE_LIMIT_PUBLIC}"} \
    ${RATE_LIMIT_E2E_HELPER:+RATE_LIMIT_E2E_HELPER="${RATE_LIMIT_E2E_HELPER}"} \
    SMOKE_TESTS_ENABLED="true" \
    --app "${CORE_APP}" --stage

# ── Purge test-helper flag (prod only, Issue #124) ───────────────────────────
# Belt-and-suspenders: production and preview use disjoint Fly app names
# (thestacks-core vs preview-*), so this script never stages the flag onto
# the prod app in the first place — the ${STACKS_E2E_TEST_HELPERS:+...}
# expansion above sees an empty value in prod mode. Still, explicitly unset
# the secret on prod so any value set by hand (or a future code path) can't
# linger and silently expose GET /api/test/confirmation-token in production.
# --stage keeps it batched with the deploy above; || true tolerates the
# common case where the secret was never present.
if [[ "$PROD_MODE" -eq 1 ]]; then
    echo ""
    echo "==> Ensuring test-helper flag is unset on ${CORE_APP} (prod safety)..."
    fly secrets unset STACKS_E2E_TEST_HELPERS --app "${CORE_APP}" --stage 2>/dev/null \
        || echo "    (STACKS_E2E_TEST_HELPERS not present — nothing to unset)"
fi

# ── DATABASE_URL assertion (prod only, P2 #9) ────────────────────────────────
# On a brand-new prod app no DATABASE_URL is configured yet, and
# `${NEON_CONNECTION_URI:+...}` above means we only set it from a preview
# Neon branch. In prod mode DATABASE_URL must already be present as a Fly
# secret (the operator-blessed prod Neon connection string). If it isn't,
# boot fails with a cryptic runtime.exs raise after the container has
# already rolled. Fail fast here with a clear message instead.
if [[ "$PROD_MODE" -eq 1 ]]; then
    echo ""
    echo "==> Verifying DATABASE_URL was composed for ${CORE_APP}..."
    # Check the env-var we just fed to `fly secrets set` rather than querying
    # Fly back — on a never-successfully-deployed app, staged-but-uncommitted
    # secrets don't always show in `fly secrets list`. If EFFECTIVE_DATABASE_URL
    # is non-empty here, the Fly stage call above received it; if empty, the
    # caller (deploy-production.yml Compose step) didn't provide DATABASE_URL
    # or a Neon preview URI, and boot would fail cryptically at runtime.exs.
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

# ── Generate proto Elm decoders ───────────────────────────────────────────────
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

# ── Generate Ecto schemas from proto ────────────────────────────────────────
# Use gen-ecto-proto.sh instead of `mix proto.sync` — it bootstraps without
# requiring app compilation (avoids chicken-and-egg when gen/ is gitignored).
echo ""
echo "==> Generating Ecto schemas from proto..."
bash "$REPO_ROOT/scripts/gen-ecto-proto.sh" \
    || { echo "FAIL deploy: gen-ecto-proto.sh failed"; exit 1; }
# Also generate inter-service proto structs (AssociateRequest etc.)
python3 "$REPO_ROOT/scripts/gen_python_proto.py" --language elixir \
    || { echo "FAIL deploy: gen_python_proto.py --language elixir failed"; exit 1; }
if [[ ! -d "$REPO_ROOT/apps/core/lib/stacks/gen" ]] || [[ -z "$(ls -A "$REPO_ROOT/apps/core/lib/stacks/gen" 2>/dev/null)" ]]; then
    echo "FAIL deploy: apps/core/lib/stacks/gen/ is empty after generation"; exit 1
fi
echo "    Ecto schemas generated to apps/core/lib/stacks/gen/"

# ── Run prod migrations BEFORE image cutover ────────────────────────────────
# Issue #137 phase 4: a partially-failing migration must abort the deploy
# while the old image is still serving traffic. Running migrate here, after
# the Elixir codegen above (which the compile depends on) and BEFORE the
# `fly deploy` cutover below, gives that guarantee — `set -e` propagates a
# migrate failure as a script failure, the workflow aborts before any
# image swap, and the old image keeps serving.
#
# Prod-only: preview deploys still run their migrations in-container as
# part of the post-deploy step (line 731). Phase 7 iteration consolidated
# this from a separate `migrate-prod` workflow step into deploy-stack.sh
# to avoid duplicating compile + codegen between the workflow and this
# script. The in-container migrate at line 731 stays as defense-in-depth.
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
            MIX_ENV=prod mix ecto.migrate); then
        echo "FAIL deploy: prod migration failed — old image still serving traffic"
        exit 1
    fi
    echo "PASS deploy: prod migrations applied"
fi

# ── Build frontend assets ─────────────────────────────────────────────────────
echo ""
echo "==> Rebuilding frontend assets via esbuild..."
if command -v node &>/dev/null && [[ -f "$REPO_ROOT/apps/core/assets/build.js" ]]; then
    # Clear Elm incremental build cache before every deploy. The esbuild-plugin-elm
    # uses elm-stuff/ as a compilation cache keyed by file mtime, not content hash.
    # A stale cache can produce an identical app.js even when Elm source changes.
    echo "    Clearing Elm incremental build cache (elm-stuff/)..."
    rm -rf "$REPO_ROOT/apps/core/assets/elm/elm-stuff"
    (cd "$REPO_ROOT/apps/core/assets" && node build.js --production) \
        || { echo "FAIL deploy: frontend build failed"; exit 1; }
    echo "    app.js rebuilt"
    # Verify textures were copied (build.js follows static/textures symlink)
    if [[ -d "$REPO_ROOT/apps/core/priv/static/textures" ]]; then
        echo "    textures: $(ls "$REPO_ROOT/apps/core/priv/static/textures/" | wc -l | tr -d ' ') files in priv/static/textures/"
    else
        echo "    WARN: priv/static/textures/ not found after build — mix phx.digest will fail"
    fi
else
    echo "    SKIP: node or build.js not found — Docker build will handle it"
fi

# ── Deploy core ──────────────────────────────────────────────────────────────
CORE_URL="https://${CORE_APP}.fly.dev"

echo ""
echo "==> Deploying ${CORE_APP}..."
# Pass a unique ASSET_HASH to bust the remote builder cache for priv/static.
# Without this, the builder reuses a stale COPY layer from a previous build
# that may not have included textures or freshly-built assets.
ASSET_HASH="$(date +%s)-$(git rev-parse --short HEAD)"

# One-retry on the core deploy too. Fly's remote-builder occasionally
# returns transient errors mid-build — e.g. "unable to upgrade to h2c,
# received 500" — that disappear on the very next attempt. We already
# retry-once for scraper / searxng / log-shipper / Modal vision; core
# is the most expensive deploy in the pipeline so a 5-second retry
# cycle is cheap compared to a wholesale stack rebuild on the next
# push. Hard-fails after two attempts so a genuinely-broken build
# still surfaces.
_core_deploy_once() {
    (cd "$REPO_ROOT" && fly deploy \
        --app "${CORE_APP}" \
        --config "${REPO_ROOT}/deploy/fly.core.toml" \
        --image-label "pr-${SANITISED}" \
        --depot=false \
        --build-arg "ASSET_HASH=${ASSET_HASH}")
}
if ! deploy_with_retry "core" _core_deploy_once; then
    echo "FAIL deploy: core app deployment failed"
    exit 1
fi
echo "PASS deploy: core app deployed"

# ── Signal proxy to route traffic ─────────────────────────────────────────────
# fly deploy creates and health-checks machines internally, but the Fly proxy
# doesn't always route external HTTPS traffic immediately. An explicit
# `fly machines start` via the Machines API signals the proxy to update its
# routing table. Without this, external curls can fail for 100+ seconds even
# though internal health checks pass.
echo ""
echo "==> Signaling Fly proxy to route traffic..."
fly_machine_ids "${CORE_APP}" | while read -r mid; do
    [[ -z "$mid" ]] && continue
    fly machines start "$mid" --app "${CORE_APP}" 2>/dev/null && \
        echo "    Signaled machine ${mid}" || true
done
sleep 5

echo "==> Waiting for ${CORE_URL}/api/health..."
# After fly apps destroy → fly apps create, macOS caches a stale NXDOMAIN for
# the hostname. Flushing requires sudo. Instead, tunnel via fly proxy which uses
# Fly's WireGuard connection and needs no DNS resolution at all.
_PROXY_PORT=14987
fly proxy "${_PROXY_PORT}:4000" --app "${CORE_APP}" >/dev/null 2>&1 &
_PROXY_PID=$!

RETRIES=30
until curl -sf --max-time 10 "http://localhost:${_PROXY_PORT}/api/health" >/dev/null 2>&1; do
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

# ── Migrate (post-deploy, defense-in-depth) ─────────────────────────────────
# In-container migrate as defense-in-depth. The primary prod-migrate path
# is the runner-side `mix ecto.migrate` block above (right after the
# Elixir codegen, before the `fly deploy` cutover) — that's where a
# partial migration aborts the deploy while the old image still serves
# traffic. On the healthy prod path, by the time this in-container call
# runs the schema is already at the target version, so `Ecto.Migrator`
# finds no pending migrations and returns :ok immediately.
#
# The in-container call is preserved as a safety net for paths where the
# runner-side step was somehow skipped (operator override, future code
# change, preview deploys that don't run the prod-only runner step).
echo ""
echo "==> Running migrations on ${CORE_APP}..."
machine_id="$(fly_machine_started_id "${CORE_APP}")"

if [[ -n "${machine_id}" ]]; then
    # deploy_with_retry: machine execs right after a rolling deploy are the
    # flakiest calls here — observed transient "failed_precondition: exec
    # request failed: EOF" (run 28928687981) aborting an otherwise-healthy
    # deploy. One 5s retry absorbs the settle window. Issue #170 G.
    deploy_with_retry "in-container migrate" \
        fly machine exec "${machine_id}" \
        "/bin/sh -c \"/app/bin/core eval 'Stacks.Release.migrate()'\"" \
        --app "${CORE_APP}" --timeout 60 \
        || { echo "FAIL deploy: migrations failed"; exit 1; }
    echo "PASS deploy: migrations applied"

    # ── Migration integrity guard (Issue #180 follow-up) ─────────────────────
    # `Stacks.Release.migrate()` only applies migrations that are PRESENT IN THE
    # IMAGE, and reports "already up" when it finds none pending. If a migration
    # exists in the repo but never reached the image (classically: an
    # uncommitted/untracked migration file that was absent from the working tree
    # at image-build time), migrate() silently succeeds while the deployed schema
    # stays behind the code — which surfaces later as fail-closed auth/DB
    # outages (see docs/runbooks/auth-session-family-outage.md). Guard against it
    # by asserting every migration VERSION present in the repo is actually
    # applied on the deployed DB. This runs for prod AND preview deploys.
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

    # ── Seed ─────────────────────────────────────────────────────────────────
    # Production: seed_prod creates exactly one owner from PROD_OWNER_*.
    # Preview: only re-seed if THIS PR has unmerged changes to seeds.exs.
    # The staging branch (parent of every preview/<pr>) is auto-reseeded on
    # push to main by .github/workflows/reseed-staging.yml, so previews of
    # PRs that don't touch seeds.exs inherit fresh fixtures via Neon's
    # copy-on-write — no per-preview cost. PRs that DO touch seeds.exs
    # carry unmerged fixture changes that staging can't reflect yet, so
    # those previews run the seed against their preview branch.
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
        # Detect unmerged changes to seeds.exs. Default to "changed" if we
        # can't determine (no origin/main reachable, no git repo) — safer
        # to over-seed (idempotent) than silently miss new fixtures.
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
            # Seed via `rpc` (run INSIDE the already-running node), NOT `eval`.
            # `eval 'seed()'` starts a SECOND BEAM next to the serving Phoenix, and
            # on the 512 MB preview VM that second BEAM plus the ~160-book in-memory
            # seed set OOMs the machine — the exec drops with a bare
            # `failed_precondition: exec request failed: EOF` ~11s in (no Elixir
            # output), deterministically, both retries (Issue #171 / #177). `rpc`
            # runs `seed_live/0` in the existing node, so no second BEAM is spawned.
            #
            # `seed_live/0` is gate-less by identity (like seed_prod/seed_prober) —
            # `rpc` cannot inject ALLOW_SEEDS into the running node — and is called
            # ONLY here in the preview branch, never prod. 180s timeout covers the
            # hundreds of insert_all rows. Retry wrapper stays for genuine transients.
            deploy_with_retry "preview seed" \
                fly machine exec "${machine_id}" \
                "/bin/sh -c \"/app/bin/core rpc 'Stacks.Release.seed_live()'\"" \
                --app "${CORE_APP}" --timeout 180 \
                || { echo "FAIL deploy: preview seed failed"; exit 1; }
            echo "PASS deploy: preview dev fixtures seeded"
        fi
    fi
else
    echo "WARN deploy: could not find running machine to run migrations/seeds"
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

        # ORG is hardcoded in fly.log-shipper.toml [env], so we only stage
        # the secret env vars. AXIOM_TOKEN / AXIOM_DATASET are empty-safe
        # via the `${VAR:-}` expansion — a missing Axiom credential is
        # surfaced as a Vector startup error rather than a script-level
        # unbound-variable crash.
        fly secrets set \
            LOG_SHIPPER_ACCESS_TOKEN="${LOG_SHIPPER_ACCESS_TOKEN}" \
            AXIOM_TOKEN="${AXIOM_TOKEN:-}" \
            AXIOM_DATASET="${AXIOM_DATASET:-}" \
            --app "${LOG_SHIPPER_APP}" --stage

        # CD into the Dockerfile's directory for the same reason as the
        # SearXNG deploy above — CWD wins over --config's directory for
        # Fly's build context.
        _log_shipper_deploy_once() {
            (cd "$REPO_ROOT/deploy/log-shipper" && fly deploy \
                --app "${LOG_SHIPPER_APP}" \
                --config "${REPO_ROOT}/deploy/fly.log-shipper.toml" \
                --yes)
        }

        if deploy_with_retry "log-shipper" _log_shipper_deploy_once; then
            # Same reasoning as SearXNG's 300s timeout above — cold image
            # build + VM boot + Vector's config parse + NATS source
            # connection + API server start. Vector is lighter than
            # SearXNG but still far from instant on a cold deploy.
            echo "==> Verifying log shipper health via fly status (up to 300s)..."
            # Vector's built-in /health on :8686 is what fly.log-shipper.toml's
            # [[checks]] block hits. Same rationale as SearXNG: parse Fly's
            # own report rather than running curl inside the container. A
            # previous iteration tried `fly ssh console -C curl localhost:8686`
            # and silently broke on base images that ship without curl.
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

# ── Vision pipeline warmup ────────────────────────────────────────────────────
if [[ -n "${SKIP_VISION:-}" ]]; then
    echo "SKIP warmup: SKIP_VISION set — vision not deployed, skipping warmup"
else
# Queue 6 warmup uploads so Modal starts scaling out before the SLO gate
# starts probing. The gate fires 6 parallel canaries every 15s; queueing 6
# Oban vision jobs upfront causes Modal to spawn 6 containers in parallel
# with the gate's own cold-start demand.
#
# We do NOT stream the SSE `/api/upload/:id/stream` route during warmup.
# That route shares route_group=:upload with the gate's probes, and its
# duration is cumulative in the `upload_p95_ms` histogram for the
# lifetime of the BEAM. An earlier version waited for SSE to resolve —
# cold-start delays produced 8-minute SSE samples that dominated the
# gate's p95 (which is sample #147 of ~154: 5 long samples = blown).
#
# Fire-and-forget via POST is enough. The Oban vision queue picks up the
# 6 jobs and exercises Modal; container warming happens in parallel with
# check-slo-gate.sh starting up. `scaledown_window=1200` on the @app.cls
# decorator keeps warmed containers alive through the full 10-min gate.
#
# Credentials: PROBE_SEED_EMAIL / PROBE_SEED_PASSWORD — set at job-level
# in the production workflow from PROD_OWNER_* secrets. Dev defaults
# (owner@thestacks.app / dev-password-123) match the seeded preview user.
#
# Failure handling: upload acceptance (HTTP 202) is the success signal;
# anything else is a WARN. Only auth failure is fatal.

WARMUP_EMAIL="${PROBE_SEED_EMAIL:-owner@thestacks.app}"
WARMUP_PASSWORD="${PROBE_SEED_PASSWORD:-dev-password-123}"

# Canaries match scripts/probe-production.sh's burst set — firing the same
# six images Modal will see during the gate maximises the proportion of
# warm-path requests once the gate starts.
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

# Wait for external edge routing. deploy-stack.sh already verified health
# via fly-proxy (localhost path), but Fly's anycast edge can lag by a minute
# after deploy while learning about the new machines. Poll up to ~2 min.
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

# Build the login JSON via python's json.dumps rather than shell interpolation
# so credentials with quotes/backslashes round-trip safely. Pass the secrets
# as argv — env-var indirection doesn't survive `<(process substitution)`
# reliably, which caused a KeyError: 'WARMUP_EMAIL' at first cut.
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

# Fire all canaries in parallel so Modal sees the same scale-out demand
# shape the gate will generate. Collect image_ids from the 202 responses.
echo "    Uploading ${#warmup_canaries[@]} canaries in parallel (init → PUT → commit)..."
warmup_dir="$(mktemp -d)"
upload_pids=()
for img in "${warmup_canaries[@]}"; do
    (
        img_name="$(basename "$img")"

        # Step 1: init — get image_id + upload_url
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

        # Resolve relative upload_url against CORE_URL
        if [[ "${upload_url}" == /* ]]; then
            upload_url="${CORE_URL}${upload_url}"
        fi

        # Step 2: PUT file bytes to upload_url
        put_code="$(curl -4 -s -o /dev/null -w "%{http_code}" \
            --max-time 30 \
            -X PUT "${upload_url}" \
            -H "Content-Type: image/jpeg" \
            --data-binary "@${img}" 2>/dev/null || true)"

        if [[ "${put_code}" != "200" ]]; then
            echo "    ${img_name}: PUT to upload_url returned ${put_code} — skipping"
            exit 0
        fi

        # Step 3: commit — enqueue vision job
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

# ── Vision pipeline completion probe ─────────────────────────────────────────
# The warmup above only proves /api/upload accepts uploads — not that vision
# actually processes them. Async-pipeline failures (Modal cold-start hang,
# HMAC mismatch, vision sidecar crash) historically only surfaced at E2E
# time, with confusing 4-5min timeouts on `upload-verify`. This probe
# consumes the SSE stream of one canary and waits for the Oban vision job
# to reach a terminal state (`resolved` or `rejected`). If vision doesn't
# complete in 180s, the deploy fails fast with a clear pointer at vision
# health rather than letting downstream tests timeout mysteriously.
#
# Note: this runs AFTER the parallel warmup so Modal is already scaling up.
# 180s is generous enough for cold-start (1-3 min observed) but short
# enough that a genuinely-broken pipeline surfaces here, not in E2E.
if [[ -n "${SKIP_VISION:-}" ]]; then
    echo "SKIP probe: SKIP_VISION set — skipping vision completion probe"
elif [[ ${#warmup_ids[@]} -gt 0 ]]; then
    probe_id="${warmup_ids[0]}"
    echo ""
    echo "==> Vision pipeline completion probe (image_id=${probe_id})..."
    echo "    Waiting up to 180s for terminal status (resolved|rejected)..."

    probe_log="$(mktemp)"
    # SSE: --no-buffer streams events as they arrive; --max-time bounds
    # total wait. The endpoint emits status lines like
    # `data: {"status":"processing", ...}` and we grep for the terminal
    # states. Background curl + monitor stdout in a tee so we can kill it
    # as soon as a terminal status appears.
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
        # Timeout guard — bash arithmetic seconds since start
        if (( $(date +%s) - probe_started >= 180 )); then
            break
        fi
        # Curl exited (connection closed or completed) without a terminal
        # status — break out so we can inspect the log.
        if ! kill -0 "${probe_pid}" 2>/dev/null; then
            break
        fi
        sleep 2
    done

    # Clean up the background curl regardless of outcome.
    kill "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" 2>/dev/null || true

    if [[ "${probe_terminal}" == "resolved" ]]; then
        echo "PASS probe: vision pipeline reached 'resolved' for ${probe_id}"
    elif [[ "${probe_terminal}" == "rejected" ]]; then
        # 'rejected' is a valid vision outcome (image classified as not_a_book
        # etc.) — the pipeline worked end-to-end. The first canary in the
        # warmup set is barcode_isbn_clean.jpg which should resolve, so a
        # rejected here is unusual but not a deploy-blocking failure.
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

# Brief pause so the Oban vision queue can pick up the remaining jobs before
# the gate starts probing. The probe above already let one job complete; the
# others are mid-processing and will finish in parallel with the gate.
sleep 15

# ── Output ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS deploy: stack is live at ${CORE_URL}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP}"
echo "    Neon branch: ${NEON_BRANCH_NAME}"
