#!/usr/bin/env bash
# Every posture flag's PRODUCTION value is declared by deploy-stack.sh itself,
# not inherited from whatever shell happens to run it.
#
# The flags are staged with `${VAR:+VAR="$VAR"}`, which omits the variable
# ENTIRELY when it is unset. So a flag the production branch does not pin is
# never mentioned to fly at all, and the prod app silently keeps whatever was
# last staged — the flag's state becomes a function of deploy history rather
# than of this script.
#
# `INVITE_ONLY_REGISTRATION` was pinned only on the preview branch while every
# sibling was pinned on both, so it had neither property the siblings have:
# "off in production" AND "declared by the script". Both directions were live.
# A production deploy from a clean shell could leave registration OPEN, and a
# stale `.env` export could promote the closed beta onto production — the exact
# risk the comment beside AGE_GATING_ENABLED cites as its own reason to exist.
#
# This suite exists so the fix cannot be quietly deleted: the thing that was
# missing was an assertion, not an understanding.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

SCRIPT="$REPO_ROOT/scripts/deploy-stack.sh"

test_case "script_exists" "deploy-stack.sh is where this suite expects it"
assert_path_exists "$SCRIPT" "scripts/deploy-stack.sh exists"

# The production branch: from `if [[ "$PROD_MODE" -eq 1 ]]; then` to its `else`.
# A flag, not an awk range, for the usual reason — the opening and closing
# patterns must not be able to match the same line.
prod_branch() {
    awk '
        /^if \[\[ "\$PROD_MODE" -eq 1 \]\]; then$/ { in_branch = 1; next }
        in_branch && /^else$/ { exit }
        in_branch { print }
    ' "$SCRIPT"
}

# The preview branch, from its `else` to the closing `fi`.
preview_branch() {
    awk '
        /^else$/ { in_branch = 1; next }
        in_branch && /^fi$/ { exit }
        in_branch { print }
    ' "$SCRIPT"
}

# POSTURE flags, derived rather than listed: a variable the script assigns a
# LITERAL value to on the preview branch. Those are the behaviour switches the
# script decides for itself, and the invariant is that whatever it decides for
# preview it must also decide for production.
#
# ⚠️ NOT "every variable the staging line passes through `${VAR:+...}`". That was
# the first version of this suite and it was wrong: most staged variables are
# secrets and credentials — API keys, passwords, database URLs — which are
# SUPPOSED to come from the environment and must never be pinned in a script.
# Asserting over all of them failed against a perfectly correct script and named
# eighteen non-defects, which is how a suite teaches people to delete it.
#
# `CORE_APP` and `MODAL_APP` are excluded: they are assigned from a derived
# preview name, not a posture literal, and the production branch assigns them
# too — just with `:-` defaults.
posture_flags() {
    awk '
        /^else$/ { in_branch = 1; next }
        in_branch && /^fi$/ { exit }
        in_branch && /^[[:space:]]+[A-Z_]+="[^$]/ { print }
    ' "$SCRIPT" |
        sed -E 's/^[[:space:]]*([A-Z_]+)=.*/\1/' |
        grep -vE '^(CORE_APP|MODAL_APP)$' |
        sort -u
}

PROD_TXT="$(prod_branch)"
FLAGS="$(posture_flags)"

test_case "prod_branch_readable" "the production branch can be located in the script"
if [[ -z "$PROD_TXT" ]]; then
    _record_fail "could not locate the PROD_MODE branch — it was renamed, or its shape changed"
else
    assert_contains "$PROD_TXT" "PRODUCTION mode" "the branch is the one that announces itself as production"
fi

test_case "posture_flags_found" "the posture flags can be read from the preview branch"
if [[ -z "$FLAGS" ]]; then
    _record_fail "found no posture flags on the preview branch — its shape changed, so this suite is checking nothing"
else
    _record_pass "read $(printf '%s\n' "$FLAGS" | grep -c . | tr -d ' ') posture flag(s) from the preview branch"
fi

test_case "every_posture_flag_is_pinned_for_production" \
    "no posture flag's production value is left to the ambient environment"
if [[ -z "$PROD_TXT" || -z "$FLAGS" ]]; then
    _record_fail "cannot check: the branch or the flag list could not be read"
else
    while IFS= read -r flag; do
        [[ -z "$flag" ]] && continue
        if printf '%s' "$PROD_TXT" | grep -qE "^[[:space:]]*${flag}=" ; then
            _record_pass "$flag is pinned on the production branch"
        else
            _record_fail "$flag is decided for PREVIEW but left to the environment for PRODUCTION. The staging line's \${VAR:+...} expansion omits an unset variable entirely, so fly is told nothing and the prod app keeps whatever was last staged — the flag's value becomes a function of deploy history rather than of this script"
        fi
    done <<<"$FLAGS"
fi

test_case "invite_gate_is_on_for_production" \
    "the launch posture is declared, not assumed — the production prober asserts this gate is enforcing"
if [[ -z "$PROD_TXT" ]]; then
    _record_fail "no production branch to check"
else
    assert_contains "$PROD_TXT" 'INVITE_ONLY_REGISTRATION="true"' \
        "production launches with invite-only registration ON; scripts/probe-production.sh fails the deploy if a codeless registration is accepted, and this is where that posture is set"
fi

summarise
exit $?
