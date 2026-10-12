#!/usr/bin/env bash

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

if [[ -n "${PRE_MIGRATE_LSN:-}" ]]; then
    _MISSING_NEON_VARS=()
    [[ -z "${NEON_PROJECT_ID:-}" ]] && _MISSING_NEON_VARS+=("NEON_PROJECT_ID")
    [[ -z "${NEON_API_KEY:-}" ]] && _MISSING_NEON_VARS+=("NEON_API_KEY")
    [[ -z "${NEON_BRANCH_ID:-}" ]] && _MISSING_NEON_VARS+=("NEON_BRANCH_ID")
    if [[ ${#_MISSING_NEON_VARS[@]} -gt 0 ]]; then
        echo "FAIL rollback: PRE_MIGRATE_LSN is set but the following Neon vars are missing: ${_MISSING_NEON_VARS[*]}" >&2
        exit 1
    fi
fi

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
    # The rollback deploys an OLD image, so it must not run the CURRENT
    # config's release_command — the old image may predate whatever that
    # command calls (a rollback once aborted on UndefinedFunctionError
    # because the previous image had no Stacks.Release.deploy/0). The DB is
    # already migrated ahead of the old code (expand-contract), so skipping
    # the release step is both safe and the point.
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    ROLLBACK_CONFIG="$(mktemp -d)/fly.rollback.toml"
    grep -v '^[[:space:]]*release_command' "$REPO_ROOT/deploy/fly.core.toml" > "$ROLLBACK_CONFIG"
    echo "    (release_command stripped for rollback: $ROLLBACK_CONFIG)"
    if ! fly deploy --app "$CORE_APP" --config "$ROLLBACK_CONFIG" --image "$CORE_PREV_IMAGE" --depot=false; then
        echo "FAIL rollback: fly deploy (core) failed — NOT attempting modal rollback" >&2
        exit 1
    fi
    echo "PASS rollback: core rolled back"
fi

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

if [[ -z "${PRE_MIGRATE_LSN:-}" ]]; then
    echo "WARN rollback: PRE_MIGRATE_LSN unset — skipping Neon DB rollback (image-only)" >&2
else
    # GITHUB_SHA is only set when a workflow runs this; an operator following
    # the runbook by hand has no such variable, and `${GITHUB_SHA:0:7}` under
    # `set -u` aborts on the unset name (bash 4.4+; bash 3.2 silently yields an
    # empty segment instead). Either way it lands here — after the core image
    # has already been rolled back and before the DB is restored — leaving
    # production on old code against new schema. Default the name instead.
    _SHA_TAG="${GITHUB_SHA:-manual}"
    PRESERVE_NAME="pre-rollback-${_SHA_TAG:0:7}-$(date -u +%Y%m%dT%H%M%SZ)"
    echo ""

    # The restore mints a pre-rollback-* backup branch, and Neon's project
    # branch quota is small — a restore once failed BRANCHES_LIMIT_EXCEEDED
    # against nine accumulated backups. Reap down to the newest two first
    # (this restore's backup makes three). Ordering comes from the UTC
    # timestamp in the NAME: restore-preserved branches inherit the parent's
    # created_at, so the API field lies about their age. Best-effort — a
    # failed reap still attempts the restore, which fails loudly on its own.
    _KEEP_BACKUPS=2
    _BRANCH_LIST=$(curl -sL \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches?limit=200" 2>/dev/null || echo '{}')
    _STALE_IDS=$(jq -r '
        [.branches[]? | select(.name | startswith("pre-rollback-"))
         | {id, ts: (.name | split("-") | last)}]
        | sort_by(.ts) | .[0:(length - '"$_KEEP_BACKUPS"')] | .[]?.id
    ' <<<"$_BRANCH_LIST" 2>/dev/null || true)
    for _stale in $_STALE_IDS; do
        echo "==> Reaping stale pre-rollback backup branch ${_stale}..."
        curl -sL -o /dev/null -X DELETE \
            -H "Authorization: Bearer ${NEON_API_KEY}" \
            "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${_stale}" \
            || echo "WARN rollback: could not delete ${_stale} (continuing)" >&2
    done

    echo "==> Restoring Neon prod branch to LSN ${PRE_MIGRATE_LSN} (backup: ${PRESERVE_NAME})..."
    _NEON_BODY=$(jq -nc \
        --arg src "$NEON_BRANCH_ID" \
        --arg lsn "$PRE_MIGRATE_LSN" \
        --arg name "$PRESERVE_NAME" \
        '{source_branch_id: $src, source_lsn: $lsn, preserve_under_name: $name}')
    HTTP=$(curl -sL -o /tmp/neon-restore.json -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${NEON_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$_NEON_BODY" \
        "https://console.neon.tech/api/v2/projects/${NEON_PROJECT_ID}/branches/${NEON_BRANCH_ID}/restore") || {
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
    modal deploy "apps/vision/modal_app.py" --commit "$MODAL_PREV_COMMIT" \
        || {
            echo "FAIL rollback: modal deploy stub reported failure" >&2
            exit 1
        }
fi

echo "PASS rollback: vision rolled back to ${MODAL_PREV_COMMIT}"
exit 0
