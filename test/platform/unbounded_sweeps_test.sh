#!/usr/bin/env bash
# test/platform/unbounded_sweeps_test.sh
#
# `scripts/check-unbounded-sweeps.sh`: a retention sweep whose cost grows with
# how long it has been failing cannot keep a retention promise.
#
# ⚠️ The defect this gate ends was measured, not imagined.
# `cleanup_expired_images/0` loaded every expired row with a bare `Repo.all()`,
# then deleted that many storage objects and emitted that many events. On
# production that was 6,655 rows in one run on a machine that suspends when idle.
#
# ⛔ The shape is a RATCHET, which is why it deserves a gate rather than a
# review note: the run cannot finish before the machine goes away, nothing
# rescues the interrupted job, and the next run faces a bigger backlog. Failing
# made it less able to recover, and the oldest unpurged image was 151 days past
# its expiry before anybody noticed.
#
# ⚠️ No baseline, and that is a deliberate contrast with the serializer-omission
# gate. There, 98 pinned entries are legitimate narrowing and a reason per field
# would be 98 shallow reasons. Here every instance is a latent outage, so there
# is no benign population to pin — the gate holds at zero and all three real
# instances were fixed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-unbounded-sweeps.sh"

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-unbounded-sweeps.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

GATE_SRC="$(cat "$GATE" 2>/dev/null)"

test_case "it_passes_against_the_real_tree" "all three known instances are fixed"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-unbounded-sweeps.sh 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT"
fi

test_case "it_reports_the_population_it_checked" "the pass is not silent about scope"
# ⚠️ Anti-vacuity, and the shape demands it: the verdict is a list of offenders,
# empty both when the code is correct and when nothing was scanned.
assert_contains "$OUT" "sweep-shaped function(s) checked" \
    "the pass says how many sweep-shaped functions it examined"

SEEN="$(printf '%s\n' "$OUT" | grep -oE "OK: [0-9]+" | grep -oE "[0-9]+" | head -1)"
if [[ "${SEEN:-0}" -ge 8 ]]; then
    _record_pass "it matched $SEEN sweep-shaped function(s)"
else
    _record_fail "it matched only ${SEEN:-0}. There are at least 8 across accounts, consent, export delivery and image retention, so a lower number means the name pattern has drifted and the scan is looking at almost nothing"
fi

test_case "private_functions_are_in_scope" "the private half is not the safe half"
# Matching only `def` found 4 of the 8 that exist and tripped the gate's own
# floor. `reap_abandoned_signups` and `maybe_purge_on_revoke` are both private
# and both do real work.
assert_contains "$GATE_SRC" 'defp?' "the pattern matches defp as well as def"

test_case "both_anti_vacuity_guards_are_present" "neither population can be silently empty"
assert_contains "$GATE_SRC" "scanned only" "a too-small file corpus is refused"
assert_contains "$GATE_SRC" "matched only" "a too-small sweep population is refused"

test_case "the_failure_explains_the_ratchet" "a reader learns why it matters, not just that it fired"
assert_contains "$GATE_SRC" "ratchet" "the failure names the compounding behaviour"
assert_contains "$GATE_SRC" "set-at-a-time" \
    "and offers the alternative fix, not just the limit"

test_case "there_is_a_reviewed_escape_hatch" \
    "a provably-bounded sweep can say so rather than contorting its query"
# Without one, the only ways out of a false positive are a pointless `limit` or
# deleting the gate — and the second is what actually happens.
assert_contains "$GATE_SRC" "BOUNDED SWEEP:" "an explicit marker exempts a reviewed case"

test_case "the_gate_is_wired_into_the_lane_that_runs_the_gates" "it is not an orphan"
# A gate nothing invokes is the defect class this project keeps finding. The
# Elixir lint lane is what runs the other nine.
LANE="$(cat "$REPO_ROOT/scripts/lint-elixir.sh" 2>/dev/null)"
assert_contains "$LANE" "gate check-unbounded-sweeps.sh" \
    "scripts/lint-elixir.sh invokes it"

summarise
