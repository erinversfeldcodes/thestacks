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
# shellcheck source=lib/posture-flags.sh
source "$HERE/lib/posture-flags.sh"

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

# Every variable either branch assigns a LITERAL to, as a set of names.
#
# ⚠️ This is the ROSTER-STALENESS instrument, not the assertion. The assertions
# below run over the explicit roster in `lib/posture-flags.sh`, because deriving
# the list cannot see a flag pinned on NEITHER branch — the exact risk this
# suite's header describes, which made the old derivation blind to its own
# subject. But an allowlist cannot notice a flag somebody ADDS, so the two work
# together: the roster makes the assertions precise, this keeps the roster
# honest.
#
# Three things that were wrong with the version this replaces:
#
#   * `[A-Z_]+` excluded DIGITS, so `STACKS_E2E_TEST_HELPERS` and
#     `RATE_LIMIT_E2E_HELPER` were invisible — the two most security-relevant
#     flags in the set. `[A-Z0-9_]+` now.
#   * it read the PREVIEW branch only, so a prod-only-pinned flag never
#     appeared. It unions both branches now.
#   * `="[^$]` matched `VAR=""`, so a secret BLANKED on the production branch
#     (`NEON_STAGING_API_KEY=""`) was harvested as a posture flag. Empty
#     assignments are excluded here: a blanked secret is not a posture switch,
#     and the real posture flags are still found by their non-empty preview
#     value.
literal_assignments() {
    { prod_branch; preview_branch; } |
        grep -E '^[[:space:]]+[A-Z0-9_]+="[^"$]' |
        sed -E 's/^[[:space:]]*([A-Z0-9_]+)=.*/\1/' |
        sort -u
}

PROD_TXT="$(prod_branch)"
PREVIEW_TXT="$(preview_branch)"

test_case "prod_branch_readable" "the production branch can be located in the script"
if [[ -z "$PROD_TXT" ]]; then
    _record_fail "could not locate the PROD_MODE branch — it was renamed, or its shape changed"
else
    assert_contains "$PROD_TXT" "PRODUCTION mode" "the branch is the one that announces itself as production"
fi

test_case "preview_branch_readable" "the preview branch can be located too"
# ⚠️ `preview_branch/0` was defined and never called — dead code in a suite
# whose whole subject is the difference between two branches. Both are read now,
# and both are asserted below, which is what makes "pinned on NEITHER branch"
# detectable at all.
if [[ -z "$PREVIEW_TXT" ]]; then
    _record_fail "could not locate the preview branch — it was renamed, or its shape changed"
else
    _record_pass "read $(printf '%s\n' "$PREVIEW_TXT" | grep -c . | tr -d ' ') lines of the preview branch"
fi

# ⚠️ The population's SIZE, declared in SOURCE rather than only printed on
# failure — and the difference is the whole point.
#
# A population printed on failure is visible to whoever runs the test. A
# population declared here is visible in the DIFF, so the next person reading a
# change reviews it instead of re-deriving the set by eye. That converts "the
# set was taken from reading" into a reviewable artefact.
#
# This is not hypothetical for THIS suite. Its derivation matched
# `[A-Z_]+`, which excludes digits, so two flags were silently absent from the
# population for as long as the suite existed. A declared count would have
# turned that into a red run the day the regex was written: 7 expected, 5 found.
EXPECTED_LITERAL_ASSIGNMENTS=7

test_case "the_derived_population_is_the_declared_size" \
    "the derivation finds as many literal assignments as this suite says it should"
DERIVED="$(literal_assignments)"
DERIVED_COUNT="$(printf '%s\n' "$DERIVED" | grep -c . | tr -d ' ')"
if [[ "$DERIVED_COUNT" -eq "$EXPECTED_LITERAL_ASSIGNMENTS" ]]; then
    _record_pass "derived $DERIVED_COUNT literal assignment(s), matching the declared count"
else
    _record_fail "derived $DERIVED_COUNT literal assignment(s) across both branches, but this suite declares $EXPECTED_LITERAL_ASSIGNMENTS. Either deploy-stack.sh gained or lost a posture flag — update EXPECTED_LITERAL_ASSIGNMENTS and the roster in the same change, so the new population is reviewable in the diff — or the derivation's regex has drifted and is now reading less than it claims. Found: $(printf '%s' "$DERIVED" | tr '\n' ' ')"
fi

test_case "the_roster_is_not_stale" "no literal-assigned flag is missing from the roster"
# The half an allowlist cannot do for itself. A new posture flag added to
# either branch shows up here rather than being quietly unchecked.
if [[ -z "$DERIVED" ]]; then
    _record_fail "derived no literal assignments from either branch — the regex no longer matches the script's shape, so this staleness check is inert"
else
    _record_pass "derived $DERIVED_COUNT literal assignment(s) across both branches"
    UNROSTERED=""
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Identity and host derivations are not posture. Documented in the
        # roster file rather than restated here.
        case "$name" in
            CORE_APP|MODAL_APP|PHX_HOST_VALUE|SCRAPER_APP) continue ;;
        esac
        found=0
        for flag in "${POSTURE_FLAGS[@]}"; do
            [[ "$flag" == "$name" ]] && found=1 && break
        done
        [[ "$found" -eq 0 ]] && UNROSTERED="${UNROSTERED}${name} "
    done <<<"$DERIVED"

    if [[ -n "$UNROSTERED" ]]; then
        _record_fail "these variables are assigned a literal by deploy-stack.sh but are absent from POSTURE_FLAGS in test/platform/lib/posture-flags.sh, so nothing asserts their production value: ${UNROSTERED}— add each to the roster (with a hostile and a production value) or add it to the non-posture exclusions above with a reason. Full derived population: $(printf '%s' "$DERIVED" | tr '\n' ' ')"
    else
        _record_pass "every literal-assigned variable is either rostered or excluded with a reason"
    fi
fi

test_case "the_roster_has_no_entry_the_script_stopped_assigning" \
    "a rostered flag the script no longer pins is reported, not silently asserted"
# The OTHER direction, and an allowlist needs it: an entry naming a flag
# deploy-stack.sh has stopped assigning would keep being asserted against both
# branches and keep failing for a reason nobody can act on — or, if the flag
# were removed from the script entirely, keep claiming coverage of nothing.
if [[ -z "$DERIVED" ]]; then
    _record_fail "cannot check: no population was derived"
else
    ORPHANED=""
    for flag in "${POSTURE_FLAGS[@]}"; do
        printf '%s\n' "$DERIVED" | grep -qxF "$flag" || ORPHANED="${ORPHANED}${flag} "
    done
    if [[ -n "$ORPHANED" ]]; then
        _record_fail "these roster entries name flags deploy-stack.sh no longer assigns a literal on either branch, so the roster claims coverage it does not have: ${ORPHANED}— remove them, or restore the assignment they describe"
    else
        _record_pass "every roster entry is still assigned a literal by the script"
    fi
fi

test_case "every_rostered_flag_is_pinned_on_BOTH_branches" \
    "no posture flag's value is left to the ambient environment, in either mode"
# ⚠️ BOTH branches, which is the fix. Checking only production leaves
# "pinned on neither" indistinguishable from "correctly absent", and a flag
# pinned on neither is the failure mode the header describes: the staging line's
# `${VAR:+...}` omits an unset variable ENTIRELY, so fly is told nothing and the
# app keeps whatever was last staged — in BOTH modes.
if [[ -z "$PROD_TXT" || -z "$PREVIEW_TXT" ]]; then
    _record_fail "cannot check: one of the two branches could not be read"
else
    for flag in "${POSTURE_FLAGS[@]}"; do
        for mode in production preview; do
            if [[ "$mode" == production ]]; then TXT="$PROD_TXT"; else TXT="$PREVIEW_TXT"; fi
            if printf '%s' "$TXT" | grep -qE "^[[:space:]]*${flag}="; then
                _record_pass "$flag is pinned on the $mode branch"
            else
                _record_fail "$flag is not pinned on the $mode branch, so its value there is whatever the ambient shell happens to hold. The staging line's \${VAR:+...} expansion omits an unset variable entirely: fly is told nothing and the app keeps whatever was last staged, making the flag a function of deploy history rather than of this script"
            fi
        done
    done
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
