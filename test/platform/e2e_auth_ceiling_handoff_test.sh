#!/usr/bin/env bash
# test/platform/e2e_auth_ceiling_handoff_test.sh
#
# The preview's `:auth` ceiling has to reach the suite that floods past it, in
# EVERY environment that deploys a preview — not only inside a GitHub Actions
# job.
#
# ⛔ WHAT THIS SUITE EXISTS BECAUSE OF. `scripts/deploy-stack.sh` raises the
# preview's `:auth` bucket above production parity so the E2E suite's own
# opening burst of real logins cannot exhaust it, and `rate-limit.spec.ts`
# sizes its brute-force flood from that ceiling — a flood shorter than the
# ceiling can never see a 429. The handoff was
# `echo "E2E_AUTH_RATE_LIMIT=…" >> "$GITHUB_ENV"`, and `$GITHUB_ENV` exists
# only in Actions. The gate this project actually runs deploys the same stack
# from a shell, where the value never arrived: the flood was sized at 70
# against a ceiling of 200, and the spec failed saying "the per-IP :auth
# bucket is not limiting … treat it as brute-force protection being absent,
# not as a flaky test."
#
# ⚖️ A security verdict produced by a missing environment variable. The comment
# beside the handoff claimed the two numbers "cannot drift apart" — true in
# one environment, false in the other, and nothing related them.
#
# ⚠️ WHAT THIS PROVES AND DOES NOT. It proves the ceiling reaches the E2E step
# with no Actions environment present, that both channels carry the same
# number, and that the spec refuses to guess one. It does NOT prove the stack
# ENFORCES that ceiling — that is the spec's job against a deployed stack, and
# nothing here contacts one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

LIB="$REPO_ROOT/scripts/lib/e2e-handoff.sh"
SCRIPT="$REPO_ROOT/scripts/deploy-stack.sh"
CI="$REPO_ROOT/scripts/ci.sh"
SPEC="$REPO_ROOT/e2e/tests/rate-limit.spec.ts"

test_case "inputs_exist" "every file this suite reasons about is where it expects"
assert_path_exists "$LIB" "scripts/lib/e2e-handoff.sh exists"
assert_path_exists "$SCRIPT" "scripts/deploy-stack.sh exists"
assert_path_exists "$CI" "scripts/ci.sh exists"
assert_path_exists "$SPEC" "e2e/tests/rate-limit.spec.ts exists"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── the library, on its own terms ────────────────────────────────────────────

test_case "the_library_round_trips_with_no_actions_environment" \
    "a value written with GITHUB_ENV unset is loadable afterwards"
OUT="$(
    unset GITHUB_ENV
    export E2E_HANDOFF_FILE="$WORK/round-trip.env"
    # shellcheck source=../../scripts/lib/e2e-handoff.sh
    source "$LIB"
    e2e_handoff_reset
    e2e_handoff_write E2E_AUTH_RATE_LIMIT 177
    unset E2E_AUTH_RATE_LIMIT
    e2e_handoff_load
    printf 'loaded=%s' "${E2E_AUTH_RATE_LIMIT:-<unset>}"
)"
assert_contains "$OUT" "loaded=177" "the value survives write → load without \$GITHUB_ENV"

test_case "a_load_with_nothing_to_load_is_quiet" \
    "an absent handoff is the caller's judgement, not a crash"
OUT="$(
    export E2E_HANDOFF_FILE="$WORK/absent.env"
    # shellcheck source=../../scripts/lib/e2e-handoff.sh
    source "$LIB"
    e2e_handoff_load
    printf 'rc=%s value=%s' "$?" "${E2E_AUTH_RATE_LIMIT:-<unset>}"
)"
assert_contains "$OUT" "rc=0" "loading nothing exits zero"
assert_contains "$OUT" "value=<unset>" "and invents no value"

# ── the deploy's preview branch, EXECUTED ────────────────────────────────────
#
# Reading the script cannot establish this. A handoff can be present in the
# text and unreachable in the run — which is exactly what `$GITHUB_ENV` was.
# So the branch is extracted and run, with no Actions environment at all.

BRANCH_FILE="$WORK/preview-branch.sh"
awk '
    /^if \[\[ "\$PROD_MODE" -eq 1 \]\]; then$/ { in_prod = 1; next }
    in_prod && /^else$/ { in_prod = 0; in_preview = 1; next }
    in_preview && /^fi$/ { exit }
    in_preview { print }
' "$SCRIPT" > "$BRANCH_FILE"

# ⚠️ The load-bearing guard of the file, for the reason its sibling records: a
# block that extracted PARTIALLY would write nothing and every assertion below
# would read as a defect in the deploy script rather than in these anchors.
test_case "extraction_is_complete" "the preview branch was extracted whole"
LINES="$(grep -c . "$BRANCH_FILE" || true)"
if [[ "${LINES:-0}" -lt 10 ]]; then
    _record_fail "extracted only ${LINES} line(s) of the preview branch — the anchors no longer match the script's shape, so every assertion below would be testing an empty block"
else
    _record_pass "extracted ${LINES} lines of the preview branch"
fi
assert_contains "$(cat "$BRANCH_FILE")" "Deploy stack for branch" \
    "the extracted block is the one that announces a preview deploy"

printf '\nprintf "CEILING_PINNED=%%s\\n" "${RATE_LIMIT_AUTH}"\n' >> "$BRANCH_FILE"

run_preview_branch() {   # HANDOFF_FILE [GITHUB_ENV_FILE]
    local handoff="$1" github_env="${2:-}"
    (
        set -uo pipefail
        export REPO_ROOT="$REPO_ROOT"
        export BRANCH="handoff-suite"
        export PREVIEW_CORE_APP="suite-core"
        export PREVIEW_MODAL_APP="suite-modal"
        export NEON_STAGING_PROJECT_ID="suite-project"
        export STACKS_SKIP_RESOLVER_PREFLIGHT=1
        export E2E_HANDOFF_FILE="$handoff"
        if [[ -n "$github_env" ]]; then
            export GITHUB_ENV="$github_env"
        else
            unset GITHUB_ENV
        fi
        bash "$BRANCH_FILE" 2>&1
    )
}

HANDOFF="$WORK/deploy.env"
test_case "the_ceiling_reaches_the_e2e_step_with_no_github_env" \
    "the defect itself: the handoff must not depend on GitHub Actions"
OUT="$(run_preview_branch "$HANDOFF")"
if [[ -f "$HANDOFF" ]] && grep -q '^E2E_AUTH_RATE_LIMIT=' "$HANDOFF"; then
    _record_pass "the preview branch wrote E2E_AUTH_RATE_LIMIT with GITHUB_ENV unset: $(tr '\n' ' ' < "$HANDOFF")"
else
    _record_fail "the preview branch left no E2E_AUTH_RATE_LIMIT in its handoff when GITHUB_ENV was unset — the ceiling reaches the suite only inside a GitHub Actions job, which is the defect this suite exists for. Branch output: ${OUT}"
fi

test_case "the_handed_over_value_IS_the_ceiling_the_stack_is_given" \
    "the relation, not merely the arrival — a number that is not this stack's teaches nothing"
PINNED="$(printf '%s\n' "$OUT" | sed -n 's/^CEILING_PINNED=//p' | tail -1)"
HANDED="$(sed -n 's/^E2E_AUTH_RATE_LIMIT=//p' "$HANDOFF" 2>/dev/null | tail -1)"
if [[ -n "$PINNED" && "$PINNED" == "$HANDED" ]]; then
    _record_pass "the branch pins RATE_LIMIT_AUTH=${PINNED} and hands over ${HANDED} — the same number, from the same assignment"
else
    _record_fail "the branch pins RATE_LIMIT_AUTH='${PINNED}' but hands the suite '${HANDED}'. A flood sized from the second cannot overshoot the first, and the spec's failure message would blame the bucket."
fi

test_case "both_channels_say_the_same_thing" \
    "the GitHub mirror is written from the same argument, so it cannot disagree"
HANDOFF2="$WORK/deploy2.env"
GH_ENV="$WORK/github.env"
: > "$GH_ENV"
OUT2="$(run_preview_branch "$HANDOFF2" "$GH_ENV")"
MIRROR="$(sed -n 's/^E2E_AUTH_RATE_LIMIT=//p' "$GH_ENV" 2>/dev/null | tail -1)"
HANDED2="$(sed -n 's/^E2E_AUTH_RATE_LIMIT=//p' "$HANDOFF2" 2>/dev/null | tail -1)"
if [[ -n "$MIRROR" && "$MIRROR" == "$HANDED2" ]]; then
    _record_pass "file and \$GITHUB_ENV both carry ${MIRROR}"
else
    _record_fail "file carries '${HANDED2}' and \$GITHUB_ENV carries '${MIRROR}' — two channels that can differ are two numbers to keep in step. Branch output: ${OUT2}"
fi

test_case "a_previous_runs_ceiling_is_not_read_as_this_ones" \
    "the reset, which is the same defect wearing the opposite sign"
STALE="$WORK/stale.env"
printf 'E2E_AUTH_RATE_LIMIT=9999\n' > "$STALE"
run_preview_branch "$STALE" >/dev/null
COUNT="$(grep -c '^E2E_AUTH_RATE_LIMIT=' "$STALE" 2>/dev/null || true)"
if [[ "${COUNT:-0}" -eq 1 ]] && ! grep -q '^E2E_AUTH_RATE_LIMIT=9999$' "$STALE"; then
    _record_pass "the stale 9999 was cleared, leaving one current value: $(tr '\n' ' ' < "$STALE")"
else
    _record_fail "the handoff still holds a previous run's value ($(tr '\n' ' ' < "$STALE")) — a flood sized from a ceiling this stack does not run is as wrong as one sized from a guess"
fi

# ── the reader ───────────────────────────────────────────────────────────────

CI_SRC="$(cat "$CI")"

test_case "the_e2e_step_loads_the_handoff_before_it_runs_the_suite" \
    "a load after the suite is a load that taught it nothing"
LOAD_LINE="$(grep -n 'e2e_handoff_load' "$CI" | head -1 | cut -d: -f1)"
SUITE_LINE="$(grep -n 'run_group "deploy: e2e" bash scripts/test-e2e.sh' "$CI" | head -1 | cut -d: -f1)"
if [[ -n "$LOAD_LINE" && -n "$SUITE_LINE" && "$LOAD_LINE" -lt "$SUITE_LINE" ]]; then
    _record_pass "ci.sh loads the handoff at line ${LOAD_LINE}, before the deployed suite at line ${SUITE_LINE}"
else
    _record_fail "ci.sh does not load the handoff before the deployed E2E suite (load=${LOAD_LINE:-none}, suite=${SUITE_LINE:-none})"
fi

test_case "the_e2e_step_refuses_an_absent_handoff" \
    "running the suite half-informed is what produced the false verdict"
assert_contains "$CI_SRC" 'if [[ -z "${E2E_AUTH_RATE_LIMIT:-}" ]]; then' \
    "ci.sh checks the ceiling actually arrived"
assert_contains "$CI_SRC" "deploy-e2e-handoff" \
    "and records a named failure rather than proceeding quietly"

SPEC_SRC="$(cat "$SPEC")"

test_case "the_spec_has_no_fallback_ceiling" \
    "the default is what let a harness fault wear a security verdict"
# ⛔ STRIPPED FIRST, because this repository has caught itself five times with
# an absence assertion that matched the prose explaining why the pattern is
# banned. The comment above the read in rate-limit.spec.ts QUOTES the removed
# `|| 60` to record what it cost; an unstripped grep reads that quotation as
# the defect and fails a file that is correct. Full-line and block comments
# only — a trailing `//` after code is not stripped, and a URL's `//` is
# therefore never mangled.
SPEC_CODE="$(python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
sys.stdout.write("\n".join(l for l in src.split("\n") if not l.lstrip().startswith("//")))
' "$SPEC")"
# ⚠️ Anti-vacuity: a strip that blanked the file would make the absence check
# pass for the wrong reason, which is the failure mode one layer up.
if ! grep -q 'DECLARED_AUTH_CEILING' <<< "$SPEC_CODE"; then
    _record_fail "the comment strip removed the code as well — the absence check below would pass against an empty file"
elif grep -qE 'E2E_AUTH_RATE_LIMIT[^;]*\|\|' <<< "$SPEC_CODE"; then
    _record_fail "rate-limit.spec.ts still falls back to a hardcoded ceiling when E2E_AUTH_RATE_LIMIT is unset: $(grep -nE 'E2E_AUTH_RATE_LIMIT[^;]*\|\|' <<< "$SPEC_CODE" | head -3). A flood sized from that default cannot reach a raised ceiling, and the spec blames the bucket."
else
    _record_pass "the spec reads the ceiling with no fallback (checked against $(grep -c . <<< "$SPEC_CODE") non-comment line(s))"
fi
assert_contains "$SPEC_SRC" "E2E_AUTH_RATE_LIMIT is unset" \
    "and says so by name when nothing told it"
assert_contains "$SPEC_SRC" "e2e-handoff.sh" \
    "naming the channel that should have, so the reader is not left guessing"

summarise
