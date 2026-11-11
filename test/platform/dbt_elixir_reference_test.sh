#!/usr/bin/env bash
# test/platform/dbt_elixir_reference_test.sh
#
# `check-dbt-model-drift.sh`'s Elixir-reference check: every dbt model name in
# an Elixir string literal must exist on disk.
#
# ⚠️ Why this surface needed a gate at all. **A fixture naming a deleted model
# is still a valid string**, so nothing in the stack contradicts it — not the
# compiler, not dbt, not the test itself. A dbt-refresh job test used three
# deleted models as the fixture for its argv-joining assertion and kept
# passing, correctly asserting the joining while describing a warehouse that no
# longer existed. Three deletions in a row ticked "docs propagation" after
# sweeping only `docs/`; the test-fixture surface was the one with no
# instrument.
#
# The planted-red case below is that scenario exactly, and the pair is the
# point: with a deleted model in the argv-join fixture and the joined string
# updated to match, **the job test passes 17/0 and only the gate sees it.**
#
# ⚠️ The check is narrow by MEASUREMENT, not by caution. Its first draft scanned
# raw lines and reported ten findings, every one noise:
#
#   * eight were model names in comments *documenting those models' own
#     deletion* — in the refresh handler and in the job test that now asserts
#     `refute_enqueued` for them. Flagging those would punish exactly the
#     propagation documentation the rule asks for. (The fourth time a check in
#     this repository read a comment as configuration.)
#   * `int_param(params, "limit")` is an Elixir FUNCTION — `int_` is an ordinary
#     abbreviation for integer, and a prefix match cannot tell it from a model.
#   * the proto manifest's `dbt_path` entries are, in its own words, "the path
#     the model returns to, not a claim that it exists" — a `skip_dbt: true`
#     table keeps the key because the manifest requires it.
#
# So: string literals only, comments stripped, manifest excluded. Those three
# narrowings are what make the one real finding visible.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-dbt-model-drift.sh"
JOB_TEST="$REPO_ROOT/apps/core/test/stacks/workers/dbt_refresh_job_test.exs"

test_case "inputs_exist" "the gate and the test it was written for are present"
assert_path_exists "$GATE" "scripts/check-dbt-model-drift.sh exists"
assert_path_exists "$JOB_TEST" "the dbt-refresh job test exists"

GATE_SRC="$(cat "$GATE" 2>/dev/null)"

test_case "the_check_is_wired_into_the_gate" "the Elixir-reference check is part of the drift gate"
assert_contains "$GATE_SRC" "dbt model names named in ELIXIR sources" \
    "the check is present in the gate that already has a caller"

test_case "the_three_narrowings_are_all_present" \
    "each narrowing that made the check usable is still in place"
# Asserted individually, because dropping any ONE of them re-introduces a
# different flavour of noise and a noisy gate gets deleted. Named so a future
# reader removing one knows which ten findings come back.
assert_contains "$GATE_SRC" "COMMENT = re.compile" \
    "comments are stripped — else a deletion's own documentation is reported as drift"
assert_contains "$GATE_SRC" "STRING_LITERAL = re.compile" \
    "only string literals count — else an Elixir function named int_* is reported as a model"
assert_contains "$GATE_SRC" "MANIFEST_BASENAME" \
    "the proto manifest is excluded — its dbt_path is a destination, not a claim of existence"

test_case "the_interpolation_trap_is_avoided" \
    "the comment strip does not treat an Elixir interpolation as a comment"
# `#{` opens an interpolation. A bare `#` comment strip erases the rest of the
# line, which is precisely how a sibling gate
# (`scripts/check-outbound-test-default.sh`) once failed OPEN: a module whose
# only outbound call sat after an interpolation dropped out of scope while the
# gate printed OK.
assert_contains "$GATE_SRC" '#(?!\{)' \
    "the strip pattern excludes the interpolation opener"

test_case "the_gate_passes_against_the_real_tree" "no live phantom model reference"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-dbt-model-drift.sh 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the drift gate passes (exit 0)"
else
    _record_fail "the drift gate fails against the real tree: $OUT"
fi

test_case "the_check_read_a_real_population" "the Elixir scan is not reporting a pass over nothing"
# ⚠️ Anti-vacuity, and the shape matters: the check's result is a SET
# DIFFERENCE, which is empty both when everything is correct and when the scan
# found nothing at all. The gate has its own guard for that; this asserts the
# guard's happy path reports a non-trivial count, so a silent narrowing to zero
# cannot read as success here either.
assert_contains "$OUT" "dbt model name(s) referenced from Elixir exist on disk" \
    "the check reports its population rather than only its verdict"

COUNT="$(printf '%s\n' "$OUT" | grep -oE "all [0-9]+ dbt model name\(s\) referenced" | grep -oE "[0-9]+" | head -1)"
if [[ "${COUNT:-0}" -ge 5 ]]; then
    _record_pass "the scan found $COUNT model reference(s) in Elixir string literals"
else
    _record_fail "the scan found only ${COUNT:-0} model reference(s) in Elixir — this app names models in its refresh map and its job tests, so a number this low means the scan stopped matching the source rather than that the references are gone"
fi

test_case "the_allow_marker_is_honoured_above_the_line_too" \
    "a marker on the preceding line excuses a synthetic fixture"
# The generator tests feed invented names like `stg_new_table` to a merge
# function; those are fixtures, not references. An inline marker is often the
# wrong shape because the name sits inside a long expression, so the marker
# counts on the line itself or the one directly above — the same rule
# `check-e2e-vacuous-guards.sh` uses, so the two gates read the same way.
assert_contains "$GATE_SRC" "NO_MODEL_MARKER in previous.upper()" \
    "the preceding line is checked for the marker"
assert_contains "$GATE_SRC" "NO SUCH DBT MODEL" "the marker string is declared"

summarise
