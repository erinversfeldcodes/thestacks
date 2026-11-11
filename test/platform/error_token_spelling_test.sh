#!/usr/bin/env bash
# test/platform/error_token_spelling_test.sh
#
# `scripts/check-error-token-spelling.sh`: the wire's `error:` value is an
# identifier, and an identifier with two spellings is one the next client will
# get wrong.
#
# ⛔ Measured before the gate existed: 16 sites spelled it `"not found"` and 25
# spelled it `"not_found"` — twice in the same file. No live mismatch, because
# the one client that switches on the token happened to call routes using the
# underscore form. Latent, held by nothing but which routes that client called.
#
# ⚖️ The owner's rule (2026-10-20): `not found` in user-facing messages,
# `not_found` in code and internal systems. The gate enforces the decidable
# half — no token spelled two ways — and deliberately does not judge whether a
# human-readable sentence in an `error:` field should be a token at all.
#
# Driven against FIXTURE trees, so the suite neither depends on nor disturbs the
# repository's own vocabulary.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-error-token-spelling.sh"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The gate refuses a harvest below its parse-drift floor, so every fixture
# carries filler tokens and each case below is about its own rule.
FILLER_COUNT=70

build_fixture() {
    local extra="$1" dir="$WORK/t$RANDOM$RANDOM"
    mkdir -p "$dir/apps/core/lib/stacks_web/controllers"
    {
        echo 'defmodule StacksWeb.FixtureController do'
        for i in $(seq 1 "$FILLER_COUNT"); do
            echo "  def a${i}(conn, _), do: json(conn, %{error: \"filler_${i}\"})"
        done
        printf '%s\n' "$extra"
        echo 'end'
    } > "$dir/apps/core/lib/stacks_web/controllers/fixture_controller.ex"
    printf '%s' "$dir"
}

run_gate() {
    (cd "$1" && bash "$GATE" 2>&1)
}

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-error-token-spelling.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the repository's own vocabulary is consistent"
OUT_REAL="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC_REAL=$?
if [[ "$RC_REAL" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT_REAL"
fi

SEEN="$(printf '%s\n' "$OUT_REAL" | grep -oE "OK: [0-9]+ error token" | grep -oE "[0-9]+" | head -1)"
if [[ "${SEEN:-0}" -ge 100 ]]; then
    _record_pass "it harvested $SEEN distinct tokens from the real tree"
else
    _record_fail "it harvested only ${SEEN:-0} tokens. This codebase has well over a hundred, so a number this low means the harvest no longer matches how responses are written and the no-drift verdict covers almost nothing"
fi

test_case "the_space_form_FAILS" "the defect class, planted"
# The 17th site: one space-form spelling beside the underscore form it drifts
# from. This is the shape the gate exists to catch.
DIR="$(build_fixture '  def one(conn, _), do: json(conn, %{error: "not_found"})
  def two(conn, _), do: json(conn, %{error: "not found"})')"
OUT="$(run_gate "$DIR")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "a token spelled two ways fails the gate (exit $RC)"
else
    _record_fail "two spellings of one token PASSED: $OUT"
fi
assert_contains "$OUT" "not_found" "and the failure names the canonical token"
assert_contains "$OUT" "fixture_controller.ex" "and names the file to fix"

test_case "one_spelling_PASSES" "anti-vacuity for the case above"
# Without this, the failure above would be satisfied by a gate that rejects
# every tree it is pointed at.
DIR="$(build_fixture '  def one(conn, _), do: json(conn, %{error: "not_found"})
  def two(conn, _), do: json(conn, %{error: "not_found"})')"
OUT_OK="$(run_gate "$DIR")"
RC_OK=$?
if [[ "$RC_OK" -eq 0 ]]; then
    _record_pass "one spelling used twice passes (exit 0)"
else
    _record_fail "a consistent vocabulary was rejected, so the failure above proves nothing: $OUT_OK"
fi

test_case "case_differences_are_the_same_drift" "capitalisation is a spelling too"
# ⚠️ `Bookshelf not found` and `bookshelf not found` both existed, differing
# only in case. A comparison that ignored case would have called them one
# token and missed the pair; one that ignored only separators would have
# missed it too. Both are normalised.
DIR="$(build_fixture '  def one(conn, _), do: json(conn, %{error: "reader_not_found"})
  def two(conn, _), do: json(conn, %{error: "Reader Not Found"})')"
OUT_CASE="$(run_gate "$DIR")"
RC_CASE=$?
if [[ "$RC_CASE" -ne 0 ]]; then
    _record_pass "a case-only difference fails the gate (exit $RC_CASE)"
else
    _record_fail "two spellings differing only in case passed: $OUT_CASE"
fi

test_case "a_sentence_is_left_alone" "the gate does not judge prose"
# ⛔ The false-FAIL direction, and the reason this gate is narrow. 63 distinct
# `error:` values contain spaces and several are genuinely human-readable —
# the partner API answers "The provided email address is not valid." Demanding
# snake_case everywhere would turn this into a gate that fails on correct code,
# which is how a gate gets suppressed. Whether those should become
# token-plus-message is a contract change, tracked elsewhere.
DIR="$(build_fixture '  def one(conn, _), do: json(conn, %{error: "The provided email address is not valid."})
  def two(conn, _), do: json(conn, %{error: "Unable to process opt-out request."})')"
OUT_PROSE="$(run_gate "$DIR")"
RC_PROSE=$?
if [[ "$RC_PROSE" -eq 0 ]]; then
    _record_pass "sentences with no competing spelling pass (exit 0)"
else
    _record_fail "a human-readable message was failed for not being snake_case, which makes the gate fail on correct code: $OUT_PROSE"
fi

test_case "an_interpolated_value_is_SKIPPED_and_counted" "no invented vocabulary"
# An interpolated value has no fixed spelling to compare, so normalising its
# literal fragments would invent a token no client ever receives. Skipped — and
# the count is reported, so the skip is visible rather than silent.
DIR="$(build_fixture '  def one(conn, _), do: json(conn, %{error: "Forbidden — #{role} role required"})')"
OUT_INTERP="$(run_gate "$DIR")"
RC_INTERP=$?
if [[ "$RC_INTERP" -eq 0 ]]; then
    _record_pass "an interpolated value does not fail the gate (exit 0)"
else
    _record_fail "an interpolated value was harvested as a token: $OUT_INTERP"
fi
assert_contains "$OUT_INTERP" "1 interpolated value(s) skipped" \
    "and the number skipped is reported rather than hidden"

test_case "a_tiny_harvest_FAILS" "the parse-drift alarm"
# ⛔ The verdict is "no token has two spellings", which is true when the code is
# consistent AND when nothing was harvested.
DIR="$WORK/tiny"
mkdir -p "$DIR/apps/core/lib/stacks_web/controllers"
cat > "$DIR/apps/core/lib/stacks_web/controllers/fixture_controller.ex" <<'ELIXIR'
defmodule StacksWeb.FixtureController do
  def one(conn, _), do: json(conn, %{error: "not_found"})
end
ELIXIR
OUT_TINY="$(run_gate "$DIR")"
RC_TINY=$?
if [[ "$RC_TINY" -ne 0 ]]; then
    _record_pass "a harvest below the floor fails the gate (exit $RC_TINY)"
else
    _record_fail "one token was accepted as the whole vocabulary — a drifted harvest would report clean: $OUT_TINY"
fi
assert_contains "$OUT_TINY" "harvested only" \
    "and the failure says the harvest is suspect, not that the code is wrong"

test_case "the_ruling_and_its_limit_are_recorded" "where the next reader will look"
assert_contains "$GATE_SRC" "in user-facing messages" \
    "the gate states the rule it enforces"
assert_contains "$GATE_SRC" "gate does not touch it" \
    "and states what it deliberately leaves alone"

summarise
