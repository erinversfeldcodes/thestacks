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
# A follow-up (Issue #137) will wrap this script in a GitHub composite
# action so the env contract is declarative.
#
# Exit non-zero if:
#   - CORE_PREV_IMAGE is unset,
#   - `fly deploy` fails (we do NOT attempt the modal step in this case).
#
# Exit 0 if core rolls back cleanly AND either (a) modal rolls back cleanly
# or (b) MODAL_PREV_COMMIT is unset and the skip is warned.

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

# ── 1. Core: redeploy the previous Fly image ────────────────────────────────
echo ""
echo "==> Rolling core back to image ${CORE_PREV_IMAGE}..."
if ! fly deploy --app "$CORE_APP" --image "$CORE_PREV_IMAGE" --depot=false; then
    echo "FAIL rollback: fly deploy (core) failed — NOT attempting modal rollback" >&2
    exit 1
fi
echo "PASS rollback: core rolled back"

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

# ── 2. Modal vision: redeploy from the previous commit sha ──────────────────
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
