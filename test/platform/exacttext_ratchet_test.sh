#!/usr/bin/env bash
#
# exacttext_ratchet_test.sh — planted-violation coverage for check-exacttext-ratchet.sh.
#
# The gate is a two-directional ratchet on the count of Selector.text copy matches: it
# fails ABOVE the recorded max (a regression) and BELOW it (ground gained, left
# unrecorded). Both arms are exercised here against a mktemp copy of frontend/tests, so a
# planted match never touches the real tree. The real gate is run with EXACTTEXT_ROOT /
# EXACTTEXT_MAX; capture-then-match, never `gate | grep` (pipefail would misread the arm).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$REPO_ROOT/scripts/check-exacttext-ratchet.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$REPO_ROOT/frontend/tests" "$WORK/tests"
mkdir -p "$WORK/empty"

run() { EXACTTEXT_ROOT="$1" EXACTTEXT_MAX="$2" bash "$GATE" 2>&1; }

assert_path_exists "$GATE" "scripts/check-exacttext-ratchet.sh exists"

# The real count of the copy: run against max 0 and read it off the FAIL line.
BASE="$(run "$WORK/tests" 0 | sed -nE 's/^FAIL: ([0-9]+) Selector.*/\1/p' | head -1)"

test_case "clean_copy_at_ratchet_passes" "a tree sitting exactly at the ratchet is green"
OUT="$(run "$WORK/tests" "$BASE")"; RC=$?
assert_exit_zero "$RC" "the copy at its own count passes"
assert_contains "$OUT" "at the ratchet" "and says so"

test_case "a_real_planted_match_fails" "an added Selector.text is seen and refused"
printf 'module Planted exposing (x)\nx = Selector.text "planted copy"\n' > "$WORK/tests/Planted.elm"
OUT="$(run "$WORK/tests" "$BASE")"; RC=$?
rm -f "$WORK/tests/Planted.elm"
assert_exit_nonzero "$RC" "count $((BASE + 1)) above the ratchet $BASE fails"
assert_contains "$OUT" "above the ratchet" "the rise arm fired"

test_case "a_commented_match_is_not_counted" "Selector.text inside a comment does not count"
printf 'module Planted exposing (x)\n-- x = Selector.text "commented"\nx = 1\n' > "$WORK/tests/Planted.elm"
OUT="$(run "$WORK/tests" "$BASE")"; RC=$?
rm -f "$WORK/tests/Planted.elm"
assert_exit_zero "$RC" "a commented match leaves the count at the ratchet"

test_case "an_unrecorded_drop_fails" "a count below the recorded max is refused"
OUT="$(run "$WORK/tests" "$((BASE + 1))")"; RC=$?
assert_exit_nonzero "$RC" "count $BASE below the ratchet $((BASE + 1)) fails"
assert_contains "$OUT" "left unrecorded" "the drop arm fired"

test_case "no_test_files_fails_closed" "an empty corpus is refused, not read as perfect"
OUT="$(run "$WORK/empty" "$BASE")"; RC=$?
assert_exit_nonzero "$RC" "a tree with no test files fails closed"
assert_contains "$OUT" "found no Elm test files" "and says why"

summarise
