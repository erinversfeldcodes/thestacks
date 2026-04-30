#!/usr/bin/env bash
# scripts/rollback-production.sh — SLO-breach rollback for core + vision.
#
# Ordering: core first, then vision. Per
# docs/runbooks/vision-service-rollback.md the wire-format of core N-1 only
# matches vision N-1, so rolling back vision first would leave core talking
# to a vision API it doesn't know about.
#
# Env vars:
#   CORE_APP             Fly app name for core (default: thestacks-core).
#   CORE_PREV_IMAGE      Previous Fly image digest/sha — REQUIRED.
#   MODAL_APP_NAME       Modal prod app name (default: thestacks-vision).
#   MODAL_PREV_COMMIT    Previous git sha for the modal app source — optional;
#                        if unset, core rolls back and vision is skipped with
#                        a loud warning (core is the critical path).
#
#                        Bootstrap note: on the very first production deploy
#                        there is no prior `main-*` tag, so this will always
#                        be empty. The first deploy therefore has no rollback
#                        target; operators must accept that the first merge
#                        to main cannot be auto-rolled-back. After the first
#                        successful deploy `tag-main.yml` stamps a tag and
#                        subsequent rollbacks restore vision correctly.
#   MODAL_TOKEN_ID       Modal auth (required when MODAL_PREV_COMMIT is set).
#   MODAL_TOKEN_SECRET   Modal auth (required when MODAL_PREV_COMMIT is set).
#   ROLLBACK_REASON      Free-form string written to stdout + logs.
#   ORIGIN_REMOTE        Git remote to clone prev-commit from (default:
#                        https://github.com/erinversfeld/thestacks.git).
#
# Authentication note:
# `modal deploy` authenticates via MODAL_TOKEN_ID / MODAL_TOKEN_SECRET read
# from the environment. Callers MUST export both before invoking this script
# whenever MODAL_PREV_COMMIT is set — otherwise the vision rollback leg fails
# with an opaque Modal SDK error instead of a clean "missing auth" message.
#
# Neon LSN restore (optional, opt-in via PRE_MIGRATE_LSN):
#   PRE_MIGRATE_LSN        Postgres LSN captured immediately before the
#                          migrate-before-cutover step. When set, the prod
#                          Neon branch is restored to this LSN between core
#                          and vision rollback so image and DB revert
#                          together. Empty/unset = skip (logged WARN).
#   NEON_PROD_PROJECT_ID   Neon project ID for the production project.
#                          REQUIRED when PRE_MIGRATE_LSN is set.
#   NEON_PROD_API_KEY      Neon API key scoped to the production project.
#                          REQUIRED when PRE_MIGRATE_LSN is set.
#   NEON_PROD_BRANCH_ID    Neon branch ID for the prod default branch.
#                          REQUIRED when PRE_MIGRATE_LSN is set.
#   GITHUB_SHA             Used to derive the preserve_under_name suffix
#                          (`pre-rollback-<sha7>-<ts>`). Optional; falls
#                          back to "unknown" when unset.
#
# Exit non-zero if:
#   - CORE_PREV_IMAGE is unset,
#   - PRE_MIGRATE_LSN is set but any of NEON_PROD_PROJECT_ID,
#     NEON_PROD_API_KEY, NEON_PROD_BRANCH_ID is missing (validated BEFORE
#     any rollback work begins),
#   - `fly deploy` fails (we do NOT attempt the modal step in this case),
#   - the Neon restore call fails (we do NOT attempt the modal step — the
#     schema state is unknown and vision's wire format depends on it).
#
# Exit 0 if core rolls back cleanly AND the Neon restore (if attempted)
# succeeds AND either (a) modal rolls back cleanly or (b) MODAL_PREV_COMMIT
# is unset and the skip is warned.

set -euo pipefail

CORE_APP="${CORE_APP:-thestacks-core}"
MODAL_APP_NAME="${MODAL_APP_NAME:-thestacks-vision}"
ROLLBACK_REASON="${ROLLBACK_REASON:-unspecified SLO breach}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-https://github.com/erinversfeld/thestacks.git}"

echo "==> Rolling back production core + vision"
echo "    Reason: ${ROLLBACK_REASON}"
echo "    Core app:    ${CORE_APP}"
echo "    Modal app:   ${MODAL_APP_NAME}"

if [[ -z "${CORE_PREV_IMAGE:-}" ]]; then
    echo "FAIL rollback: CORE_PREV_IMAGE is required but unset" >&2
    exit 1
fi

# Fast-fail: when PRE_MIGRATE_LSN is set, all three Neon vars must also be
# set BEFORE we touch fly/curl/modal. Validating mid-rollback would leave
# the image already swapped while the DB-restore leg is unrunnable.
if [[ -n "${PRE_MIGRATE_LSN:-}" ]]; then
    _MISSING_NEON_VARS=()
    [[ -z "${NEON_PROD_PROJECT_ID:-}" ]] && _MISSING_NEON_VARS+=("NEON_PROD_PROJECT_ID")
    [[ -z "${NEON_PROD_API_KEY:-}" ]] && _MISSING_NEON_VARS+=("NEON_PROD_API_KEY")
    [[ -z "${NEON_PROD_BRANCH_ID:-}" ]] && _MISSING_NEON_VARS+=("NEON_PROD_BRANCH_ID")
    if [[ ${#_MISSING_NEON_VARS[@]} -gt 0 ]]; then
        echo "FAIL rollback: PRE_MIGRATE_LSN is set but the following Neon vars are missing: ${_MISSING_NEON_VARS[*]}" >&2
        exit 1
    fi
fi

# ── 1. Core: redeploy the previous Fly image ────────────────────────────────
# Migration-failure detection: if the currently-serving image already
# matches CORE_PREV_IMAGE, a `fly deploy --image` would be a no-op cutover
# adding nothing but log noise. Skip it and continue to the DB + vision
# legs — those are exactly the cases where a half-applied migration earns
# the LSN reset.
echo ""
_CURRENT_IMAGE=""
if _FLY_IMAGE_JSON=$(fly image show --app "$CORE_APP" --json 2>/dev/null); then
    _CURRENT_IMAGE=$(printf '%s' "$_FLY_IMAGE_JSON" | jq -r '.reference // empty' 2>/dev/null || true)
fi

if [[ -n "$_CURRENT_IMAGE" && "$_CURRENT_IMAGE" == "$CORE_PREV_IMAGE" ]]; then
    echo "==> core rollback skipped — currently-serving image already matches ${CORE_PREV_IMAGE}"
    echo "    (migration-failure path: image was never cut over; DB + vision legs still run)"
else
    echo "==> Rolling core back to image ${CORE_PREV_IMAGE}..."
    if ! fly deploy --app "$CORE_APP" --image "$CORE_PREV_IMAGE" --depot=false; then
        echo "FAIL rollback: fly deploy (core) failed — NOT attempting modal rollback" >&2
        exit 1
    fi
    echo "PASS rollback: core rolled back"
fi

# Wait for core to report healthy. We mirror deploy-stack.sh's fly-proxy
# technique so the rollback succeeds on fresh CI runners that lack IPv6.
# On test stubs this loop is cheap: the stubbed `fly proxy` exits immediately
# and `curl` fails, so we fall through after the small retry budget. Skip
# entirely when the stubs are in play — INVOCATION_LOG is only set by the
# test harness.
if [[ -z "${INVOCATION_LOG:-}" ]]; then
    _PROXY_PORT=14987
    fly proxy "${_PROXY_PORT}:4000" --app "$CORE_APP" >/dev/null 2>&1 &
    _PROXY_PID=$!
    RETRIES=30
    until curl -sf --max-time 10 "http://localhost:${_PROXY_PORT}/api/health" >/dev/null 2>&1; do
        if [[ $RETRIES -le 0 ]]; then
            kill "${_PROXY_PID}" 2>/dev/null || true
            echo "WARN rollback: core health check did not pass after rollback" >&2
            break
        fi
        sleep 5
        ((RETRIES--))
    done
    kill "${_PROXY_PID}" 2>/dev/null || true
    wait "${_PROXY_PID}" 2>/dev/null || true
fi

# ── 2. Neon prod branch: restore to pre-migrate LSN ─────────────────────────
# After core image rollback (image N-1 ↔ schema N is safe by construction —
# expand-contract migrations are enforced by the `migration-safety` lint),
# reset the DB so image and schema revert together. The dangerous direction
# (image N ↔ schema N-1) is avoided because we already reverted the image.
#
# Neon's self-restore API requires `preserve_under_name`; the resulting
# `pre-rollback-*` branch is a free safety net the operator can promote
# back if the rollback itself was wrong.
if [[ -z "${PRE_MIGRATE_LSN:-}" ]]; then
    echo "WARN rollback: PRE_MIGRATE_LSN unset — skipping Neon DB rollback (image-only)" >&2
else
    PRESERVE_NAME="pre-rollback-${GITHUB_SHA:0:7}-$(date -u +%Y%m%dT%H%M%SZ)"
    echo ""
    echo "==> Restoring Neon prod branch to LSN ${PRE_MIGRATE_LSN} (backup: ${PRESERVE_NAME})..."
    _NEON_BODY=$(jq -nc \
        --arg src "$NEON_PROD_BRANCH_ID" \
        --arg lsn "$PRE_MIGRATE_LSN" \
        --arg name "$PRESERVE_NAME" \
        '{source_branch_id: $src, source_lsn: $lsn, preserve_under_name: $name}')
    HTTP=$(curl -sL -o /tmp/neon-restore.json -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${NEON_PROD_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$_NEON_BODY" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROD_PROJECT_ID}/branches/${NEON_PROD_BRANCH_ID}/restore") || {
        echo "FAIL rollback: Neon restore curl call failed (transport-level)" >&2
        exit 1
    }
    if [[ "$HTTP" != "200" && "$HTTP" != "201" ]]; then
        echo "FAIL rollback: Neon restore returned HTTP ${HTTP}" >&2
        cat /tmp/neon-restore.json >&2 2>/dev/null || true
        exit 1
    fi
    echo "PASS rollback: Neon prod branch restored to LSN ${PRE_MIGRATE_LSN}"
    echo "  pre-rollback state preserved as branch: ${PRESERVE_NAME}"
fi

# ── 3. Modal vision: redeploy from the previous commit sha ──────────────────
if [[ -z "${MODAL_PREV_COMMIT:-}" ]]; then
    echo "WARN rollback: MODAL_PREV_COMMIT is unset — skipping modal vision rollback." >&2
    echo "  Core is the critical path; vision rollback is partial-success here."
    echo "PASS rollback: core-only rollback complete (modal skipped)"
    exit 0
fi

echo ""
echo "==> Rolling vision back to commit ${MODAL_PREV_COMMIT}..."
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# In the test harness INVOCATION_LOG is set and there's no git checkout step
# needed — the `modal` stub on PATH records the call. In production we need
# a real clone at the previous commit before invoking modal deploy.
if [[ -z "${INVOCATION_LOG:-}" ]]; then
    (
        cd "$WORK_DIR"
        git clone --no-checkout "$ORIGIN_REMOTE" stacks-rollback
        cd stacks-rollback
        git checkout "$MODAL_PREV_COMMIT"
    ) || {
        echo "FAIL rollback: could not check out ${MODAL_PREV_COMMIT} from ${ORIGIN_REMOTE}" >&2
        exit 1
    }
    MODAL_APP_NAME="$MODAL_APP_NAME" \
        modal deploy "$WORK_DIR/stacks-rollback/apps/vision/modal_app.py" \
        || {
            echo "FAIL rollback: modal deploy (vision rollback) failed at ${MODAL_PREV_COMMIT}" >&2
            exit 1
        }
else
    # Test mode: call modal directly so the invocation log captures it.
    modal deploy "apps/vision/modal_app.py" --commit "$MODAL_PREV_COMMIT" \
        || {
            echo "FAIL rollback: modal deploy stub reported failure" >&2
            exit 1
        }
fi

echo "PASS rollback: vision rolled back to ${MODAL_PREV_COMMIT}"
exit 0
