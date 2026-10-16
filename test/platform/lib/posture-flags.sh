#!/usr/bin/env bash
# The posture-flag roster, shared by every suite that reasons about what
# `scripts/deploy-stack.sh` decides for production.
#
# WHY AN EXPLICIT LIST, when the suite that needed it used to derive one.
# Deriving from the preview branch cannot see a flag pinned on NEITHER branch —
# which is precisely the risk the posture suite exists to cover, so the
# instrument was blind to its own subject. The alternative considered and
# REFUTED was "every variable the staging line passes through `${VAR:+...}`,
# minus a named secrets list": that needs an 18-name denylist of API keys,
# passwords, URLs and addresses, and all 18 are non-defects. A 7-name allowlist
# that never cries wolf beats an 18-name denylist that does.
#
# ⚠️ An allowlist cannot notice a NEW posture flag, so it does not stand alone:
# `deploy_stack_posture_test.sh` derives literal assignments from the union of
# both branches and fails when anything it finds is absent from this roster.
# The allowlist makes the assertions precise; the derivation keeps the allowlist
# honest. Neither is sufficient alone, which is why both are here.
#
# ⚠️ SEVEN, NOT FIVE — and the two that were missing are the two that matter
# most. The derivation this replaces matched `^[[:space:]]+[A-Z_]+="`, and
# `[A-Z_]+` excludes DIGITS, so every flag with a digit in its name was
# invisible to it. That silently dropped `STACKS_E2E_TEST_HELPERS` and
# `RATE_LIMIT_E2E_HELPER`. The first gates endpoints that mint confirmed
# sessions and flip age-verification with no authentication — on production an
# unauthenticated account-takeover surface — so the one flag whose leak would be
# most serious was the one the suite could not see. Both are correctly pinned
# today, so there was no live defect; there was no coverage either.
#
# ⚠️ The ledger's own reconciliation of this was wrong too. It recorded "7 is
# the raw preview-pinned count, 5 is after the CORE_APP/MODAL_APP exclusions" —
# but both of those numbers came from the digit-blind regex. The real figures
# are 9 literal assignments on the preview branch, 7 after excluding the two
# app-name derivations.
#
# NOT posture flags, excluded with reasons:
#   CORE_APP / MODAL_APP   assigned from a derived preview name, not a posture
#                          literal, and the production branch assigns them too
#                          (with `:-` defaults). They are identity, not posture.
#   PHX_HOST_VALUE         likewise a host derivation, not a behaviour switch.
#   every secret           API keys, passwords, database URLs and addresses are
#                          SUPPOSED to come from the environment and must never
#                          be pinned in a script. Asserting over them is the
#                          mistake that produced eighteen non-defects.

# shellcheck disable=SC2034  # consumed by the suites that source this file
POSTURE_FLAGS=(
    AGE_GATING_ENABLED
    INVITE_ONLY_REGISTRATION
    RATE_LIMIT_AUTH
    RATE_LIMIT_E2E_HELPER
    RATE_LIMIT_PUBLIC
    SMOKE_TESTS_ENABLED
    STACKS_E2E_TEST_HELPERS
)

# The value each flag must NOT have in production, for the suite that executes
# the branch under a hostile environment. Kept beside the roster so a flag
# cannot be added to one without the other noticing — the execution suite
# asserts this map covers the roster exactly.
#
# Each value is the state a stale `.env` export or a developer's shell would
# leave behind, i.e. the direction that is actually dangerous:
#   - the dark and loosening flags: ON, so a surviving value is visible
#   - the launch gate: OFF, because opening registration during a closed beta
#     is its dangerous direction
# shellcheck disable=SC2034
POSTURE_HOSTILE_VALUES=(
    "AGE_GATING_ENABLED=true"
    "INVITE_ONLY_REGISTRATION=false"
    "RATE_LIMIT_AUTH=9999"
    "RATE_LIMIT_E2E_HELPER=9999"
    "RATE_LIMIT_PUBLIC=9999"
    "SMOKE_TESTS_ENABLED=true"
    "STACKS_E2E_TEST_HELPERS=1"
)

# The value each flag must HAVE after the production branch runs. Empty means
# "the script blanks it"; a non-empty value means the script pins it ON.
# shellcheck disable=SC2034
POSTURE_PRODUCTION_VALUES=(
    "AGE_GATING_ENABLED="
    "INVITE_ONLY_REGISTRATION=true"
    "RATE_LIMIT_AUTH="
    "RATE_LIMIT_E2E_HELPER="
    "RATE_LIMIT_PUBLIC="
    "SMOKE_TESTS_ENABLED="
    "STACKS_E2E_TEST_HELPERS="
)
