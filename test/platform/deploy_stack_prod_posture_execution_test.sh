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

# ── run it under a hostile environment ──────────────────────────────────────
#
# Every posture flag pre-set to the value production must NOT have. If the
# script's assignment is missing, conditional, or self-referential, the value
# below survives and the assertion fails naming it.
run_prod_branch() {
    env -i \
        PATH="$PATH" \
        HOME="$HOME" \
        AGE_GATING_ENABLED="true" \
        STACKS_E2E_TEST_HELPERS="1" \
        INVITE_ONLY_REGISTRATION="false" \
        RATE_LIMIT_PUBLIC="9999" \
        RATE_LIMIT_E2E_HELPER="9999" \
        RATE_LIMIT_AUTH="9999" \
        SMOKE_TESTS_ENABLED="true" \
        NEON_STAGING_API_KEY="leaked-staging-key" \
        PROD_PHX_HOST="" \
        bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            # Printed as NAME=value lines so an empty value is distinguishable
            # from an absent variable — the distinction the whole suite turns on.
            for v in AGE_GATING_ENABLED STACKS_E2E_TEST_HELPERS INVITE_ONLY_REGISTRATION \
                     RATE_LIMIT_PUBLIC RATE_LIMIT_E2E_HELPER RATE_LIMIT_AUTH \
                     SMOKE_TESTS_ENABLED NEON_STAGING_API_KEY PHX_HOST_VALUE \
                     CORE_APP MODAL_APP; do
                printf "%s=%s\n" "$v" "${!v-<<UNSET>>}"
            done
        ' _ "$BRANCH_FILE"
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

# ── the dark flags must come out EMPTY, not inherited ───────────────────────

test_case "age_gating_is_dark_in_production" "a stale export cannot promote age-gating onto production"
assert_contains "$OUT" "AGE_GATING_ENABLED=" \
    "the variable is reported"
if [[ "$OUT" == *$'\nAGE_GATING_ENABLED=true'* || "$OUT" == AGE_GATING_ENABLED=true* ]]; then
    _record_fail "AGE_GATING_ENABLED came out as 'true' — the value this suite pre-set in the environment survived the production branch. Age-gating ships DARK: the enforcement machinery is built and inert until a real verification provider is integrated, so promoting it onto production enforces a gate with no way through it."
else
    _record_pass "AGE_GATING_ENABLED was overridden to empty by the script"
fi

test_case "e2e_helpers_never_reach_production" "the test-helper endpoints cannot be enabled on prod"
if [[ "$OUT" == *"STACKS_E2E_TEST_HELPERS=1"* ]]; then
    _record_fail "STACKS_E2E_TEST_HELPERS came out as '1' — the environment's value survived. These endpoints mint confirmed sessions and flip age-verification without authentication; on production that is an unauthenticated account-takeover surface."
else
    _record_pass "STACKS_E2E_TEST_HELPERS was overridden to empty by the script"
fi

test_case "staging_credentials_do_not_reach_production" "a staging Neon key cannot be carried in"
if [[ "$OUT" == *"NEON_STAGING_API_KEY=leaked-staging-key"* ]]; then
    _record_fail "NEON_STAGING_API_KEY survived into the production branch. A production deploy must not hold a staging credential, and the branch blanks it precisely so a developer's .env cannot hand one over."
else
    _record_pass "NEON_STAGING_API_KEY was blanked by the script"
fi

test_case "rate_limit_overrides_do_not_reach_production" "test-tuned rate limits cannot leak onto prod"
LEAKED_LIMITS=""
for v in RATE_LIMIT_PUBLIC RATE_LIMIT_E2E_HELPER RATE_LIMIT_AUTH SMOKE_TESTS_ENABLED; do
    if [[ "$OUT" == *"${v}=9999"* || "$OUT" == *"${v}=true"* ]]; then
        LEAKED_LIMITS="${LEAKED_LIMITS}${v} "
    fi
done
if [[ -n "$LEAKED_LIMITS" ]]; then
    _record_fail "these flags kept their environment values on the production branch, so their production state is a function of whoever ran the deploy: ${LEAKED_LIMITS}"
else
    _record_pass "all four loosening flags were blanked by the script"
fi

# ── the one flag that is pinned ON ─────────────────────────────────────────

test_case "the_launch_gate_is_pinned_ON_not_merely_pinned" \
    "invite-only registration is 'true' after the branch runs, whatever the shell said"
# The mirror of every assertion above, and the reason the suite cannot be
# written as "all posture flags end up empty": this one is deliberately ON, and
# the hostile environment sets it to "false" — the direction that would open
# registration during a closed beta.
if [[ "$OUT" == *"INVITE_ONLY_REGISTRATION=true"* ]]; then
    _record_pass "INVITE_ONLY_REGISTRATION=true survived a hostile 'false' in the environment"
else
    _record_fail "INVITE_ONLY_REGISTRATION did not come out as 'true' — this suite pre-set it to 'false', which is what a clean shell or a stale export looks like. scripts/probe-production.sh fails the deploy if a codeless registration is accepted, so a deploy from the wrong shell would fail at the far end having already shipped."
fi

test_case "the_host_is_the_production_domain" "PHX_HOST falls back to the real domain, not to empty"
# The hostile environment sets PROD_PHX_HOST="" — empty, not unset. `${VAR:-d}`
# substitutes the default for an empty value too, which is the behaviour relied
# on here; `${VAR-d}` would not, and the difference is one character.
assert_contains "$OUT" "PHX_HOST_VALUE=readinginthestacks.com" \
    "an empty PROD_PHX_HOST falls back to the production domain rather than deploying with no host"

summarise
