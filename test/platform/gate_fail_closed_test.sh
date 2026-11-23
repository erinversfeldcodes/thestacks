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
# reports a clean pass over nothing. Thirteen gates are in that position today,
# and the whole-corpus section at the end of this suite enumerates them.
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
# the `run_starved` probe's reach by construction — a clean result from THAT
# probe says nothing about them.
#
# ⬛ THE WHOLE-CORPUS SECTION AT THE END CLOSES THAT GAP. The three named cases
# below pin specific fixes with their own mechanisms; past them, a loop starves
# EVERY `scripts/check-*.sh` via the sandbox-copy mechanism the licences case
# uses — copy the gate into an otherwise-empty `scripts/` and run it there, with
# `git` shadowed. That reaches a gate whether it roots itself on `git rev-parse`
# (REPO_ROOT falls to ".") or on `BASH_SOURCE`/`dirname "$0"` (its parent is the
# empty sandbox), so the four BASH_SOURCE gates are no longer out of reach. The
# invariant the loop holds is that ZERO gates fail OPEN — a gate that exits 0
# over nothing is a defect and a NEW one reds this suite. The thirteen that fail
# CLOSED via an unhandled exception are enumerated and pinned there, with the
# anchor each crashes on and the disposition for the set.

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

# ══ 4. the WHOLE corpus: no gate may pass over a starved population ══════════
#
# The cases above pin three specific gates. This reaches every one, via the
# sandbox-copy mechanism — copy the gate into an otherwise-empty scripts/ and
# run it there with `git` shadowed, so both root-resolution styles land in an
# empty tree. Each gate is classified:
#
#   CLEAN  exit!=0, no python traceback  — a deliberate refusal (good).
#   TRACE  exit!=0, python traceback     — fail-closed by ACCIDENT (ugly but
#          safe today; see the thirteen below).
#   OPEN   exit 0 over nothing           — a DEFECT. Must be zero.
#
# ⬛ DISPOSITION OF THE THIRTEEN TRACEBACK GATES. Each fails CLOSED (non-zero
# exit), so none emits a false pass — the traceback-refusal is ACCEPTABLE as it
# stands, just ugly. But each is FRAGILE: it fails closed only because its
# anchor read is an unhandled `open()` (twelve) or a `subprocess(check=True)`
# (one), and the moment that read becomes a glob, or gains a `try/except` that
# falls through to the success path, the gate would pass over nothing. So the
# set is PINNED, not converted here (thirteen gate edits, each needing its own
# planted red, is a separate adoption): the loop reds if ANY gate fails open —
# catching exactly the glob-ification that would turn one of these fail-open —
# and reds if this documented set drifts, forcing a conscious decision. A gate
# that ADOPTS a clean refusal leaves the set and must be dropped from the list
# (the ratchet toward clean refusals); a NEW traceback gate must be given a
# clean refusal or added here with its anchor.
#
#   gate                                anchor it crashes on (starved)
#   check-css-contrast.sh               open('frontend/css/main.css')
#   check-css-values.sh                 open('frontend/css/main.css')
#   check-css.sh                        open('frontend/css/main.css')
#   check-dbt-model-drift.sh            open('docs/technical-architecture.md')
#   check-mapping-truth.sh              open('docs/implementation-mapping.md')
#   check-oban-queue-drift.sh           open('apps/core/config/config.exs')
#   check-orphan-classes.sh             open('frontend/css/main.css')
#   check-phase-scheme.sh               open('docs/implementation-mapping.md')
#   check-public-route-metering.sh      open('apps/core/lib/core_web/router.ex')
#   check-route-clients.sh              open('apps/core/lib/core_web/router.ex')
#   check-route-reachability.sh         open('frontend/src/Main.elm')
#   check-session-expiry-coverage.sh    open('frontend/src/Api.elm')
#   check-tracker-refs.sh               subprocess ['git','ls-files','-z'] (check=True)
EXPECTED_TRACEBACK="
check-css-contrast.sh
check-css-values.sh
check-css.sh
check-dbt-model-drift.sh
check-mapping-truth.sh
check-oban-queue-drift.sh
check-orphan-classes.sh
check-phase-scheme.sh
check-public-route-metering.sh
check-route-clients.sh
check-route-reachability.sh
check-session-expiry-coverage.sh
check-tracker-refs.sh
"

# Copy ONE gate into an empty scripts/ and run it there with git shadowed. The
# `$SANDBOX/bin/git` stub and the empty-tree starve are the same ones the cases
# above use; only the ROOT differs — here it is the copy's own parent, which
# starves the BASH_SOURCE/`dirname` gates that `run_starved` leaves in the real
# repository.
starve_copy() {
    local gate="$1" dir
    dir="$(mktemp -d "$SANDBOX/corpus.XXXXXX")"
    mkdir -p "$dir/scripts"
    cp "$REPO_ROOT/scripts/$gate" "$dir/scripts/$gate"
    STARVED_OUT="$(cd "$dir" && PATH="$SANDBOX/bin:$PATH" timeout 60 bash "scripts/$gate" 2>&1)"
    STARVED_RC=$?
    rm -rf "$dir"
}

sorted_unique() { printf '%s\n' $1 | grep -v '^[[:space:]]*$' | sort -u; }

mapfile -t ALL_GATES < <(cd "$REPO_ROOT" && ls scripts/check-*.sh | sed 's#scripts/##' | sort)

# ⛔ The loop's OWN floor — an empty gate list makes every assertion below
# vacuous, the exact shape this suite exists to catch. The corpus is ~50; this
# refuses a glob that returned implausibly few.
EXPECTED_GATE_FLOOR=45
test_case "corpus_probe_enumerates_a_plausible_number_of_gates" \
    "a broken glob must not make the whole-corpus probe pass over nothing"
if [[ "${#ALL_GATES[@]}" -lt "$EXPECTED_GATE_FLOOR" ]]; then
    _record_fail "enumerated only ${#ALL_GATES[@]} gate(s) under scripts/check-*.sh (floor $EXPECTED_GATE_FLOOR) — the probe would assert over an empty population. This is a refusal, not a pass."
else
    _record_pass "enumerated ${#ALL_GATES[@]} gate(s) to starve"
fi

open_gates=""
trace_gates=""
for g in "${ALL_GATES[@]}"; do
    starve_copy "$g"
    if [[ "$STARVED_OUT" == *"Traceback (most recent call last)"* ]]; then
        trace_gates="$trace_gates $g"
    elif [[ "$STARVED_RC" -eq 0 ]]; then
        open_gates="$open_gates $g"
    fi
done

test_case "no_gate_fails_open_over_a_starved_population" \
    "every gate exits non-zero when it has nothing to inspect"
if [[ -n "${open_gates// /}" ]]; then
    _record_fail "these gate(s) exited 0 over a starved tree — a fail-open defect:$open_gates. A gate whose population is empty must refuse, not pass; give it an anti-vacuity floor (see scripts/check-gate-floors.sh)."
else
    _record_pass "no gate passed over nothing"
fi

test_case "the_traceback_set_is_exactly_the_documented_thirteen" \
    "a new accidental traceback — or a gate that adopted a clean refusal — must update the list"
NEW_TRACE="$(comm -13 <(sorted_unique "$EXPECTED_TRACEBACK") <(sorted_unique "$trace_gates") | tr '\n' ' ')"
GONE_TRACE="$(comm -23 <(sorted_unique "$EXPECTED_TRACEBACK") <(sorted_unique "$trace_gates") | tr '\n' ' ')"
if [[ -n "${NEW_TRACE// /}" ]]; then
    _record_fail "gate(s) now fail closed via an UNDOCUMENTED traceback:${NEW_TRACE% }. Give each a clean refusal, or add it to EXPECTED_TRACEBACK with the anchor it crashes on — an accidental fail-closed is one glob away from fail-open."
elif [[ -n "${GONE_TRACE// /}" ]]; then
    _record_fail "documented traceback gate(s) no longer crash:${GONE_TRACE% }. Good — they likely adopted a clean refusal; drop them from EXPECTED_TRACEBACK so the list stays honest."
else
    _record_pass "the accidental-traceback set is exactly the thirteen documented"
fi

summarise
