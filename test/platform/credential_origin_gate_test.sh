#!/usr/bin/env bash
# test/platform/credential_origin_gate_test.sh
#
# `scripts/check-credential-origin.sh` — a request declaring `SameOrigin` must
# have a URL the gate can prove is same-origin.
#
# ⛔ WHY THE GATE EXISTS, because it decides what these cases have to be. The
# builder's `Destination` is **declared by the caller, not derived from the
# URL**, so `requestHeaders SameOrigin (Session token)` at an external URL still
# attaches the token. The builder's own precedence defends `CrossOrigin` +
# `Session` — which nobody writes by accident — and leaves `SameOrigin` at a
# foreign URL, which is the ordinary-looking value a hurried caller reaches for.
#
# ⚠️ So the half that matters is NOT "does it reject CrossOrigin". That direction
# is already safe by construction. It is "does it reject a SameOrigin CLAIM the
# URL does not support" — and a test that only checked the first would be the
# blind spot restated as coverage.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-credential-origin.sh"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
LINT_ELM="$REPO_ROOT/scripts/lint-elm.sh"

SANDBOX=""
cleanup() { [[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ⚠️ The gate resolves `Api.elm` from its own location, so a sandbox has to
# mirror the repository shape rather than pass a path.
run_on() {
    local api_body="$1"

    cleanup
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/frontend/src" "$SANDBOX/scripts"
    cp "$GATE" "$SANDBOX/scripts/"
    printf '%s\n' "$api_body" > "$SANDBOX/frontend/src/Api.elm"

    OUT="$(cd "$SANDBOX" && bash scripts/check-credential-origin.sh 2>&1)"
    RC=$?
}

# A request record, parameterised by its url expression and headers expression.
# ⚠️ `method` and `headers` are both present in every fixture because that pair
# is what the gate uses to tell a request record from an adapter record — a
# fixture missing one would be silently skipped and the case would pass for the
# wrong reason.
record() {
    local name="$1" url="$2" headers="$3"
    cat <<EOF

$name : String -> Cmd msg
$name arg =
    Http.request
        { method = "GET"
        , headers = $headers
        , url = $url
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
EOF
}

# The gate floors on records PARSED, so every fixture needs enough records to
# clear it. This emits filler whose urls are provably same-origin.
filler() {
    local count="$1" i
    for ((i = 0; i < count; i++)); do
        record "filler$i" "baseUrl ++ \"/api/thing\"" "[]"
    done
}

test_case "gate_exists" "the script both callers invoke is present"
assert_path_exists "$GATE" "scripts/check-credential-origin.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below exercises the real thing"
fi

# ── the clean baseline, so a non-zero exit below carries information ─────────
test_case "a_provably_same_origin_corpus_passes" \
    "the green half — a baseline, or every refusal below is satisfied by the fixture"
run_on "$(filler 75)"
assert_exit_zero "$RC" "75 provably same-origin records is a clean run"
assert_contains "$OUT" "75 request record(s) parsed" "and it reports the population it read"

# ── the planted red: a SameOrigin CLAIM the url does not support ─────────────
#
# ⛔ THE CASE THE GATE EXISTS FOR. `url = someArgument` could be any origin, so
# `SameOrigin` beside it is a claim nothing checks — and that is the likely
# mistake, not the exotic one.
test_case "a_SameOrigin_claim_over_an_unprovable_url_is_refused" \
    "declared is not derived, so the claim has to be checked against the URL"
run_on "$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_nonzero "$RC" "the claim is refused"
assert_contains "$OUT" "declare SameOrigin with a URL that is not" "the refusal names the condition"
assert_contains "$OUT" "uploadToStorage" "and the function, not just a line"
assert_contains "$OUT" "DECLARED, not derived" "and says why the claim cannot be taken"

# ⚠️ The mirror: the SAME unprovable url, declaring CrossOrigin, must PASS. A
# gate that refused both would make an unprovable URL unusable rather than
# undeclared, and `putFileToR2` would have no legal form.
test_case "the_same_unprovable_url_declaring_CrossOrigin_passes" \
    "an unprovable URL is undeclared, not forbidden"
run_on "$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders CrossOrigin NoCredential |> List.map toHeader")"
assert_exit_zero "$RC" "declaring CrossOrigin is the legal form for an unprovable URL"

# ── each recognised same-origin form, driven ─────────────────────────────────
#
# ⚠️ The forms are an enumerated SYNTAX list rather than an allowlist of call
# sites, so each shape needs a case: a shape that silently stopped being
# recognised would make every request using it report as unprovable, and the
# gate would be loudly wrong rather than quietly wrong — but only if something
# drives the shape.
test_case "spec_url_is_recognised_as_same_origin" "the plan path builds its url upstream from baseUrl"
run_on "$(filler 75)$(record "viaSpec" "spec.url" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "spec.url is same-origin by construction"

test_case "absolute_path_builder_is_recognised" "an absolute PATH is our origin"
run_on "$(filler 75)$(record "viaBuilder" "Url.Builder.absolute [ \"api\", \"thing\" ] []" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "Url.Builder.absolute yields a path, not a host"

test_case "a_literal_relative_path_is_recognised" "a leading slash is our origin"
run_on "$(filler 75)$(record "viaLiteral" "\"/api/thing\"" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "a literal \"/path\" is same-origin"

# ── the floor is on RECORDS PARSED, not on findings ─────────────────────────
#
# ⛔ THE ONE THING THIS GATE DELIBERATELY DOES NOT COPY FROM ITS SIBLING.
# `check-session-expiry-coverage.sh` floors on `if not authed_endpoints` —
# emptiness — so a change taking its population from 71 to ONE passes green,
# classifying one endpoint and printing "1" as though that were the population.
#
# ⚠️ "I found no violations" and "I could not look" are the same output unless
# the floor is on what was READ. That distinction is the one five sweeps in this
# campaign failed on.
test_case "a_corpus_below_the_floor_is_refused_even_with_no_violations" \
    "a floor on findings is satisfied by almost-total parser loss"
run_on "$(filler 3)"
assert_exit_nonzero "$RC" "three records is not a cleared file, whatever the findings say"
assert_contains "$OUT" "parsed only 3 request record(s)" "the refusal quotes what it read"
assert_contains "$OUT" "parser having drifted" "and names the cause it cannot distinguish otherwise"

# ⚠️ And the discriminating half: the refusal must be about the COUNT, not about
# finding something. These three records are clean, so a findings-based floor
# would have passed them.
test_case "the_sub_floor_corpus_contains_no_violations" \
    "so the refusal above is about the population, not about a finding"
assert_not_contains "$OUT" "declare SameOrigin with a URL that is not" \
    "nothing in the small corpus is a violation — the floor is what refused it"

# ── an adapter record is not a request ──────────────────────────────────────
#
# ⚠️ A `url`-keyed scan would have counted `fromProtoDiscoveredSource`, which
# maps a record with a `url` FIELD and is not a request at all. The gate keys on
# `method` AND `headers` together, and this pins that.
test_case "a_record_with_a_url_field_but_no_method_is_not_counted" \
    "an adapter is not a request, and a url-keyed scan would have counted it"
run_on "$(filler 75)
fromProtoThing : Proto -> Thing
fromProtoThing proto =
    { id = proto.id
    , url = proto.url
    , name = proto.name
    }
"
assert_exit_zero "$RC" "the adapter does not make the corpus dirty"
assert_contains "$OUT" "75 request record(s) parsed" \
    "and it is not counted as a request — 75, not 76"

# ———————————————————————— callers ————————————————————————
# A gate nothing invokes is not a gate. This project has shipped one.

test_case "caller_lint" "the local lint runner invokes the gate"
if [[ -f "$LINT_ELM" ]]; then
    assert_contains "$(cat "$LINT_ELM")" "check-credential-origin.sh" \
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

# ⛔ A COMMENT MENTIONING THE KEYWORD IS NOT A DECLARATION — this repository's
# most-recorded gate failure, caught the first time this gate met real code.
#
# MEASURED: `putFileToR2` declares `CrossOrigin NoCredential` and carries a
# comment explaining that a `SameOrigin` claim there would attach a bearer token
# to a third-party host. The gate matched `SameOrigin` IN THAT COMMENT and
# reported the one correctly-declared cross-origin request as the violation —
# while the comment said exactly why it was not one.
#
# ⚠️ The text explaining the rule was the text that broke it. Any file
# discussing this gate contains its keywords as prose, so stripping is a
# precondition rather than a refinement.
test_case "the_keyword_in_a_comment_is_not_a_declaration" \
    "the text explaining the rule must not trip it"
run_on "$(filler 75)
putFileToStorage : String -> Cmd msg
putFileToStorage presignedUrl =
    Http.request
        { method = \"PUT\"

        -- A SameOrigin claim here would attach a bearer token to a third-party
        -- host, which is why this declares CrossOrigin instead.
        , headers = httpHeaders CrossOrigin NoCredential
        , url = presignedUrl
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" \
    "a correctly-declared cross-origin request must not be flagged by its own explanation"

# ⚠️ And a block comment too, since Elm has both forms and a line-comment-only
# strip would leave the other half open.
test_case "a_block_comment_mentioning_the_keyword_is_also_stripped" \
    "Elm has two comment forms and stripping one leaves the other"
run_on "$(filler 75)
putFileToStorage : String -> Cmd msg
putFileToStorage presignedUrl =
    Http.request
        { method = \"PUT\"
        {- SameOrigin would be wrong here -}
        , headers = httpHeaders CrossOrigin NoCredential
        , url = presignedUrl
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" "a block comment is stripped too"

summarise
