#!/usr/bin/env bash
# test/platform/one_credential_derivation_test.sh
#
# `scripts/check-one-credential-derivation.sh` — the credential is spelled in
# exactly one place, and that stays true.
#
# ⛔ WHY THE GATE EXISTS, because it decides what these cases have to prove.
# 71 inline `Authorization` derivations were collapsed onto one builder, and the
# evidence was a COUNT: 71 → 0, per batch, monotonic. **A count is a fact about
# the past.** Nothing stopped a 72nd, and the one gate that would have seen it —
# `check-session-expiry-coverage.sh` — had been taught to ACCEPT the inline form
# for the duration of the migration, so a new inline site would have classified
# as a correctly-authenticated endpoint with every gate green.
#
# ⚠️ So the case that matters is NOT "does it pass on a clean tree". It is "does
# it refuse a newly-introduced spelling", and separately "does it refuse when it
# cannot find the one place that is allowed to spell it" — because a gate that
# silently loses its permitted region reports the builder itself, and a gate
# that silently loses its corpus reports nothing at all.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-one-credential-derivation.sh"
LINT_ELM="$REPO_ROOT/scripts/lint-elm.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

SANDBOX=""
cleanup() { [[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# The gate takes its corpus root as an argument, so a sandbox is a directory of
# Elm files rather than a whole fake repository.
#
# ⚠️ Every sandbox needs enough files to clear the gate's own floor, which is why
# `filler` exists: without it each case below would fail on the floor instead of
# on the thing it asserts, and would look like it was passing for the right
# reason when the gate was broken.
new_sandbox() {
    cleanup
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/src/Page"

    cat > "$SANDBOX/src/Api.elm" <<'ELM'
module Api exposing (requestHeaders)


requestHeaders : Destination -> Credential -> List ( String, String )
requestHeaders destination credential =
    case destination of
        CrossOrigin ->
            []

        SameOrigin ->
            case credential of
                Session token ->
                    [ ( "Authorization", "Bearer " ++ token ) ]

                NoCredential ->
                    []


somethingElse : String
somethingElse =
    "not the builder"
ELM

    local i
    for ((i = 0; i < 90; i++)); do
        printf 'module Page.Filler%d exposing (view)\n\n\nview : String\nview =\n    "hi"\n' \
            "$i" > "$SANDBOX/src/Page/Filler$i.elm"
    done
}

run_gate() {
    OUT="$(bash "$GATE" "$SANDBOX/src" 2>&1)"
    RC=$?
}

test_case "gate_exists" "the script both callers invoke is present"
assert_path_exists "$GATE" "scripts/check-one-credential-derivation.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below exercises the real thing"
fi

# ── the clean baseline, so a refusal below carries information ───────────────
test_case "one_spelling_inside_the_builder_passes" \
    "the green half — without it every refusal below could be satisfied by the fixture"
new_sandbox
run_gate
assert_exit_zero "$RC" "a corpus whose only spelling is inside the builder is clean"
assert_contains "$OUT" "spelled in 1 place(s)" "and it reports how many spellings it permitted"
assert_contains "$OUT" "91 Elm file(s) scanned" "and the population it read"

# ── THE CASE THE GATE EXISTS FOR: a 72nd derivation appears ─────────────────
test_case "a_new_inline_derivation_in_a_page_is_refused" \
    "the count reached zero; this is what keeps it there"
new_sandbox
cat >> "$SANDBOX/src/Page/Filler0.elm" <<'ELM'


ownHeaders : String -> List Http.Header
ownHeaders token =
    [ Http.header "Authorization" ("Bearer " ++ token) ]
ELM
run_gate
assert_exit_nonzero "$RC" "the new derivation is refused"
assert_contains "$OUT" "Filler0.elm" "the refusal names the file"
assert_contains "$OUT" "spell the credential" "and the condition"
assert_contains "$OUT" "silently exempt" \
    "and says why it matters — the CSRF token lives in the builder"

# ⚠️ Both spellings, separately. Collapsing them would let the other through: a
# derivation can name the header without the scheme literal (`Http.header
# "Authorization" value`) or the scheme without `Http.header` (building a pair).
test_case "the_scheme_literal_alone_is_refused" \
    "a pair-building derivation never calls Http.header"
new_sandbox
cat >> "$SANDBOX/src/Page/Filler1.elm" <<'ELM'


ownPair : String -> ( String, String )
ownPair token =
    ( "Authorization", "Bearer " ++ token )
ELM
run_gate
assert_exit_nonzero "$RC" "the scheme literal is refused on its own"
assert_contains "$OUT" "scheme literal" "the refusal says which spelling it found"

test_case "the_header_name_call_alone_is_refused" \
    "and a derivation that takes its value from a variable spells no scheme"
new_sandbox
cat >> "$SANDBOX/src/Page/Filler2.elm" <<'ELM'


ownNamed : String -> List Http.Header
ownNamed value =
    [ Http.header "Authorization" value ]
ELM
run_gate
assert_exit_nonzero "$RC" "the header-name call is refused on its own"
assert_contains "$OUT" 'Http.header "Authorization"' "the refusal says which spelling it found"

# ── a comment is not a derivation ───────────────────────────────────────────
#
# ⛔ THIS REPOSITORY'S MOST-RECORDED GATE FAILURE: a gate reading its own subject
# matter as configuration. A sibling gate matched its keyword inside the comment
# explaining why the code beside it was correct, and reported that code as the
# violation. Any file discussing this rule contains its keywords as prose —
# `Api.elm`'s builder docs do, and so does the gate's own header.
test_case "a_line_comment_mentioning_the_credential_is_not_a_derivation" \
    "the text explaining the rule must not trip it"
new_sandbox
cat >> "$SANDBOX/src/Page/Filler3.elm" <<'ELM'


-- Never write Http.header "Authorization" ("Bearer " ++ token) here; call
-- Api.httpHeaders instead, so the CSRF token comes with it.


note : String
note =
    "see above"
ELM
run_gate
assert_exit_zero "$RC" "a comment about the rule is not a violation of it"

test_case "a_block_comment_mentioning_the_credential_is_also_stripped" \
    "Elm has two comment forms and stripping one leaves the other open"
new_sandbox
cat >> "$SANDBOX/src/Page/Filler4.elm" <<'ELM'


{- Do not build [ Http.header "Authorization" ("Bearer " ++ token) ] by hand. -}


note : String
note =
    "see above"
ELM
run_gate
assert_exit_zero "$RC" "a block comment is stripped too"

# ── the floor is on FILES SCANNED, not on findings ──────────────────────────
#
# ⚠️ "I found one derivation" and "I could not look" are the same output unless
# the floor is on what was READ.
test_case "a_corpus_below_the_floor_is_refused_even_though_it_is_clean" \
    "a findings floor is satisfied by almost-total corpus loss"
new_sandbox
rm -f "$SANDBOX/src/Page/"Filler*.elm
run_gate
assert_exit_nonzero "$RC" "two files is not a cleared frontend, whatever the findings say"
assert_contains "$OUT" "scanned only" "the refusal quotes what it read"
assert_contains "$OUT" "walk having drifted" "and names the cause it cannot otherwise distinguish"

test_case "the_sub_floor_corpus_contained_no_violations" \
    "so the refusal above is about the population, not about a finding"
assert_not_contains "$OUT" "spell the credential" \
    "nothing in the small corpus is a violation — the floor is what refused it"

# ── and the permitted REGION has its own anti-vacuity ───────────────────────
#
# ⛔ Two ways this gate could pass while meaning nothing, and neither is covered
# by the corpus floor:
#
#   1. the builder is renamed  -> the permitted region vanishes, and every
#      legitimate spelling inside it becomes a violation. Loud, but for the
#      wrong reason, so the gate must say what actually happened.
#   2. the builder stops spelling the credential at all -> the gate passes over a
#      frontend that cannot authenticate. **Silent**, and the dangerous one.
test_case "a_missing_builder_is_a_refusal_naming_the_cause" \
    "a gate that loses its permitted region reports the builder itself"
new_sandbox
python3 - "$SANDBOX/src/Api.elm" <<'RENAME'
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text(encoding="utf-8").replace("requestHeaders", "buildHeaders"), "utf-8")
RENAME
run_gate
assert_exit_nonzero "$RC" "a renamed builder refuses rather than flagging itself"
assert_contains "$OUT" "could not find" "the refusal names what it could not locate"
assert_contains "$OUT" "Renamed?" "and tells the reader what to do about it"

test_case "a_builder_that_spells_nothing_is_a_refusal" \
    "otherwise green means nobody sends a credential anywhere"
new_sandbox
python3 - "$SANDBOX/src/Api.elm" <<'BLANK'
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
p.write_text(text.replace('[ ( "Authorization", "Bearer " ++ token ) ]', "[]"), encoding="utf-8")
BLANK
run_gate
assert_exit_nonzero "$RC" "a builder that attaches no credential is not a pass"
assert_contains "$OUT" "does not spell the credential at all" "the refusal names the condition"

# ———————————————————————— callers ————————————————————————
# A gate nothing invokes is not a gate. This project has shipped one.

test_case "caller_lint" "the local lint runner invokes the gate"
if [[ -f "$LINT_ELM" ]]; then
    assert_contains "$(cat "$LINT_ELM")" "check-one-credential-derivation.sh" \
        "lint-elm.sh runs the gate, so it fires before CI does"
else
    _record_fail "lint-elm.sh not found at $LINT_ELM"
fi

test_case "caller_ci" "CI invokes the gate"
if [[ -f "$CI_YML" ]]; then
    assert_contains "$(cat "$CI_YML")" "lint-elm.sh" \
        "ci.yml runs lint-elm.sh, which runs this gate"
else
    _record_fail "ci.yml not found at $CI_YML"
fi

# ———————————————————————— the real tree ————————————————————————

test_case "the_real_frontend_has_one_derivation" "the invariant holds as the tree stands"
OUT="$(cd "$REPO_ROOT" && bash "$GATE" 2>&1)"
RC=$?
assert_exit_zero "$RC" "the gate passes over frontend/src"
assert_contains "$OUT" "all inside" "and says where the spellings it permitted live"

summarise
