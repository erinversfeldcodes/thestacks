#!/usr/bin/env bash
# What a preview deploy DECIDES that the E2E step has to be told.
#
# ⛔ THE CHANNEL THIS REPLACES EXISTED IN ONE ENVIRONMENT OUT OF TWO.
# The preview's `:auth` ceiling is raised above production parity so the
# suite's own opening burst of real logins cannot eat the budget, and
# rate-limit.spec.ts sizes its flood from that ceiling — it must overshoot the
# number the stack actually runs or it can never see a 429. The handoff was
# `echo "E2E_AUTH_RATE_LIMIT=…" >> "$GITHUB_ENV"`, and `$GITHUB_ENV` exists
# only inside a GitHub Actions job. `just ci` deploys the same stack and runs
# the same suite with no such variable, so the value never arrived: the spec
# fell back to its 60 default, flooded 70 attempts at a ceiling of 200, and
# failed saying "the per-IP :auth bucket is not limiting … treat it as
# brute-force protection being absent, not as a flaky test".
#
# ⚖️ A security-shaped verdict for a missing environment variable is worse than
# a silent skip, because it is believable. The comment beside the old handoff
# said the two values "cannot drift apart" — true in Actions, false in the gate
# this project actually runs.
#
# So the channel is a FILE that every caller can read, written unconditionally
# by the deploy and loaded by the E2E step. The GitHub mirror is kept beside
# it, written from the same argument in the same call, so the two cannot say
# different things.

_E2E_HANDOFF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

e2e_handoff_path() {
    printf '%s' "${E2E_HANDOFF_FILE:-${_E2E_HANDOFF_ROOT}/.e2e-handoff.env}"
}

# Start a fresh handoff. ⚠️ Called by the deploy before its first write, so a
# previous run's ceiling cannot be read as this one's — a stale value here
# would be the same defect wearing the opposite sign.
e2e_handoff_reset() {
    : > "$(e2e_handoff_path)"
}

# e2e_handoff_write NAME VALUE — to the file, and to GitHub's own channel when
# one exists, from the same argument.
e2e_handoff_write() {
    local name="$1" value="$2"
    printf '%s=%s\n' "$name" "$value" >> "$(e2e_handoff_path)"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$name" "$value" >> "${GITHUB_ENV}"
    fi
}

# Export everything the deploy handed over. Silent when there is nothing — the
# caller decides whether an absent handoff is a problem, because only the
# caller knows whether a preview was deployed at all.
e2e_handoff_load() {
    local path
    path="$(e2e_handoff_path)"
    [[ -f "$path" ]] || return 0
    set -a
    # shellcheck disable=SC1090  # a file this library wrote, path computed above
    source "$path"
    set +a
}
