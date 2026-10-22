#!/usr/bin/env bash
# test/platform/breaking_suppressions_test.sh
#
# Two things, both about `buf breaking` being real rather than nominal:
#
#   1. `scripts/check-breaking-suppressions-are-spent.sh` — a suppression that
#      suppresses nothing must fail the build.
#   2. `scripts/lint-proto.sh` must FAIL when origin/main is unavailable, rather
#      than falling through in silence.
#
# ⛔ The second is why the first matters. The `lint-proto` CI job checked out at
# the default shallow depth, so `origin/main` did not exist, `git rev-parse
# --verify origin/main` failed, the `elif` was false, and with no `else` the
# whole construct fell through printing NOTHING. `buf breaking` had never run in
# CI. A gate policing suppressions would have been policing a gate that was not
# running.
#
# ⛔ And the policing gate's own first implementation was VACUOUS. It removed one
# entry at a time and asked whether `buf breaking` still failed — which it does,
# for violations covered by the OTHER entries. MEASURED: a deliberately spent
# entry (`FIELD_SAME_CARDINALITY` on `social.proto`, a file with no violations)
# was reported load-bearing alongside all four real ones. The exit status is a
# property of the whole run; the question is per-entry, so the verdict has to
# come from the violation LIST.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-breaking-suppressions-are-spent.sh"
LINT="$REPO_ROOT/scripts/lint-proto.sh"
BUF_YAML="$REPO_ROOT/proto/buf.yaml"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"
LINT_SRC="$(cat "$LINT" 2>/dev/null)"

BUF_BACKUP="$(mktemp)"
cp "$BUF_YAML" "$BUF_BACKUP"
restore_buf() { cp "$BUF_BACKUP" "$BUF_YAML"; rm -f "$BUF_BACKUP"; }
trap restore_buf EXIT

run_gate() {
    OUT=$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)
    RC=$?
}

# --- the real tree: every suppression is load-bearing ----------------------

test_case "the_real_tree_has_no_spent_suppression" "each entry covers a violation that exists"
run_gate
assert_exit_zero "$RC" "the gate passes over buf.yaml as it stands"
assert_contains "$OUT" "load-bearing" "and says how many entries it checked"
assert_contains "$OUT" "violation(s)" "and how many violations it matched them against"

# --- a spent suppression is refused ----------------------------------------

# ⛔ The planted red, and the case that caught the vacuous implementation.
# `social.proto` has no breaking violations at all — the baseline passes without
# it suppressed — so an entry for it is definitionally spent.
#
# ⚠️ The gate's declared entry count has to move with the plant, or the count
# check fires first and this case passes on the wrong refusal. Driven through a
# COPY of the gate with the count bumped, so the committed gate is untouched.
PLANTED_GATE="$(mktemp)"
sed 's/^EXPECTED_ENTRIES = 4$/EXPECTED_ENTRIES = 5/' "$GATE" > "$PLANTED_GATE"
if grep -q 'EXPECTED_ENTRIES = 5' "$PLANTED_GATE"; then
    _record_pass "the copy's declared count was bumped, so the count check will not fire first"
else
    _record_fail "could not bump the count — this case would pass on the wrong refusal"
fi

python3 - "$BUF_YAML" <<'PLANT'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "    FIELD_SAME_CARDINALITY:\n      - stacks/common/v1/writing_assistant.proto"
assert src.count(needle) == 1, "anchor moved — this case would pass for the wrong reason"
src = src.replace(needle, needle + "\n      - stacks/common/v1/social.proto", 1)
open(path, "w", encoding="utf-8").write(src)
PLANT

test_case "a_spent_suppression_is_refused" "an entry covering nothing fails the build"
OUT=$(cd "$REPO_ROOT" && bash "$PLANTED_GATE" 2>&1)
RC=$?
rm -f "$PLANTED_GATE"
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "are SPENT" "the refusal names the condition"
assert_contains "$OUT" "social.proto" "and names the offending entry"
assert_contains "$OUT" "standing allowance" "and says what a spent entry costs while it stands"

restore_buf
BUF_BACKUP="$(mktemp)"
cp "$BUF_YAML" "$BUF_BACKUP"

test_case "the_restore_is_clean" "the planted entry is gone again"
run_gate
assert_exit_zero "$RC" "the gate passes once the plant is removed"

# --- the declared count moves in both directions ---------------------------

test_case "the_entry_count_is_declared" "adding or removing a suppression is a recorded decision"
assert_contains "$GATE_SRC" "EXPECTED_ENTRIES = 4" "the population is declared, not floored"
assert_contains "$GATE_SRC" "FEWER means" "fewer entries is distinguished from a drifted parse"
assert_contains "$GATE_SRC" "MORE means" "and more is distinguished from a legitimate addition"

# --- the verdict comes from the violation list, not the exit status --------

# ⛔ Pins the fix for the vacuous first implementation. If this ever reverts to
# per-entry removal plus an exit-status check, every entry reads as load-bearing
# whenever any other entry is doing work.
test_case "the_verdict_comes_from_the_violation_list" "an exit status cannot answer a per-entry question"
assert_contains "$GATE_SRC" "error-format=json" "violations are read structurally"
assert_contains "$GATE_SRC" "declared & violations" "and matched against the declared entries"
assert_contains "$GATE_SRC" "property of the whole run" "with the reason recorded"

# --- an uncovered violation is also refused --------------------------------

test_case "an_uncovered_violation_is_refused" "a breaking change nobody recorded fails too"
assert_contains "$GATE_SRC" "covered by no ignore_only entry" "the other direction is checked"

# --- an empty violation set is a refusal, not a pass ----------------------

test_case "an_empty_violation_set_is_refused" "a clean verdict over a failed buf run is impossible"
# ⚠️ This floor earned its place immediately: the gate's first working version
# copied `proto/` to a temp dir and kept the relative `../.git` against-ref,
# which has no `.git` two levels up — so buf exited 1 with no violations. The
# floor reported "buf did not run" instead of "nothing is spent".
assert_contains "$GATE_SRC" "reported no violations" "an empty result refuses"
assert_contains "$GATE_SRC" "cannot tell those apart" "and says why it will not guess"

# --- lint-proto FAILS when it cannot run buf breaking ---------------------

# ⛔ The silent fall-through that meant buf breaking never ran in CI.
test_case "lint_proto_refuses_without_origin_main" "a gate that cannot run is a failure, not a skip"
assert_contains "$LINT_SRC" "origin/main is not available" "the fall-through now fails"
assert_contains "$LINT_SRC" "NOTHING WAS CHECKED" "and says so in the words this repo uses"
assert_contains "$LINT_SRC" "fetch-depth: 0" "and names the CI fix"
assert_contains "$LINT_SRC" "BUF_BREAKING_SKIP=1 says so out loud" \
    "while leaving the deliberate-migration escape explicit"

test_case "ci_gives_lint_proto_the_history_it_needs" "the job must not checkout shallow"
CI_YML="$(cat "$REPO_ROOT/.github/workflows/ci.yml" 2>/dev/null)"
LINT_JOB="$(printf '%s' "$CI_YML" | awk '/^  lint-proto:/{f=1} f{print} /^  lint-actions:/{f=0}')"
assert_contains "$LINT_JOB" "fetch-depth: 0" "the lint-proto job checks out full history"
assert_contains "$LINT_JOB" "buf-setup-action" "and still installs buf"

summarise
