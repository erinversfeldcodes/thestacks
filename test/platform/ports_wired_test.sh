#!/usr/bin/env bash
# test/platform/ports_wired_test.sh
#
# `scripts/check-ports-wired.sh`: an Elm `Cmd` port with no JavaScript
# subscriber is a message the app sends into nothing.
#
# ⛔ This suite exists because the gate could not go red on the defect class its
# own header claims to close. A platform review demonstrated two ways:
#
#   * it read COMMENTS as code, on both sides — a `//`-commented
#     `app.ports.X.subscribe(...)` satisfied the outbound rule, so commenting a
#     wiring block out while debugging shipped a dropped Cmd behind a green gate;
#   * it was blind to the GUARD that decides whether the wiring runs. All 17
#     wiring blocks in `app.js` are `if (app.ports && app.ports.X) { ... }`, and
#     the gate harvested only `.subscribe`/`.send`. A one-character typo in the
#     guard left the gate green while the subscribe never executed.
#
# Both are fixed; this is what keeps them fixed. Each case below is driven
# against a FIXTURE tree rather than the real one, so the suite neither depends
# on nor disturbs the repository's actual wiring.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-ports-wired.sh"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-ports-wired.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the repository's own wiring is complete"
OUT="$(cd "$REPO_ROOT" && bash scripts/check-ports-wired.sh 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT"
fi
assert_contains "$OUT" "ports, every Cmd subscribed" \
    "the pass names how many ports it checked"

PORTS_SEEN="$(printf '%s\n' "$OUT" | grep -oE "OK — [0-9]+ ports" | grep -oE "[0-9]+" | head -1)"
if [[ "${PORTS_SEEN:-0}" -ge 15 ]]; then
    _record_pass "it harvested $PORTS_SEEN ports"
else
    _record_fail "it harvested only ${PORTS_SEEN:-0} ports. This app declares more than that, so a number this low means the Elm parse has drifted and every rule below is being checked over almost nothing"
fi

test_case "both_sides_strip_comments" "commented-out code is not wiring"
# Source assertions, because the behavioural demonstration needs a fixture tree
# and the two helpers are the thing that must not be removed.
assert_contains "$GATE_SRC" "_strip_js_comments" "the JS harvest strips comments"
assert_contains "$GATE_SRC" "_strip_elm_comments" "the Elm harvest strips comments"
assert_contains "$GATE_SRC" "COMMENTS ARE NOT CODE" \
    "and the reason is recorded where someone would otherwise remove it"

test_case "the_guard_expression_is_harvested" \
    "the reference that decides whether wiring runs is read"
# ⛔ The narrower version of this gate harvested only `.subscribe` and `.send`.
# A guard naming a port that does not exist was invisible, which is the live
# half of the review's finding.
assert_contains "$GATE_SRC" 'app\.ports\.([A-Za-z0-9_]+)"' \
    "a bare app.ports.<name> reference is collected into js_refs"
assert_contains "$GATE_SRC" "17 wiring blocks" \
    "the guard count is recorded, so a reader can check it against app.js"

GUARDS="$(grep -cE "if \(app\.ports && app\.ports\." "$REPO_ROOT/apps/core/assets/js/app.js" 2>/dev/null || echo 0)"
if [[ "${GUARDS:-0}" -ge 1 ]]; then
    _record_pass "app.js really does guard its wiring ($GUARDS blocks), so this case is not hypothetical"
else
    _record_fail "no `if (app.ports && app.ports.X)` guards found in app.js. If the wiring style has changed, the assertion above guards nothing — retire it deliberately rather than leaving it to pass over an empty case"
fi

test_case "a_commented_subscribe_FAILS" "driven against a fixture, not asserted from source"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/frontend/src" "$WORK/apps/core/assets/js"

cat > "$WORK/frontend/src/Main.elm" <<'ELM'
port module Main exposing (main)


{-| port round-trip prose that must NOT be harvested as a declaration
-}
port saveThing : String -> Cmd msg


port gotThing : (String -> msg) -> Sub msg
ELM

cat > "$WORK/apps/core/assets/js/app.js" <<'JS'
if (app.ports && app.ports.saveThing) {
  // app.ports.saveThing.subscribe(function () {});
}
app.ports.gotThing.send("x");
JS

OUT_C="$(cd "$WORK" && bash "$GATE" 2>&1)"
RC_C=$?
if [[ "$RC_C" -ne 0 ]]; then
    _record_pass "a commented-out subscribe fails the gate (exit $RC_C)"
else
    _record_fail "a commented-out subscribe PASSED — the gate is reading comments as wiring again: $OUT_C"
fi
assert_contains "$OUT_C" "saveThing" "and the failure names the unsubscribed port"

test_case "a_doc_comment_beginning_with_port_is_not_a_declaration" \
    "the false-FAIL direction"
# Three real doc-comment lines in this repository begin with the word `port`.
# Before the Elm strip, one of them gaining a colon turned the gate red on prose
# — and an unreadable signature is fail-closed, so that was a hard stop.
assert_not_contains "$OUT_C" "round-trip" \
    "prose beginning with 'port' is not harvested as a port"

test_case "a_typod_guard_FAILS" "the live half of the review's finding"
cat > "$WORK/apps/core/assets/js/app.js" <<'JS'
if (app.ports && app.ports.saveThingg) {
  app.ports.saveThing.subscribe(function () {});
}
app.ports.gotThing.send("x");
JS

OUT_G="$(cd "$WORK" && bash "$GATE" 2>&1)"
RC_G=$?
if [[ "$RC_G" -ne 0 ]]; then
    _record_pass "a guard naming an undeclared port fails the gate (exit $RC_G)"
else
    _record_fail "a one-character typo in the guard PASSED. At runtime the guard is falsy, the subscribe never executes and the Cmd is dropped silently — the exact failure this gate exists to catch: $OUT_G"
fi
assert_contains "$OUT_G" "saveThingg" "and the failure names the misspelled reference"

test_case "correct_wiring_PASSES" "the gate is not simply always red"
# Anti-vacuity for the two failure cases: without this they would be satisfied
# by a gate that rejects everything.
cat > "$WORK/apps/core/assets/js/app.js" <<'JS'
if (app.ports && app.ports.saveThing) {
  app.ports.saveThing.subscribe(function () {});
}
app.ports.gotThing.send("x");
JS

OUT_OK="$(cd "$WORK" && bash "$GATE" 2>&1)"
RC_OK=$?
if [[ "$RC_OK" -eq 0 ]]; then
    _record_pass "correctly wired ports pass (exit 0)"
else
    _record_fail "correct wiring was rejected, so the two failures above prove nothing: $OUT_OK"
fi

summarise
