#!/usr/bin/env bash
# test/platform/cli_stub_provenance_test.sh
#
# `scripts/check-cli-stub-provenance.sh` — a stubbed CLI must say which real
# tool output it encodes.
#
# ⛔ WHAT IT IS FOR. A stubbed suite can only test the contract its stub
# encodes, and that cost three undetected faults in one script. The preview
# orphan sweep was driven against a stub `modal` emitting the 1.2.6 key spelling
# and a successful `app stop`; the real 1.6.2 renamed those keys and PROMPTS on
# `app stop`, so the live leg collected nothing and swept nothing while every
# assertion passed.
#
# ⚠️ The cases below are deliberately driven through COPIES of the gate with
# `EXPECTED_PAIRS` adjusted, never by editing the committed gate. A planted stub
# changes the population, so the declared-count check would fire FIRST and every
# case would pass on the wrong refusal — the trap this project has already paid
# for once in the breaking-suppression gate.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-cli-stub-provenance.sh"

test_case "inputs_exist" "the gate is present"
assert_path_exists "$GATE" "scripts/check-cli-stub-provenance.sh exists"

PLANT_DIR="$(mktemp -d)"
PLANTED_SH="$REPO_ROOT/test/platform/zz_provenance_plant_test.sh"
cleanup() { rm -rf "$PLANT_DIR"; rm -f "$PLANTED_SH"; }
trap cleanup EXIT

run_gate() {
    OUT="$(cd "$REPO_ROOT" && bash "$1" 2>&1)"
    RC=$?
}

# ── the real tree: every stub accounts for itself ──────────────────────────
test_case "the_real_tree_accounts_for_every_stub" "each stubbed CLI carries a marker"
run_gate "$GATE"
assert_exit_zero "$RC" "the gate passes over the tree as it stands"
assert_contains "$OUT" "7 of 7" "and states the population it enumerated"
assert_contains "$OUT" "enumerated from the stub definitions" \
    "naming its enumeration source, because a count without one is not checkable"

# ⚖️ The three-state report. `unknown` is a DECLARED gap and passes; it must be
# counted and shown rather than folded into the pass.
test_case "an_unverified_stub_is_reported_not_hidden" \
    "a declared gap passes, but silently passing is how the gap survives"
assert_contains "$OUT" "declared UNVERIFIED" "unverified stubs are counted separately"
assert_contains "$OUT" "never been compared to one" \
    "and the report says what that actually means"
assert_contains "$OUT" "re-recorded against the real CLI" \
    "while the verified ones are distinguished from them"

# ── a stub with NO marker is refused ───────────────────────────────────────
#
# ⛔ The planted red. A new stub with no provenance must fail; without this case
# the gate is only asserting that seven markers it already has still exist.
cat > "$PLANTED_SH" <<'PLANT'
#!/usr/bin/env bash
set -uo pipefail
STUBS="$(mktemp -d)"
cat > "$STUBS/psql"
echo stub
PLANT

PLANTED_GATE="$PLANT_DIR/gate-plus-one.sh"
sed 's/^EXPECTED_PAIRS = 7$/EXPECTED_PAIRS = 8/' "$GATE" > "$PLANTED_GATE"
if grep -q 'EXPECTED_PAIRS = 8' "$PLANTED_GATE"; then
    _record_pass "the copy's declared count was bumped, so the count check will not fire first"
else
    _record_fail "could not bump the count — the next case would pass on the wrong refusal"
fi

test_case "an_undocumented_stub_is_refused" "a stub with no provenance fails the build"
run_gate "$PLANTED_GATE"
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "do not say what real output they encode" "the refusal names the condition"
assert_contains "$OUT" "zz_provenance_plant_test.sh" "and the offending file"
assert_contains "$OUT" "psql" "and the tool it stubs"
assert_contains "$OUT" "memory of an API" "and says why a date is what makes it re-checkable"

# ── the declared count moves in both directions ────────────────────────────
#
# ⚠️ With the plant still in place, the UNMODIFIED gate must refuse on the count.
# That is the half that catches a stub added without a decision being recorded.
test_case "an_unrecorded_new_stub_trips_the_count" \
    "adding a stubbed CLI is a decision, and it must show up in the diff"
run_gate "$GATE"
assert_exit_nonzero "$RC" "the committed gate refuses a population it does not expect"
assert_contains "$OUT" "expected exactly 7" "naming the declared count"
assert_contains "$OUT" "MORE means" "and distinguishing growth from a drifted parse"

rm -f "$PLANTED_SH"

test_case "the_restore_is_clean" "the planted stub is gone again"
run_gate "$GATE"
assert_exit_zero "$RC" "the gate passes once the plant is removed"

# ── a marker whose stub is gone is also refused ────────────────────────────
#
# ⚠️ The other direction, and the worse one: a stale marker is trusted by the
# next reader, where a missing one is merely absent.
cat > "$PLANTED_SH" <<'PLANT'
#!/usr/bin/env bash
set -uo pipefail
# stub-provenance: dbt 1.8.0 captured 2026-10-01
echo "this file documents a dbt stub it does not define"
PLANT

test_case "an_orphaned_marker_is_refused" "a provenance note for a stub that does not exist is a claim about nothing"
run_gate "$GATE"
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "describe a stub that is gone" "the refusal names the condition"
assert_contains "$OUT" "dbt" "and the tool the stale marker documents"

rm -f "$PLANTED_SH"

# ── age is reported, never failed ──────────────────────────────────────────
#
# ⛔ Pins a deliberate decision that looks like a weakness. A gate that turns red
# at N days fires in CI on a day nobody changed anything, and the first fix for
# that is to delete the gate. So the age is printed and the gate stays green.
test_case "age_is_a_count_not_a_verdict" "a check that reddens on its own is a check that gets deleted"
GATE_SRC="$(cat "$GATE")"
assert_contains "$GATE_SRC" "AGE IS REPORTED, NOT FAILED" "the decision is recorded in the gate"
assert_contains "$GATE_SRC" "time bomb" "with the reason stated"
run_gate "$GATE"
assert_exit_zero "$RC" "and an aged capture does not fail the build"
assert_contains "$OUT" "A COUNT, not a verdict" "while the output refuses to read as a verdict"

# ── the enumeration is from the stubs, not from the markers ────────────────
#
# ⛔ The constraint that makes this gate meaningful rather than circular: a list
# built by asking which markers exist can only contain tools somebody already
# documented, which is the defect and not the check.
test_case "the_population_comes_from_the_stubs" "a list built from the checkers can only contain what they cover"
assert_contains "$GATE_SRC" "ENUMERATED FROM THE STUBS" "the direction is stated"
assert_contains "$GATE_SRC" "never the reverse" "and the inverse is named as wrong"

summarise
