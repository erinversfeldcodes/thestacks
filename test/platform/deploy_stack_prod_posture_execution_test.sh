#!/usr/bin/env bash
# test/platform/deploy_stack_prod_posture_execution_test.sh
#
# EXECUTES the production posture branch of deploy-stack.sh, rather than reading
# it.
#
# ⚠️ Why a second posture suite, when `deploy_stack_posture_test.sh` exists.
# That suite asserts that each posture flag HAS AN ASSIGNMENT on the production
# branch, textually. Its stated concern is that a flag's value must come from
# the script and "not inherited from whatever shell happens to run it" — and a
# presence check cannot establish that. These all satisfy "is assigned" while
# leaving the environment in charge:
#
#     AGE_GATING_ENABLED="${AGE_GATING_ENABLED}"
#     AGE_GATING_ENABLED="${AGE_GATING_ENABLED:-}"
#     AGE_GATING_ENABLED=""        # …then reassigned 40 lines later
#
# The only way to know what production actually gets is to run the branch and
# look at the variables afterwards. So this suite pre-sets every posture flag to
# the WRONG value — the state a stale `.env` export or a developer's shell would
# leave — executes the branch, and asserts the script overrode each one.
#
# That failure mode is documented, not imagined: `INVITE_ONLY_REGISTRATION` was
# once pinned on the preview branch only, so its production value was a function
# of deploy history. A clean shell could have launched with registration OPEN,
# and a stale export could have promoted the closed beta onto production.
#
# ⚠️ WHAT THIS DOES AND DOES NOT PROVE. It proves the production-only decision
# logic is REACHABLE and produces the right values under a hostile environment.
# It does NOT prove the Fly or Neon calls downstream behave — nothing here
# contacts either. The honest description is "the branch is rehearsed", not "the
# production deploy is rehearsed". The remaining gap needs a throwaway app, and
# is recorded in the issue rather than implied away here.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"
# shellcheck source=lib/posture-flags.sh
source "$HERE/lib/posture-flags.sh"

SCRIPT="$REPO_ROOT/scripts/deploy-stack.sh"

test_case "script_exists" "deploy-stack.sh is where this suite expects it"
assert_path_exists "$SCRIPT" "scripts/deploy-stack.sh exists"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BRANCH_FILE="$WORK/prod-branch.sh"

# The production branch alone: from its `if` to the matching `else`. Same
# anchors the sibling suite uses, so a rename breaks both rather than silently
# passing one.
awk '
    /^if \[\[ "\$PROD_MODE" -eq 1 \]\]; then$/ { in_branch = 1; next }
    in_branch && /^else$/ { exit }
    in_branch { print }
' "$SCRIPT" > "$BRANCH_FILE"

# ── the extraction must be loud when it fails ────────────────────────────────
#
# ⚠️ This is the load-bearing guard of the whole file. Every assertion below
# runs the extracted block; if extraction silently produced nothing, the block
# would be a no-op, the variables would keep their pre-set hostile values, and
# the assertions would FAIL — which is the right direction. But a block that
# extracted PARTIALLY (say, the first two lines) would set some flags and not
# others, and the resulting failure would read like a defect in the script. So
# the extraction is checked on its own terms first.
test_case "extraction_is_complete" "the branch was extracted whole, not partially"
LINES="$(grep -c . "$BRANCH_FILE" || true)"
if [[ "${LINES:-0}" -lt 10 ]]; then
    _record_fail "extracted only ${LINES} line(s) of the production branch — the anchors no longer match the script's shape, so every assertion below would be testing an empty block"
else
    _record_pass "extracted ${LINES} lines of the production branch"
fi

assert_contains "$(cat "$BRANCH_FILE")" "PRODUCTION mode" \
    "the extracted block is the one that announces itself as production"

# ── the roster and this suite must agree ────────────────────────────────────

test_case "the_hostile_map_covers_the_roster" "every rostered flag has a hostile and a production value"
# ⚠️ A pairing, not a convenience. The roster lives in `lib/posture-flags.sh`
# and is shared with `deploy_stack_posture_test.sh`; without this assertion a
# flag could be added to the roster — gaining a "is it pinned?" check there —
# while this suite silently never exercises it, which is the shape that left
# `STACKS_E2E_TEST_HELPERS` unchecked for as long as it was.
MISSING=""
for flag in "${POSTURE_FLAGS[@]}"; do
    has_hostile=0
    has_prod=0
    for pair in "${POSTURE_HOSTILE_VALUES[@]}"; do
        [[ "${pair%%=*}" == "$flag" ]] && has_hostile=1 && break
    done
    for pair in "${POSTURE_PRODUCTION_VALUES[@]}"; do
        [[ "${pair%%=*}" == "$flag" ]] && has_prod=1 && break
    done
    [[ "$has_hostile" -eq 1 && "$has_prod" -eq 1 ]] || MISSING="${MISSING}${flag} "
done
if [[ -n "$MISSING" ]]; then
    _record_fail "these rostered flags have no hostile and/or production value, so this suite does not exercise them: ${MISSING}"
else
    _record_pass "all ${#POSTURE_FLAGS[@]} rostered flags have both values"
fi

# ── run it under a hostile environment ──────────────────────────────────────
#
# Every posture flag pre-set to the value production must NOT have, taken from
# the shared roster. If the script's assignment is missing, conditional, or
# self-referential, the hostile value survives and the assertion fails naming
# it.
run_prod_branch() {
    local -a env_args=(PATH="$PATH" HOME="$HOME")
    local pair
    for pair in "${POSTURE_HOSTILE_VALUES[@]}"; do
        env_args+=("$pair")
    done
    # Two non-posture values with their own reasons for being here:
    # a staging credential that must not survive into a production deploy, and
    # an EMPTY (not unset) host, because `${VAR:-default}` substitutes for an
    # empty value while `${VAR-default}` does not — a one-character difference
    # between deploying to the real domain and deploying to no host at all.
    env_args+=(NEON_STAGING_API_KEY="leaked-staging-key" PROD_PHX_HOST="")

    env -i "${env_args[@]}" \
        bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            shift
            # Printed as NAME=value lines so an empty value is distinguishable
            # from an absent variable — the distinction the whole suite turns on.
            for v in "$@" NEON_STAGING_API_KEY PHX_HOST_VALUE CORE_APP MODAL_APP; do
                printf "%s=%s\n" "$v" "${!v-<<UNSET>>}"
            done
        ' _ "$BRANCH_FILE" "${POSTURE_FLAGS[@]}"
}

OUT="$(run_prod_branch 2>&1)"

test_case "the_branch_actually_ran" "the block executed and reported its variables"
# Anti-vacuity before any value is judged: an empty or errored run would make
# every "is empty" assertion below pass for the wrong reason, because a missing
# line contains no forbidden value either.
assert_contains "$OUT" "CORE_APP=thestacks-core" \
    "the branch ran and applied its own production default for CORE_APP"
assert_contains "$OUT" "MODAL_APP=thestacks-vision" \
    "…and for MODAL_APP"

# ── every rostered flag comes out as the SCRIPT's value, not the shell's ────
#
# One loop over the roster rather than a case per flag, so adding a flag to
# `lib/posture-flags.sh` extends the coverage automatically. The failure message
# stays specific per flag, because "a posture flag leaked" is not actionable and
# "the endpoints that mint sessions without authentication are enabled on
# production" is.
posture_why() {
    case "$1" in
        AGE_GATING_ENABLED)
            printf '%s' "age-gating ships DARK — the enforcement machinery is built and tested but inert until a real verification provider is integrated, so promoting it onto production enforces a gate with no way through it"
            ;;
        STACKS_E2E_TEST_HELPERS)
            printf '%s' "these endpoints mint confirmed sessions and flip age-verification with no authentication; on production that is an unauthenticated account-takeover surface"
            ;;
        INVITE_ONLY_REGISTRATION)
            printf '%s' "scripts/probe-production.sh fails the deploy if a codeless registration is accepted, so a deploy from the wrong shell would ship and then fail at the far end"
            ;;
        RATE_LIMIT_*)
            printf '%s' "a test-tuned rate limit on production removes the metering that protects the public endpoints"
            ;;
        SMOKE_TESTS_ENABLED)
            printf '%s' "the smoke-test affordances are preview scaffolding and have no business being reachable on production"
            ;;
        *)
            printf '%s' "its production value would be a function of whoever ran the deploy rather than of this script"
            ;;
    esac
}

expected_production_value() {
    local flag="$1" pair
    for pair in "${POSTURE_PRODUCTION_VALUES[@]}"; do
        if [[ "${pair%%=*}" == "$flag" ]]; then
            printf '%s' "${pair#*=}"
            return 0
        fi
    done
    return 1
}

test_case "every_rostered_flag_takes_the_scripts_value" \
    "a hostile environment cannot decide any posture flag's production value"
for flag in "${POSTURE_FLAGS[@]}"; do
    want="$(expected_production_value "$flag")"
    # The reported line for this flag, matched whole so an empty value is
    # distinguishable from a prefix of a longer one.
    actual=""
    while IFS= read -r line; do
        [[ "${line%%=*}" == "$flag" ]] && actual="${line#*=}" && break
    done <<<"$OUT"

    if [[ "$actual" == "<<UNSET>>" ]]; then
        _record_fail "$flag is UNSET after the production branch ran, so it is pinned on neither path. The staging line's \${VAR:+...} expansion omits an unset variable entirely — fly is told nothing and the app keeps whatever was last staged. ($(posture_why "$flag"))"
    elif [[ "$actual" == "$want" ]]; then
        if [[ -z "$want" ]]; then
            _record_pass "$flag was blanked by the script, overriding the hostile environment value"
        else
            _record_pass "$flag came out as '$want', overriding the hostile environment value"
        fi
    else
        _record_fail "$flag came out as '$actual' but production requires '$want' — the value this suite pre-set in the environment survived the production branch. ($(posture_why "$flag"))"
    fi
done

test_case "staging_credentials_do_not_reach_production" "a staging Neon key cannot be carried in"
if [[ "$OUT" == *"NEON_STAGING_API_KEY=leaked-staging-key"* ]]; then
    _record_fail "NEON_STAGING_API_KEY survived into the production branch. A production deploy must not hold a staging credential, and the branch blanks it precisely so a developer's .env cannot hand one over."
else
    _record_pass "NEON_STAGING_API_KEY was blanked by the script"
fi

test_case "the_host_is_the_production_domain" "PHX_HOST falls back to the real domain, not to empty"
# The hostile environment sets PROD_PHX_HOST="" — empty, not unset. `${VAR:-d}`
# substitutes the default for an empty value too, which is the behaviour relied
# on here; `${VAR-d}` would not, and the difference is one character.
assert_contains "$OUT" "PHX_HOST_VALUE=readinginthestacks.com" \
    "an empty PROD_PHX_HOST falls back to the production domain rather than deploying with no host"

summarise
