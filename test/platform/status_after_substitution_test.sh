#!/usr/bin/env bash
# test/platform/status_after_substitution_test.sh
#
# scripts/check-status-after-substitution.sh refuses a `$?` read in the same
# command as a substitution that precedes it.
#
# The defect it catches cost real time twice in one session:
#
#     out=$(bash "$g" 2>&1)
#     echo "$(basename "$g") rc=$?"
#
# `basename` succeeds, so a FAILING gate printed `rc=0` beside its own FAIL
# text, and a live gate was nearly reported as failing open on that evidence.
#
# ⛔ The cases that matter most here are the NEGATIVE ones. This project
# prescribes `out=$(cmd 2>&1); rc=$?`, and the obvious discriminator — one that
# excludes only `|` and `&` between the substitution and the `$?` — flags that
# prescribed form. A gate that refuses the idiom its own project mandates gets
# switched off, so the suite pins both directions.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-status-after-substitution.sh"

# ⚠️ The gate discovers its corpus with `git ls-files` from the repository root,
# so a sandbox cannot drive it — a planted file has to live in the real tree and
# be removed afterwards. The name sorts last and is unmistakable.
PLANT="$REPO_ROOT/scripts/zz-status-probe-fixture.sh"
cleanup() { rm -f "$PLANT"; }
trap cleanup EXIT

plant() {
    cat > "$PLANT"
}

# ⛔ THE HAZARD LINE IS ASSEMBLED, NOT SPELLED, and this is not the
# literal-splitting dodge that `check-tracker-refs.sh` rightly refuses.
#
# There the test's own text WAS the input under test, so splitting a literal
# stopped testing the real thing. Here the input is the PLANTED FILE: it must
# contain the exact hazard, byte for byte, and it does. What must not contain it
# is this fixture, because the gate sweeps every `.sh` in the repository and
# this file is one — a heredoc carrying the shape made the gate report its own
# test suite as two live violations, which is how the first version of this
# suite failed six cases including "the real tree is clean".
#
# The alternative was a name-based exemption, which is the mechanism the
# platform axis is currently arguing should be DELETED from the sibling gate in
# favour of a better strip. Adding a new one here would be moving against that.
hazard_line() {
    printf 'echo "$(basename scripts/check-css.sh) rc=$%s"\n' '?'
}

run_gate() {
    OUT=$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)
    RC=$?
}

# --- the real tree is clean ------------------------------------------------

cleanup

test_case "the_real_tree_is_clean" "no committed site reads a status after a substitution"
run_gate
assert_exit_zero "$RC" "the gate passes over the repository as it stands"
assert_contains "$OUT" "shell script(s), no" "and says how many files it actually swept"

# --- the hazard shape is refused -------------------------------------------

{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'o=$(bash scripts/check-css.sh 2>&1)\n'
    hazard_line
} > "$PLANT"

test_case "the_hazard_shape_is_refused" "a `$?` inside the same command as a substitution fails"
run_gate
assert_exit_nonzero "$RC" "the gate refuses"
assert_contains "$OUT" "zz-status-probe-fixture.sh" "the planted file is named"
assert_contains "$OUT" "read \`\$?\` after a substitution" "the refusal says what is wrong"
assert_contains "$OUT" "usually succeed" "and explains why the wrong status is usually 0"

# --- the MANDATED idiom is not refused -------------------------------------

# ⛔ The case that rules out the obvious-but-wrong discriminator. `;` ends the
# command, so the assignment's own status IS the substitution's status and this
# `$?` reads it faithfully. A pattern excluding only `|` and `&` flags this.
plant <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
out=$(bash scripts/check-css.sh 2>&1); rc=$?
echo "css rc=$rc"
quoted="$(bash scripts/check-css.sh 2>&1)"; qrc=$?
echo "quoted rc=$qrc"
EOF

test_case "the_mandated_idiom_is_not_refused" "the form this project prescribes must stay legal"
run_gate
assert_exit_zero "$RC" "the gate passes on `out=\$(cmd); rc=\$?`"
assert_not_contains "$OUT" "zz-status-probe-fixture.sh" "the prescribed form is not reported"

# --- || and && also end the command ---------------------------------------

plant <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
x=$(bash scripts/check-css.sh) || rc=$?
y=$(bash scripts/check-css.sh) && echo $?
EOF

test_case "a_short_circuit_also_ends_the_command" "|| and && are boundaries too"
run_gate
assert_exit_zero "$RC" "neither form is a hazard"
assert_not_contains "$OUT" "zz-status-probe-fixture.sh" "neither is reported"

# --- both shapes in one file: exactly the hazard is named ------------------

# ⚠️ The discriminating case. A file carrying BOTH must produce exactly one
# finding, and it must be the right line — a gate that flags both is as useless
# as one that flags neither.
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'o=$(bash scripts/check-css.sh 2>&1)\n'
    hazard_line
    printf 'safe=$(bash scripts/check-css.sh 2>&1); src=$%s\n' '?'
    printf 'echo "safe rc=$src"\n'
} > "$PLANT"

test_case "both_shapes_in_one_file_yields_one_finding" "it separates them inside a single file"
run_gate
assert_exit_nonzero "$RC" "the hazard still fails the gate"
assert_contains "$OUT" "1 site(s)" "exactly one finding, not two"
assert_contains "$OUT" "rc=\$?\"" "and it is the line where \$? sits inside the command"

# --- a commented example is not a violation -------------------------------

# ⛔ The gate's own header spells the hazard out as an example, so a gate that
# read its own documentation as a violation could never ship. This repository
# has recorded five instances of exactly that.
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf '# Never write: '
    hazard_line
    printf 'echo "fine"\n'
} > "$PLANT"

test_case "a_commented_example_is_not_a_violation" "prose describing the hazard is not the hazard"
run_gate
assert_exit_zero "$RC" "the commented form passes"
assert_not_contains "$OUT" "zz-status-probe-fixture.sh" "the comment is not reported"

# --- an empty corpus is a refusal, not a pass -----------------------------

# ⛔ The fall-through must default to HAZARD: an empty violation list is what a
# clean tree produces AND what broken discovery produces.
test_case "the_floor_is_declared" "a clean verdict over nothing is impossible"
GATE_SRC="$(cat "$GATE")"
assert_contains "$GATE_SRC" "MIN_SCRIPTS" "the population floor is declared"
assert_contains "$GATE_SRC" "refusal, not a pass" "and an undersized sweep refuses"

cleanup
summarise
