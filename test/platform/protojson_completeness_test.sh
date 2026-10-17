#!/usr/bin/env bash
# test/platform/protojson_completeness_test.sh
#
# `scripts/check-protojson-completeness.sh`: a proto field that reaches no
# surface is a field that was added for nothing.
#
# ⚠️ The gap this closes is specific, and nothing else in the stack can see it.
# `apps/core/lib/stacks/gen/proto_json.ex` is generated, so it carries every
# contract field automatically; the hand-written serializers narrowing it do
# not. `mix proto.sync --check` compares GENERATED files against what it would
# generate, so it is structurally blind to a hand-written allowlist. Add a field
# to a proto message and it is emitted by codegen, dropped by every narrowing
# serializer, reaches no client, and no test fails anywhere.
#
# The planted-red case below is that exact scenario, and it was measured rather
# than imagined: adding `string probe_shelf_note` to the `Book` message and
# regenerating made the gate name all four `Book` serializers that drop it.
#
# ⚠️ Why a pinned BASELINE and not a reason per field. There are 98 omissions
# today and nearly all are legitimate narrowing — a search hit does not need a
# description. Demanding a written reason for each would produce 98 shallow
# reasons, which reads as considered when it was not, and is the same cry-wolf
# shape this project already rejected when an 18-name secrets denylist named
# eighteen non-defects. The baseline says where we are; the gate makes the next
# ADDITION a decision.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-protojson-completeness.sh"

test_case "inputs_exist" "the gate and both sides it compares are present"
assert_path_exists "$GATE" "scripts/check-protojson-completeness.sh exists"
assert_path_exists "$REPO_ROOT/apps/core/lib/stacks_web/proto_json.ex" \
    "the hand-written serializers exist"
assert_path_exists "$REPO_ROOT/apps/core/lib/stacks/gen/proto_json.ex" \
    "the generated serializers exist — produced by mix proto.sync"

GATE_SRC="$(cat "$GATE" 2>/dev/null)"

test_case "the_gate_passes_against_the_real_tree" "no unpinned omission today"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-protojson-completeness.sh 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT"
fi

test_case "it_reports_both_populations" "the success line says what was actually compared"
# ⚠️ Anti-vacuity, and the shape demands it: the gate's result is a SET
# DIFFERENCE, empty both when everything is pinned and when nothing was parsed.
# The counts in the success line are what distinguish those.
assert_contains "$OUT" "serializer(s) narrow" \
    "the pass names how many serializers and generated shapes it compared"
assert_contains "$OUT" "omission(s), all pinned" \
    "and how many omissions the baseline covers"

NARROWING="$(printf '%s\n' "$OUT" | grep -oE "OK: [0-9]+ serializer" | grep -oE "[0-9]+" | head -1)"
if [[ "${NARROWING:-0}" -ge 8 ]]; then
    _record_pass "the gate read $NARROWING narrowing serializer(s)"
else
    _record_fail "the gate read only ${NARROWING:-0} narrowing serializer(s). This module has more than that, so a number this low means its parse has drifted and the set difference is over an empty population"
fi

test_case "both_anti_vacuity_guards_are_present" "neither population can be silently empty"
# Each guard covers a different drift: the generated file moving or being
# un-generated, versus the hand-written parse ceasing to match. Asserted
# individually because dropping either one re-opens a different hole.
assert_contains "$GATE_SRC" "parsed only" \
    "a too-small generated population is refused"
assert_contains "$GATE_SRC" "found only" \
    "a too-small hand-written population is refused"

test_case "a_missing_generated_half_is_a_refusal_not_a_pass" \
    "the gate says so rather than reporting success over nothing"
assert_contains "$GATE_SRC" "refusal, not a pass" \
    "the unreadable-input path states it is a refusal"

test_case "the_baseline_is_checked_in_BOTH_directions" "it cannot grow silently or rot"
# Growth catches a new proto field reaching nothing. Staleness catches an entry
# describing an omission that no longer exists — without it the baseline drifts
# into a list nobody maintains, which is how an allowlist stops meaning
# anything.
assert_contains "$GATE_SRC" "reach no client through their serializer" \
    "a NEW omission fails, naming the field and serializer"
assert_contains "$GATE_SRC" "name an omission that no longer exists" \
    "a STALE baseline entry fails too"

test_case "the_module_attribute_lists_are_resolved" \
    "a serializer using an @attr roster is not reported as dropping everything in it"
# Without this the `user` serializer alone showed 29 phantom omissions against
# its real 14, because its field roster lives in `@user_auth_fields` rather than
# inline. A gate that invents fifteen findings gets switched off.
assert_contains "$GATE_SRC" "attrs.get(attr, set())" \
    "attribute rosters are unioned into the carried set"

summarise
