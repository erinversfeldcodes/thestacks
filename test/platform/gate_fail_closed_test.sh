#!/usr/bin/env bash
# test/platform/gate_fail_closed_test.sh
#
# A gate must fail DELIBERATELY when it has nothing to inspect — not by
# accident, and never silently.
#
# ⚠️ The distinction this suite exists for. Probed for vacuity — shadow `git` so
# `git rev-parse --show-toplevel` fails and `REPO_ROOT` falls back to `.`, then
# run from an empty directory — most gates here do exit non-zero. But the
# majority do so on an unhandled Python `FileNotFoundError` for an anchor file,
# which is fail-closed by ACCIDENT: the moment such a gate's anchor read moves
# from a direct `open()` to a glob, the traceback disappears and the gate
# reports a clean pass over nothing. Thirteen gates are in that position today.
#
# Three real defects were found by running that probe, and this suite pins their
# fixes:
#
#   1. `check-component-dispatch.sh` printed "OK: all 0 drivable component(s)
#      are dispatched." and exited 0. Both of its populations come from globs,
#      so a wrong root yields two empty sets and the success path reports a
#      pass. A count inside a success message is not a guard — nobody reads
#      "all 0".
#
#   2. `check-slo-gate.sh` printed "CORE_APP required in production mode" and
#      exited **0**. The cause is a bash behaviour worth knowing: **`${var:?}`
#      plus ANY `trap … EXIT` exits 0.** Measured in isolation — bare, the
#      idiom exits 1; with a trap installed above it, the same script prints
#      the message and exits 0. A status-preserving `trap 'rc=$?; …; exit $rc'`
#      does not help, because `$?` is still 0 on that path. So the production
#      SLO gate announced its own missing inputs and reported success.
#
#   3. `check-licenses.sh` has three legs that each skip when their tool or
#      lockfile is absent, and the skips compose: all three skipping printed
#      "All licence checks passed." and exited 0 having inspected nothing.
#
# ⚠️ And one FALSE POSITIVE, recorded because the probe's limits matter as much
# as its results: `check-e2e-vacuous-guards.sh` also exited 0 under the probe,
# but it derives `REPO_ROOT` from `BASH_SOURCE`, so it always `cd`s into the
# real repository and the probe never reached it. Its exit 0 was a correct pass
# over the real specs. Four gates derive `REPO_ROOT` that way and are out of
# the probe's reach by construction — a clean result from this probe says
# nothing about them.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# `git` shadowed so `REPO_ROOT` falls back to `.`, which is an empty directory.
mkdir -p "$SANDBOX/bin" "$SANDBOX/empty"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/git"

# Run a gate with no inputs reachable, returning its exit code and output.
run_starved() {
    STARVED_OUT="$(cd "$SANDBOX/empty" && PATH="$SANDBOX/bin:$PATH" bash "$REPO_ROOT/scripts/$1" 2>&1)"
    STARVED_RC=$?
}

test_case "inputs_exist" "the gates under test are present"
for g in check-component-dispatch.sh check-slo-gate.sh check-licenses.sh; do
    assert_path_exists "$REPO_ROOT/scripts/$g" "scripts/$g exists"
done

# ── 1. a glob-fed gate refuses rather than passing over nothing ─────────────

test_case "component_dispatch_refuses_an_empty_tree" \
    "a gate whose populations are globs must not pass when both are empty"
run_starved check-component-dispatch.sh
if [[ "$STARVED_RC" -eq 0 ]]; then
    _record_fail "check-component-dispatch.sh exited 0 with no Elm tree reachable. Its populations are globs, so an empty result is drift — and the success message reports it as \"all 0 drivable component(s) are dispatched\", which reads as a pass: $STARVED_OUT"
else
    _record_pass "check-component-dispatch.sh refused (exit $STARVED_RC)"
fi

assert_contains "$STARVED_OUT" "found no Elm sources" \
    "the refusal names the missing population, rather than failing on a traceback"
assert_not_contains "$STARVED_OUT" "Traceback (most recent call last)" \
    "it is a deliberate guard, not an accidental FileNotFoundError"

test_case "component_dispatch_still_passes_for_real" "the guard did not break the real run"
# The positive control. A gate that refuses everything satisfies the assertion
# above while being useless, and this is the cheapest way to tell the two apart.
REAL_OUT="$(cd "$REPO_ROOT" && bash scripts/check-component-dispatch.sh 2>&1)"
REAL_RC=$?
if [[ "$REAL_RC" -eq 0 ]]; then
    _record_pass "the real run still passes"
else
    _record_fail "check-component-dispatch.sh now fails against the real repository: $REAL_OUT"
fi
assert_not_contains "$REAL_OUT" "all 0 drivable" \
    "the real run inspects a non-empty population"

# ── 2. a missing required input is a refusal, not a pass ────────────────────

test_case "slo_gate_refuses_without_its_required_inputs" \
    "the production SLO gate cannot report success when it was never told what to measure"
run_starved check-slo-gate.sh
if [[ "$STARVED_RC" -eq 0 ]]; then
    _record_fail "check-slo-gate.sh exited 0 without CORE_APP or METRICS_SCRAPE_TOKEN. This is the \${var:?}-plus-EXIT-trap trap: the message is printed and the status is 0, so a production gate reports success having measured nothing: $STARVED_OUT"
else
    _record_pass "check-slo-gate.sh refused (exit $STARVED_RC)"
fi

assert_contains "$STARVED_OUT" "is required in production mode" \
    "the refusal names the missing variable"
assert_contains "$STARVED_OUT" "This is a refusal, not a pass" \
    "and says plainly that nothing was measured"

test_case "the_required_input_check_does_not_use_the_broken_idiom" \
    "no \${var:?} guards a required input in a script with an EXIT trap"
# ⚠️ Asserted on the SOURCE, not only on the behaviour, because the behaviour
# above would also be satisfied by a different accident. The idiom is the
# defect: it is the obvious way to write this and it silently does not work
# here. Matched on the executable form so the explanatory comment does not
# satisfy it.
SLO_CODE="$(sed 's/[[:space:]]*#.*$//' "$REPO_ROOT/scripts/check-slo-gate.sh")"
if grep -qE ':[[:space:]]+"\$\{[A-Za-z_][A-Za-z0-9_]*:\?' <<<"$SLO_CODE"; then
    _record_fail "check-slo-gate.sh uses \${var:?} for a required input while installing a trap … EXIT. Measured: that combination prints the message and exits 0. Use an explicit test and \`exit 1\`."
else
    _record_pass "required inputs are checked with an explicit test and exit"
fi

# ── 3. zero checks run is not a pass ───────────────────────────────────────

test_case "licenses_gate_distinguishes_a_skip_from_a_pass" \
    "all three legs skipping is reported as a skip, not as success"
# Run from a sandbox holding ONLY the script, so every leg's tool and lockfile
# is absent. `REPO_ROOT` here comes from BASH_SOURCE, so the script must be
# copied rather than reached through a shadowed `git`.
mkdir -p "$SANDBOX/lic/scripts"
cp "$REPO_ROOT/scripts/check-licenses.sh" "$SANDBOX/lic/scripts/"
LIC_OUT="$(cd "$SANDBOX/lic" && bash scripts/check-licenses.sh 2>&1)"
LIC_RC=$?
if [[ "$LIC_RC" -eq 0 ]]; then
    _record_fail "check-licenses.sh exited 0 with all three legs skipped, having inspected nothing. \"All licence checks passed\" is the same claim for zero checks as for three: $LIC_OUT"
else
    _record_pass "check-licenses.sh refused when every leg skipped (exit $LIC_RC)"
fi

assert_contains "$LIC_OUT" "This is a SKIP, not a pass" \
    "the refusal says so in the words the sibling squawk gate already uses"
assert_not_contains "$LIC_OUT" "All licence checks passed" \
    "it must not claim a pass it did not earn"

test_case "licenses_gate_reports_how_many_legs_ran" "a partial run says how partial it was"
# The positive control, and the reason the fix is a counter rather than a
# refusal: one leg skipping while others run is still a real check, and failing
# that would block the ordinary local case the tolerance exists for.
REAL_LIC="$(cd "$REPO_ROOT" && bash scripts/check-licenses.sh 2>&1)"
assert_contains "$REAL_LIC" "dependency trees inspected" \
    "the success message states the number of trees actually inspected"

summarise
