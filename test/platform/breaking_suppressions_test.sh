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

# ⛔ THIS RESTORE COULD TRUNCATE A TRACKED FILE, and the fix removes the window
# rather than narrowing it.
#
# `restore_buf` used to delete the backup it restored from, so every case that
# re-armed had to `mktemp` a fresh one and re-fill it — and between those two
# statements `BUF_BACKUP` pointed at an EMPTY file while the EXIT trap was
# armed. Worse than a two-statement window: this suite runs `set -uo pipefail`
# WITHOUT `-e`, so a failed re-fill `cp` leaves the empty backup in place for
# the REST of the run, and the trap then copies zero bytes over the real file.
#
# MEASURED on a standalone reproduction of the exact shape: a tracked file went
# from 25 bytes to 0.
#
# ⚖️ TWO CHANGES, and the first is the generalisable one:
#
#   1. NEVER RESTORE FROM A BACKUP WITHOUT CHECKING IT IS NON-EMPTY. An empty
#      backup is indistinguishable from a good one at `cp` time — the same
#      "signal that means two things, one of which is I DID NOTHING" shape as a
#      verifier that echoes its own input.
#   2. The restore no longer deletes the backup, so nothing needs to re-arm and
#      the window does not exist. Deletion moves to the trap, once.
BUF_BACKUP="$(mktemp)"
cp "$BUF_YAML" "$BUF_BACKUP"

WA_PROTO="$REPO_ROOT/proto/stacks/common/v1/writing_assistant.proto"
WA_BACKUP="$(mktemp)"
cp "$WA_PROTO" "$WA_BACKUP"

restore_one() {
    local backup="$1" target="$2"
    if [[ -s "$backup" ]]; then
        cp "$backup" "$target"
    else
        echo "REFUSING to restore $target from an EMPTY backup — leaving the file as it is." >&2
    fi
}

restore_buf() { restore_one "$BUF_BACKUP" "$BUF_YAML"; }
restore_wa() { restore_one "$WA_BACKUP" "$WA_PROTO"; }

# ⚠️ BOTH planted files are in the trap, not just the one that had it. The proto
# plant was restored inline only, so an early exit left a tracked proto file
# modified — residue rather than truncation, but residue the next suite in
# `run_all.sh` would then measure as its own finding.
trap 'restore_buf; restore_wa; rm -f "$BUF_BACKUP" "$WA_BACKUP"' EXIT

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
assert_contains "$GATE_SRC" "declared & violation_pairs" "and matched against the declared entries"
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

# --- the declared count must be reachable on EVERY path ---------------------
#
# ⛔ R13-1, and it was a live fail-open. `EXPECTED_ENTRIES` sat BELOW the block
# search, so the declared count caught a PARTIAL parse and was bypassed
# entirely by a TOTAL one: no regex match meant an early `SystemExit(0)`
# printing "nothing to police" while every suppression stood.
#
# MEASURED — re-indenting `ignore_only` by ONE SPACE, which leaves the file
# valid YAML and changes nothing about what buf does, made this gate exit 0
# with nine suppression lines live in the file.
#
# ⚠️ The generalisable shape, and the second instance of it in one change: an
# audit for fail-open enumerates what each BRANCH does, and both defects lived
# on a PATH — there a missing `else`, here an early exit above the guard. There
# is nothing to read in either case.
test_case "a_total_parse_failure_cannot_bypass_the_count" \
    "an early exit above the guard is a path, not a branch — an audit of branches cannot see it"
python3 - "$BUF_YAML" <<'REINDENT'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = "\n  ignore_only:\n"
assert src.count(needle) == 1, "anchor moved — this case would pass for the wrong reason"
open(path, "w", encoding="utf-8").write(src.replace(needle, "\n   ignore_only:\n", 1))
REINDENT

run_gate
assert_exit_nonzero "$RC" "a block the parse cannot see is a refusal, not 'nothing to police'"
assert_contains "$OUT" "no \`breaking.ignore_only\` block parsed" "the refusal names what happened"
assert_contains "$OUT" "still live" "and says the suppressions are still in force"
assert_contains "$OUT" "Re-indenting the block by one space" \
    "naming the cheapest way to cause it, because the file stays valid YAML"
# ⚠️ The needle is the old OK LINE, not the phrase "nothing to police" — the new
# refusal quotes that phrase when explaining what it was about to do, so an
# absence check on it fails against the fixed gate. Same shape as this repo's
# recorded "gates read their own prose" defect, one level up in a test.
assert_not_contains "$OUT" "OK: no breaking" \
    "and it must NOT print the OK line it used to exit 0 with"

restore_buf

test_case "the_reindent_restore_is_clean" "the gate passes again once the indentation is back"
run_gate
assert_exit_zero "$RC" "the gate passes over the restored file"

# --- a suppression must cover ONLY what it was created for ------------------
#
# ⛔ Every other check in this gate is satisfied by an entry matching SOME
# violation, so a second unrelated change to the same file during the
# suppression window was silently covered with the gate green. That is the real
# price of `ignore_only` being file-scoped.
#
# ⚠️ The multiplicity was being collected and thrown away — violations went
# into a set, so the gate reported "4 violation(s)" where there are 34, which
# read as a far smaller blast radius than the suppressions actually have.
test_case "an_entry_covering_MORE_than_declared_is_refused" \
    "covering something is not the same as covering only what it was created for"
python3 - "$WA_PROTO" <<'EXTRA'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
needle = '  string title = 5 [json_name = "title"];'
assert src.count(needle) == 1, "anchor moved — this case would pass for the wrong reason"
open(path, "w", encoding="utf-8").write(
    src.replace(needle, '  int64 title = 5 [json_name = "title"];', 1)
)
EXTRA

run_gate
restore_wa
assert_exit_nonzero "$RC" "a thirteenth field-type change on a file declared to have twelve is refused"
assert_contains "$OUT" "declared 12, found 13" "the refusal gives both numbers"
assert_contains "$OUT" "covering a change nobody recorded" \
    "and says what MORE than declared means"

test_case "the_extra_violation_restore_is_clean" "the planted field type is back to string"
run_gate
assert_exit_zero "$RC" "the gate passes once the extra violation is gone"
assert_contains "$OUT" "as declared" "and each entry reports its own count"

test_case "the_report_states_violations_not_pairs" \
    "a count labelled wrongly understates the blast radius"
assert_contains "$OUT" "34 violation(s)" "the raw violation total is reported"
assert_contains "$OUT" "(rule, file) pair(s)" "distinguished from the pair count it used to print"

# --- no residue: both planted files are back as git has them ---------------
#
# ⛔ Every case above plants into a REAL tracked file — `proto/buf.yaml` and
# `writing_assistant.proto` — so the hygiene of these restores is load-bearing
# for every suite that runs after this one in `run_all.sh`. A restore that
# half-worked would show up as a finding somewhere else entirely.
#
# ⚠️ This was being checked by hand, once, by me. A manual check is not a
# check: it does not run in CI, it does not run for the next person, and it is
# exactly the kind of step that gets skipped on the run where it matters.
test_case "no_residue" "the suite must leave both planted files as it found them"
RESIDUE_OUT="$(cd "$REPO_ROOT" && git diff --name-only -- \
    proto/buf.yaml proto/stacks/common/v1/writing_assistant.proto 2>&1)"
if [[ -z "$RESIDUE_OUT" ]]; then
    _record_pass "both planted files match the index — every restore completed"
else
    _record_fail "PLANT RESIDUE left behind in: ${RESIDUE_OUT//$'\n'/, }"
fi

# ⚠️ And the restore must REFUSE an empty backup rather than copying zero bytes
# over a tracked file. Asserted on the helper's own behaviour, because the
# consequence is destructive and "it has not happened yet" is not evidence.
test_case "an_empty_backup_is_refused_not_restored" \
    "an empty backup is indistinguishable from a good one at cp time"
EMPTY_BACKUP="$(mktemp)"
VICTIM_FILE="$(mktemp)"
printf 'content that must survive\n' > "$VICTIM_FILE"
REFUSAL="$(restore_one "$EMPTY_BACKUP" "$VICTIM_FILE" 2>&1)"
SURVIVED="$(cat "$VICTIM_FILE")"
rm -f "$EMPTY_BACKUP" "$VICTIM_FILE"
if [[ "$SURVIVED" == "content that must survive" ]]; then
    _record_pass "the target was left intact rather than truncated to zero bytes"
else
    _record_fail "the target was CLOBBERED by an empty backup: '${SURVIVED}'"
fi
assert_contains "$REFUSAL" "REFUSING to restore" "and the refusal is reported rather than silent"

summarise
