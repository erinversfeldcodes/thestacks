#!/usr/bin/env bash
# test/platform/guard_unbypassable_test.sh
#
# `scripts/check-guard-is-unbypassable.sh` — a declared-count guard must not sit
# below a path that exits 0.
#
# ⛔ THE DEFECT IT CLOSES WAS LIVE. `check-breaking-suppressions-are-spent.sh`
# declared `EXPECTED_ENTRIES = 4` below an early `SystemExit(0)` that printed
# "nothing to police". So the declared count caught a PARTIAL parse and was
# bypassed entirely by a TOTAL one — and re-indenting the file it parses by ONE
# SPACE, leaving it valid YAML, made that gate exit 0 with nine live
# suppressions standing.
#
# ⚠️ These cases plant the defect back into the REAL gate rather than into a
# fixture, because the point is that this shape is reachable in code someone
# already reviewed. A fixture would prove the regex works; the real file proves
# the gate would have caught the thing it was built for.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-guard-is-unbypassable.sh"
VICTIM="$REPO_ROOT/scripts/check-breaking-suppressions-are-spent.sh"

test_case "inputs_exist" "the gate and the script it will be probed against are present"
assert_path_exists "$GATE" "scripts/check-guard-is-unbypassable.sh exists"
assert_path_exists "$VICTIM" "the suppression gate exists to be probed"

GATE_SRC="$(cat "$GATE")"

run_gate() {
    OUT="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
    RC=$?
}

# --- the real tree is clean, and says what it read -------------------------
test_case "the_real_tree_has_no_bypassable_guard" "every declared count sits above its exits"
run_gate
assert_exit_zero "$RC" "the gate passes over the tree as it stands"
assert_contains "$OUT" "16 of 16" "and states the population it enumerated"
assert_contains "$OUT" "enumerated from" "naming its enumeration source"

# ⚠️ The gate is in its OWN corpus, which is deliberate: a gate policing
# bypassable guards whose own guard were bypassable is the defect it exists for.
test_case "the_gate_polices_itself" "a guard-checker with a bypassable guard is the defect"
assert_contains "$OUT" "check-guard-is-unbypassable.sh" \
    "the gate's own declared count is in the population it checks"

# --- the planted red, against the real script -----------------------------
test_case "a_guard_below_a_success_exit_is_refused" \
    "a partial failure is caught and a total one is not, which is the case that matters"
# ⚠️ TRAPPED, not only restored inline — and this suite had the gap. It plants
# into `scripts/check-breaking-suppressions-are-spent.sh`, which is TRACKED, and
# an early exit between the plant and the inline restore would have left a
# modified gate in the tree for every suite that runs after it in `run_all.sh`.
#
# The `-s` guard is the same one its sibling needed: an empty backup is
# indistinguishable from a good one at `cp` time, so restoring from one silently
# truncates the thing it was meant to protect.
BACKUP="$(mktemp)"
cp "$VICTIM" "$BACKUP"
restore_victim() {
    if [[ -s "$BACKUP" ]]; then
        cp "$BACKUP" "$VICTIM"
    else
        echo "REFUSING to restore $VICTIM from an EMPTY backup." >&2
    fi
}
trap 'restore_victim; rm -f "$BACKUP"' EXIT

python3 - "$VICTIM" <<'PLANT'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
decl = "EXPECTED_ENTRIES = 4\n\nignore_block = re.search"
assert src.count(decl) == 1, "anchor moved — this case would pass for the wrong reason"
src = src.replace(decl, "ignore_block = re.search", 1)
anchor = "declared = set(entries)"
assert src.count(anchor) == 1, "second anchor moved"
src = src.replace(anchor, "EXPECTED_ENTRIES = 4\n\n" + anchor, 1)
open(path, "w", encoding="utf-8").write(src)
PLANT

run_gate
restore_victim
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "sit below a path that exits 0" "the refusal names the condition"
assert_contains "$OUT" "check-breaking-suppressions-are-spent.sh" "and the offending file"
assert_contains "$OUT" "EXPECTED_ENTRIES" "and the guard that was bypassable"
assert_contains "$OUT" "nine live suppressions" \
    "and grounds it in the measured case rather than the abstract rule"

test_case "the_restore_is_clean" "the probe left nothing behind"
run_gate
assert_exit_zero "$RC" "the gate passes once the plant is removed"

# --- a NON-zero exit above a guard is fine --------------------------------
#
# ⛔ THE DISCRIMINATING HALF, and without it this gate would fire on most
# refusal paths in the repository. A path that exits non-zero cannot bypass a
# guard — it just refuses earlier, which is the behaviour every gate here wants.
test_case "a_refusal_above_a_guard_is_not_a_violation" \
    "a path that refuses cannot bypass a guard, and most gates refuse early"
assert_contains "$GATE_SRC" "Non-zero exits are irrelevant" "the distinction is stated"
if grep -qE 'exit\s+0|sys\.exit\(\s*0\s*\)|SystemExit\(\s*0\s*\)' "$GATE"; then
    _record_pass "the pattern is keyed on a SUCCESS exit specifically"
else
    _record_fail "the gate's exit pattern no longer names a zero exit, so it may match any exit"
fi
# The suppression gate has several `raise SystemExit(1)` above its count; those
# must not be reported, and the clean run above is what proves it.
VICTIM_REFUSALS="$(grep -c 'SystemExit(1)' "$VICTIM" || true)"
if [[ "$VICTIM_REFUSALS" -ge 2 ]]; then
    _record_pass "the probed script carries ${VICTIM_REFUSALS} non-zero exits that are correctly ignored"
else
    _record_fail "the probed script has ${VICTIM_REFUSALS} non-zero exits, so the clean run proves little"
fi

# --- the missing-else half is deliberately NOT covered --------------------
#
# ⛔ Recorded in the gate so nobody "completes" it. The sibling instance of this
# shape was an `if`/`elif` chain with no terminal `else`, and it is NOT cheaply
# gateable: measured, that shape occurs 17 times in this repository and every
# one is legitimate. Two narrowings (every branch reports; no branch exits) took
# it to 5 then 4, all still legitimate, zero true positives.
test_case "the_unimplementable_half_is_recorded_not_implied" \
    "a gate with four known false positives needs an exemption list, which this repo just deleted"
assert_contains "$GATE_SRC" "DELIBERATELY DOES NOT COVER" "the exclusion is explicit"
# ⚠️ The needle is kept SHORT so a line wrap cannot defeat it. The full phrase
# wraps as "17 instances, every\n# one legitimate" in the gate's comment, and
# this assertion failed against text that was present — the same defect
# `check-sigpipe-hazards.sh` already records about its lapse phrase.
assert_contains "$GATE_SRC" "17 instances" \
    "with the measurement that refutes the obvious rule"
assert_contains "$GATE_SRC" "zero true" \
    "and the fact that every narrowing found no real instance"
assert_contains "$GATE_SRC" "semantic" \
    "and the reason: the distinguishing property is not syntactic"

summarise
