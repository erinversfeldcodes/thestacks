#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ⛔ REFUSE TO RUN ON A PYTHON THAT CANNOT DO THE CODEGEN, rather than failing
# eight minutes in with a TypeError.
#
# MEASURED 2026-10-27, and it is a documented rule of this project that was
# broken anyway: run bare, this script gets the SYSTEM python (3.9 on macOS),
# and `scripts/gen_python_proto.py` uses `zip(..., strict=True)`, which is 3.10+.
# The failure arrives as
#
#     TypeError: zip() takes no keyword arguments
#
# after the deploy has already provisioned secrets and started compiling — so
# the cost is a full round trip, and the message says nothing about the cause.
#
# ⚖️ The rule "run it through `just run`" was written down after the first time
# and did not fire the second time. A rule recalled as context is not a rule
# consulted at the point of action; this is the version a tool enforces.
#
# ⚠️ Gated on the CAPABILITY, not on the wrapper. Checking `STACKS_DEV_SHELL`
# would refuse a correctly-pinned environment reached some other way, and would
# pass a `just run` that had somehow picked up the wrong interpreter. The thing
# that matters is whether this python can run the generator.
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    _found="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "unknown")"
    echo "FAIL: proto codegen needs Python 3.10+, found ${_found} on PATH." >&2
    echo "      scripts/gen_python_proto.py uses zip(strict=True), which 3.9 refuses with" >&2
    echo "      'TypeError: zip() takes no keyword arguments' — eight minutes into the deploy." >&2
    echo "" >&2
    echo "      Run it through the pinned toolchain:" >&2
    echo "          just run bash scripts/deploy-preview.sh" >&2
    exit 1
fi

if [[ -f "$REPO_ROOT/.env" && -z "${CI:-}" ]]; then
    set -a; source "$REPO_ROOT/.env"; set +a
fi

export PATH="${HOME}/.local/bin:${PATH}"

BRANCH_ARG=""
REUSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) BRANCH_ARG="--branch $2"; shift 2 ;;
        --reuse)  REUSE=1; shift ;;
        *) shift ;;
    esac
done

BRANCH="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "preview")}"
# shellcheck source=scripts/lib/preview-names.sh
source "${REPO_ROOT}/scripts/lib/preview-names.sh"
derive_preview_names "$BRANCH"
CORE_APP="${PREVIEW_CORE_APP}"
CORE_URL="https://${CORE_APP}.fly.dev"

if [[ "$REUSE" -eq 1 ]]; then
    echo "==> --reuse: skipping teardown, redeploying onto the existing stack."
    echo "    (If this deploy behaves strangely, tear down and retry before debugging the app.)"
else
    echo "==> Tearing down any existing preview stack first (use --reuse to skip)..."
    bash "${REPO_ROOT}/scripts/cleanup-preview.sh" ${BRANCH_ARG} || {
        echo "FAIL deploy: teardown failed; not deploying onto an unknown stack state" >&2
        exit 1
    }
fi

bash "${REPO_ROOT}/scripts/deploy-stack.sh" ${BRANCH_ARG}
