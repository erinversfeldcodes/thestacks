#!/usr/bin/env bash
# test/platform/decoder_coverage_test.sh
#
# `scripts/check-decoder-coverage.sh`: an `Api.elm` decoder that no test ever
# feeds JSON to is an unverified claim about the server.
#
# ⛔ The gate exists because two defects shipped in exactly that gap.
# `blockedUserDecoder` required a non-null `display_name` while the query
# selected it raw, so ONE blocked reader with no name permanently broke the only
# surface whose purpose is unblocking people; `groupMemberDecoder` had the same
# shape and had been fixed server-side earlier with no test, which is why the fix
# never travelled to its sibling. Both sat in a set of decoders nothing fed.
#
# ⚠️ And this suite exists because the FIRST derivation of that set was wrong in
# the direction that matters — it under-reported. Slicing a decoder's body from
# one decoder signature to the next swept the request helpers between them into
# the body, so a decoder referenced only by a request function appeared to be
# referenced by a tested decoder. Seven were hidden that way. The case below
# named `referenced_only_by_a_request_function` is that bug, planted.
#
# Every case is driven against a FIXTURE tree, not the repository's own, so the
# suite neither depends on nor disturbs the real coverage.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-decoder-coverage.sh"
GATE_SRC="$(cat "$GATE" 2>/dev/null)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ⚠️ The gate refuses a population below its parse-drift floor, so a fixture of
# three decoders would trip that instead of exercising the rule under test. The
# filler is generated and fed, which keeps every case below about its own rule.
FILLER_COUNT=45

# Builds a fixture tree: $1 extra Api.elm content, $2 extra test content.
build_fixture() {
    local api_extra="$1" test_extra="$2" dir="$WORK/t$RANDOM$RANDOM"
    mkdir -p "$dir/frontend/src" "$dir/frontend/tests"

    {
        echo "module Api exposing (..)"
        echo ""
        echo "import Json.Decode as Decode exposing (Decoder)"
        echo ""
        for i in $(seq 1 "$FILLER_COUNT"); do
            echo "filler${i}Decoder : Decoder String"
            echo "filler${i}Decoder ="
            echo "    Decode.field \"f${i}\" Decode.string"
            echo ""
        done
        printf '%s\n' "$api_extra"
    } > "$dir/frontend/src/Api.elm"

    {
        echo "module FillerTest exposing (suite)"
        echo ""
        echo "import Api"
        echo ""
        echo "suite ="
        for i in $(seq 1 "$FILLER_COUNT"); do
            echo "    Api.filler${i}Decoder"
        done
        printf '%s\n' "$test_extra"
    } > "$dir/frontend/tests/FillerTest.elm"

    printf '%s' "$dir"
}

run_gate() {
    (cd "$1" && bash "$GATE" 2>&1)
}

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-decoder-coverage.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

test_case "it_passes_against_the_real_tree" "the repository's own decoders are all fed"
OUT_REAL="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC_REAL=$?
if [[ "$RC_REAL" -eq 0 ]]; then
    _record_pass "the gate passes (exit 0)"
else
    _record_fail "the gate fails against the real tree: $OUT_REAL"
fi
assert_contains "$OUT_REAL" "are fed JSON by a test" \
    "the pass states what it checked rather than printing OK alone"

SEEN="$(printf '%s\n' "$OUT_REAL" | grep -oE "all [0-9]+ Api.elm" | grep -oE "[0-9]+" | head -1)"
if [[ "${SEEN:-0}" -ge 60 ]]; then
    _record_pass "it harvested $SEEN decoders from the real Api.elm"
else
    _record_fail "it harvested only ${SEEN:-0} decoders. Api.elm defines more than that, so a number this low means the signature parse has drifted and the set difference is being computed over almost nothing"
fi

test_case "an_unfed_decoder_FAILS" "the defect class, planted"
DIR="$(build_fixture '
lonelyDecoder : Decoder String
lonelyDecoder =
    Decode.field "nobody_feeds_me" Decode.string
' '')"
OUT="$(run_gate "$DIR")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "a decoder no test feeds fails the gate (exit $RC)"
else
    _record_fail "an unfed decoder PASSED: $OUT"
fi
assert_contains "$OUT" "lonelyDecoder" "and the failure names it"

test_case "a_fed_decoder_PASSES" "anti-vacuity for the case above"
# Without this, the failure above would be satisfied by a gate that rejects
# every tree it is pointed at.
DIR="$(build_fixture '
fedDecoder : Decoder String
fedDecoder =
    Decode.field "someone_feeds_me" Decode.string
' '    Api.fedDecoder
')"
OUT_OK="$(run_gate "$DIR")"
RC_OK=$?
if [[ "$RC_OK" -eq 0 ]]; then
    _record_pass "a decoder a test names passes (exit 0)"
else
    _record_fail "a fed decoder was rejected, so the failure above proves nothing: $OUT_OK"
fi

test_case "a_child_fed_through_its_parent_PASSES" "the transitive closure"
# A decoder inside a tested parent receives the same JSON — `Decode.list
# childDecoder` in a parent the test feeds IS fed. Demanding a test name every
# child would push the file toward naming decoders instead of endpoints.
DIR="$(build_fixture '
childDecoder : Decoder String
childDecoder =
    Decode.field "child" Decode.string


parentDecoder : Decoder (List String)
parentDecoder =
    Decode.field "items" (Decode.list childDecoder)
' '    Api.parentDecoder
')"
OUT_CHILD="$(run_gate "$DIR")"
RC_CHILD=$?
if [[ "$RC_CHILD" -eq 0 ]]; then
    _record_pass "a child reached only through a tested parent passes (exit 0)"
else
    _record_fail "a child fed through its parent was reported as unfed: $OUT_CHILD"
fi

test_case "referenced_only_by_a_request_function" \
    "⛔ the bug that hid seven decoders from the first derivation"
# The decoder is referenced from a request helper that sits BETWEEN it and a
# tested decoder. A body sliced decoder-to-decoder swallows that helper and the
# decoder looks reachable from the tested one; sliced to the next top-level
# binding of any kind, it is correctly reported as unfed.
DIR="$(build_fixture '
testedDecoder : Decoder String
testedDecoder =
    Decode.field "tested" Decode.string


getSomething : String -> String
getSomething token =
    expectJson hiddenDecoder token


hiddenDecoder : Decoder String
hiddenDecoder =
    Decode.field "hidden" Decode.string
' '    Api.testedDecoder
')"
OUT_HIDDEN="$(run_gate "$DIR")"
RC_HIDDEN=$?
if [[ "$RC_HIDDEN" -ne 0 ]]; then
    _record_pass "a decoder reached only from a request function is reported unfed (exit $RC_HIDDEN)"
else
    _record_fail "the decoder referenced only by a request function passed — the body slice is swallowing the helper again, which is how seven of these stayed hidden: $OUT_HIDDEN"
fi
assert_contains "$OUT_HIDDEN" "hiddenDecoder" "and the failure names it"
assert_not_contains "$OUT_HIDDEN" "testedDecoder" \
    "while the genuinely tested decoder is not named"

test_case "a_function_TAKING_a_decoder_is_not_a_decoder" "the false-FAIL direction"
# `resolveJson : Decoder a -> Http.Response String -> Result …` is not a decoder,
# and counting it as one overstated the population by two — one of which sat in
# the untested list inflating it. The exclusion is signatures containing `->`.
DIR="$(build_fixture '
resolveJson : Decoder a -> String -> Result String a
resolveJson decoder body =
    Err "stub"
' '')"
OUT_ARROW="$(run_gate "$DIR")"
RC_ARROW=$?
if [[ "$RC_ARROW" -eq 0 ]]; then
    _record_pass "a function taking a decoder is not demanded a fixture (exit 0)"
else
    _record_fail "a combinator was counted as a decoder and reported unfed: $OUT_ARROW"
fi

test_case "a_tiny_population_FAILS" "the parse-drift alarm"
# ⛔ Every verdict this gate reaches is a set difference, empty when the code is
# correct AND when nothing was parsed. The floor is what stops a drifted regex
# reporting a clean pass over an empty population.
DIR="$WORK/tiny"
mkdir -p "$DIR/frontend/src" "$DIR/frontend/tests"
cat > "$DIR/frontend/src/Api.elm" <<'ELM'
module Api exposing (..)

import Json.Decode as Decode exposing (Decoder)


oneDecoder : Decoder String
oneDecoder =
    Decode.field "one" Decode.string
ELM
cat > "$DIR/frontend/tests/T.elm" <<'ELM'
module T exposing (suite)

import Api


suite =
    Api.oneDecoder
ELM

OUT_TINY="$(run_gate "$DIR")"
RC_TINY=$?
if [[ "$RC_TINY" -ne 0 ]]; then
    _record_pass "a population below the floor fails the gate (exit $RC_TINY)"
else
    _record_fail "one decoder was accepted as the whole population — a drifted parse would report clean: $OUT_TINY"
fi
assert_contains "$OUT_TINY" "parsed only" \
    "and the failure says the parse is suspect, not that the code is wrong"

test_case "the_provenance_caveat_is_recorded" "what the gate does NOT claim"
# ⚠️ Feeding a decoder JSON proves it accepts a shape somebody wrote down, not
# that the server sends it. That limit has to be written where the next person
# reads the gate, or a green run gets read as a server-contract guarantee.
assert_contains "$GATE_SRC" "does not prove the server sends that shape" \
    "the gate states the limit of its own claim"
assert_contains "$GATE_SRC" "name it in a comment" \
    "and tells a new fixture's author to record its provenance"

summarise
