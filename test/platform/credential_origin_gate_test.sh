#!/usr/bin/env bash
# test/platform/credential_origin_gate_test.sh
#
# `scripts/check-credential-origin.sh` — a request declaring `SameOrigin` must
# have a URL the gate can prove is same-origin.
#
# ⛔ WHY THE GATE EXISTS, because it decides what these cases have to be. The
# builder's `Destination` is **declared by the caller, not derived from the
# URL**, so `requestHeaders "GET" (Session token)` at an external URL still
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

# A `RequestSpec` builder. ⚠️ These no longer clear a floor — the gate's spec
# half was retired when `RequestSpec.url` became an `Api.Url.SameOriginUrl`, so
# the compiler makes that statement now. They are kept because a fixture without
# any is unlike the real file, and a parser change that started mis-reading them
# should still show up here.
spec() {
    local name="$1" url="$2"
    cat <<EOF

$name : RequestSpec
$name =
    { method = "GET"
    , url = $url
    , body = Nothing
    }
EOF
}

spec_filler() {
    local count="$1" i
    for ((i = 0; i < count; i++)); do
        spec "fillerSpec$i" "baseUrl ++ \"/api/thing\""
    done
}

# A request record, parameterised by its url expression and headers expression.
# ⚠️ `method` and `headers` are both present in every fixture because that pair
# is what the gate uses to tell a request record from an adapter record — a
# fixture missing one would be silently skipped and the case would pass for the
# wrong reason.
# A record whose sent method and header-builder method can differ, for the
# agreement rule below.
record_with_methods() {
    local name="$1" sent="$2" told="$3"
    cat <<EOF

$name : String -> Cmd msg
$name arg =
    Http.request
        { method = "$sent"
        , headers = httpHeaders "$told" (Session token)
        , url = baseUrl ++ "/api/thing"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
EOF
}

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
run_on "$(spec_filler 32)$(filler 75)"
assert_exit_zero "$RC" "75 provably same-origin records is a clean run"
assert_contains "$OUT" "request record(s) parsed" "and it reports the population it read"

# ── the planted red: a SameOrigin CLAIM the url does not support ─────────────
#
# ⛔ THE CASE THE GATE EXISTS FOR. `url = someArgument` could be any origin, so
# `SameOrigin` beside it is a claim nothing checks — and that is the likely
# mistake, not the exotic one.
test_case "a_SameOrigin_claim_over_an_unprovable_url_is_refused" \
    "declared is not derived, so the claim has to be checked against the URL"
run_on "$(spec_filler 32)$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders \"GET\" (Session token) |> List.map toHeader")"
assert_exit_nonzero "$RC" "the unprovable url is refused"
assert_contains "$OUT" "cannot prove is same-origin" "the refusal names the condition"
assert_contains "$OUT" "uploadToStorage" "and the function, not just a line"
assert_contains "$OUT" "Api.Url.path" "and names the constructor that fixes it"

# ⛔ THE MIRROR CASE IS INVERTED, AND THE INVERSION IS THE POINT.
#
# This used to assert that the SAME unprovable url PASSES when it declares
# `CrossOrigin` — "an unprovable URL is undeclared, not forbidden" — because
# `putFileToR2` needed a legal form for a presigned link. That function no
# longer exists (the upload PUT was same-origin all along), `Api.Destination` is
# deleted, and there is no declaration to make. So an unprovable URL is now
# forbidden rather than merely undeclared, whatever credential it carries.
#
# ⚠️ Kept as a case rather than removed, because "there is no escape hatch" is a
# statement about the gate that something must assert. Deleting the case would
# leave the hatch's absence untested, and a future `|| exit 0` would restore it
# silently.
test_case "an_unprovable_url_has_NO_escape_hatch_any_more" \
    "there is no declaration that makes an unprovable URL acceptable"
run_on "$(spec_filler 32)$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders \"GET\" (NoCredential Nothing) |> List.map toHeader")"
assert_exit_nonzero "$RC" "an unprovable URL is refused however it is credentialed"

# ── each recognised same-origin form, driven ─────────────────────────────────
#
# ⚠️ The forms are an enumerated SYNTAX list rather than an allowlist of call
# sites, so each shape needs a case: a shape that silently stopped being
# recognised would make every request using it report as unprovable, and the
# gate would be loudly wrong rather than quietly wrong — but only if something
# drives the shape.
test_case "spec_url_is_recognised_as_same_origin" "the plan path builds its url upstream from baseUrl"
run_on "$(spec_filler 32)$(filler 75)$(record "viaSpec" "spec.url" "requestHeaders \"GET\" (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "spec.url is same-origin by construction"

# ⛔ INVERTED: `Url.Builder.absolute` IS NO LONGER A PROOF.
#
# This asserted "an absolute PATH is our origin". It is not: `absolute`
# percent-encodes query keys and values and NEVER path segments, so
# `absolute [ "/evil.test" ] []` yields `//evil.test` — a protocol-relative URL
# that leaves the origin. The gate was accepting an escapable expression as
# same-origin, and this case was pinning that acceptance in place.
test_case "absolute_path_builder_is_NOT_a_proof" \
    "Url.Builder.absolute does not encode path segments, so it can escape"
run_on "$(spec_filler 32)$(filler 75)$(record "viaBuilder" "Url.Builder.absolute [ \"api\", \"thing\" ] []" "requestHeaders \"GET\" (Session token) |> List.map toHeader")"
assert_exit_nonzero "$RC" "absolute is not accepted as same-origin any more"

# ⚖️ What replaces it: a value that came from `Api.Url.SameOriginUrl`. This is a
# proof rather than a recognised shape — the type's only constructor cannot
# build a URL that leaves our origin, and a String cannot enter the type.
test_case "a_value_from_the_same_origin_type_is_recognised" \
    "Api.Url.toString carries the type's guarantee to the Http boundary"
run_on "$(spec_filler 32)$(filler 75)$(record "viaType" "Api.Url.toString (Api.Url.path [ \"api\", \"thing\" ] [])" "requestHeaders \"GET\" (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "a SameOriginUrl is same-origin by construction"

test_case "a_literal_relative_path_is_recognised" "a leading slash is our origin"
run_on "$(spec_filler 32)$(filler 75)$(record "viaLiteral" "\"/api/thing\"" "requestHeaders \"GET\" (Session token) |> List.map toHeader")"
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
run_on "$(spec_filler 32)$(filler 3)"
assert_exit_nonzero "$RC" "a surface of 35 is not a cleared file, whatever the findings say"
assert_contains "$OUT" "request surface of only 35" "the refusal quotes the surface it measured"
assert_contains "$OUT" "32 RequestSpec(s) + 3 Http.request record(s)" \
    "and shows both halves, so a drift in either is attributable"
assert_contains "$OUT" "parser having drifted" "and names the cause it cannot distinguish otherwise"

# ⚠️ And the discriminating half: the refusal must be about the COUNT, not about
# finding something. These three records are clean, so a findings-based floor
# would have passed them.
test_case "the_sub_floor_corpus_contains_no_violations" \
    "so the refusal above is about the population, not about a finding"
assert_not_contains "$OUT" "declare SameOrigin with a URL that is not" \
    "nothing in the small corpus is a violation — the floor is what refused it"

# ── the floor counts the SURFACE, so migrating a request does not shrink it ──
#
# ⛔ THE CASE THE FLOOR CHANGE EXISTS FOR, and the one a record-count floor fails.
# The migration moves a request from an `Http.request` record to a `RequestSpec`.
# Under a floor on records, every such move lowered the population and the floor
# had to be lowered with it — which is a ratchet that only loosens.
#
# Here the same request is present in BOTH forms, as it is mid-migration: a
# `fooRequest : RequestSpec` and a `foo` wrapper that sends it. The surface must
# count that as ONE, so that deleting the wrapper leaves the total unchanged.
#
# ⚠️ THE ASSERTION IS THAT IT PASSES, and the direction matters. A corpus of ONE
# record is far below any record floor, so a refusal here would be satisfied by
# either design and would prove nothing. Only the cleared run distinguishes them:
# this file is safe because 101 specs are type-checked, and a floor counting
# `Http.request` records cannot see that.
test_case "a_record_with_a_spec_sibling_counts_once_toward_the_surface" \
    "ONE record and 101 specs is a cleared file — a record-count floor refuses it"
run_on "$(spec_filler 100)
fooRequest : RequestSpec
fooRequest =
    { method = \"GET\"
    , url = Api.Url.path [ \"api\", \"foo\" ] []
    , body = Nothing
    }


foo : Credentials -> (Result Http.Error () -> msg) -> Cmd msg
foo token toMsg =
    Http.request
        { method = \"GET\"
        , headers = httpHeaders \"GET\" (Session token)
        , url = baseUrl ++ \"/api/foo\"
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" "101 specs clears the floor, and the duplicated record neither helps nor hurts"
assert_contains "$OUT" "0 unmigrated record(s)" \
    "the wrapper counts as duplication, not surface"

# ── an adapter record is not a request ──────────────────────────────────────
#
# ⚠️ A `url`-keyed scan would have counted `fromProtoDiscoveredSource`, which
# maps a record with a `url` FIELD and is not a request at all. The gate keys on
# `method` AND `headers` together, and this pins that.
test_case "a_record_with_a_url_field_but_no_method_is_not_counted" \
    "an adapter is not a request, and a url-keyed scan would have counted it"
run_on "$(spec_filler 32)$(filler 75)
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
run_on "$(spec_filler 32)$(filler 75)
putFileToStorage : String -> Cmd msg
putFileToStorage presignedUrl =
    Http.request
        { method = \"PUT\"

        -- A credential here would be attached to whatever host this URL names,
        -- which is why the destination has to be provable rather than claimed.
        , headers = httpHeaders \"PUT\" (NoCredential Nothing)
        , url = baseUrl ++ \"/api/thing\"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" \
    "a request must not be flagged by prose that merely mentions the keyword"

# ⚠️ And a block comment too, since Elm has both forms and a line-comment-only
# strip would leave the other half open.
test_case "a_block_comment_mentioning_the_keyword_is_also_stripped" \
    "Elm has two comment forms and stripping one leaves the other"
run_on "$(spec_filler 32)$(filler 75)
putFileToStorage : String -> Cmd msg
putFileToStorage presignedUrl =
    Http.request
        { method = \"PUT\"
        {- a SameOrigin claim would have been wrong here -}
        , headers = httpHeaders \"PUT\" (NoCredential Nothing)
        , url = baseUrl ++ \"/api/thing\"
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" "a block comment is stripped too"

# ── the rules must hold BY CONSTRUCTION, not by population ──────────────────
#
# ⛔ TWO RULES HERE WERE TRUE ONLY OF TODAY'S CALL SITES, which review caught
# after the gate had already shipped and passed.
#
# The guarantee this gate rests on is POSITIONAL: once a url starts with `/x`,
# nothing appended after it can change the origin. So a rule that does not pin
# the FIRST characters proves nothing, and both of these did not.

# ⚠️ `baseUrl` is `""` in this project. So `baseUrl ++ X` is literally `X`, and
# the old rule "leads with `baseUrl`" accepted `baseUrl ++ someVariable` — a
# variable that could hold `https://evil.test/`. ONE site in `Api.elm` relied on
# exactly that shape, so the rule was not merely theoretically weak.
test_case "baseUrl_followed_by_a_variable_is_refused" \
    "baseUrl is the empty string, so it guarantees nothing on its own"
run_on "$(spec_filler 32)$(filler 75)$(record "viaVariable" "baseUrl ++ path" "httpHeaders SameOrigin (Session token)")"
assert_exit_nonzero "$RC" "a variable after baseUrl is not provably same-origin"
assert_contains "$OUT" "viaVariable" "the refusal names the function"

test_case "baseUrl_followed_by_a_literal_path_is_accepted" \
    "and the discriminating half, or the rule above would forbid the normal form"
run_on "$(spec_filler 32)$(filler 75)$(record "viaLiteralBase" "baseUrl ++ \"/api/groups/\" ++ groupId ++ \"/feed\"" "httpHeaders SameOrigin (Session token)")"
assert_exit_zero "$RC" "a literal path after baseUrl is provable, interpolation after it or not"

# ⚠️ `Url.Builder.absolute` DOES NOT ENCODE ITS PATH SEGMENTS. Its whole body is
#     absolute pathSegments params = "/" ++ String.join "/" pathSegments ++ toQuery params
# with `percentEncode` applied only to QUERY keys and values. So
# `absolute [ "/evil.test" ] []` yields `//evil.test`, a protocol-relative URL
# that leaves the origin. The gate accepted any `Url.Builder.absolute` call.
test_case "an_absolute_builder_segment_that_escapes_the_origin_is_refused" \
    "Url.Builder.absolute does not percent-encode path segments"
run_on "$(spec_filler 32)$(filler 75)$(record "viaEscape" "Url.Builder.absolute [ \"/evil.test\" ] []" "httpHeaders SameOrigin (Session token)")"
assert_exit_nonzero "$RC" "a leading-slash segment is refused"
assert_contains "$OUT" "viaEscape" "the refusal names the function"

# ── the plan path, now carried by the TYPE and not by this gate ─────────────
#
# ⛔ FOUR CASES WERE HERE AND ALL FOUR ARE GONE, because their subject moved
# from this script to the compiler. They asserted that a `RequestSpec` whose URL
# leaves our origin is refused, that the spec population has its own floor, that
# the sub-floor corpus held no violations, and that a green run reports the
# plan-path population it read.
#
# `RequestSpec.url` is now an `Api.Url.SameOriginUrl`. Its only constructor
# percent-encodes every path segment and drops the empty ones, so it cannot
# produce a URL that leaves our origin, and a `String` cannot enter the type at
# all. The question "is every spec's URL same-origin?" is therefore not a
# property of a corpus to be counted — it is the field's type, checked on every
# build, with no population floor to drift and no comment-stripping pass to get
# wrong.
#
# ⚖️ So this is a case of a guard being RETIRED rather than deleted: the
# guarantee is stronger than it was, and `frontend/tests/Api/UrlTest.elm` holds
# the escape attempts that prove the constructor keeps it — including the one
# that caught the first implementation, where an empty leading segment made
# `//evil.test` because `percentEncode ""` is `""`.
#
# ⚠️ What this gate still owns is the RECORD half below: direct `Http.request`
# sites whose `url` is a plain `String`. There are about sixty-six, they move
# onto the plan when the `Cmd msg` migration lands, and only then does this file
# have nothing left to say.

# ── the method sent and the method the builder is told ──────────────────────
#
# ⛔ THE SILENT-FAILURE SHAPE. `requestHeaders` attaches the CSRF token based on
# the method it is GIVEN; the request goes out with the method in the record's
# own field. When they disagree, a write ships with no proof and every test that
# does not read the header still passes.
#
# ⚖️ The duplication is deliberate — the alternative is 45 call sites each
# deciding whether to add the header — and this is what makes it safe.
test_case "a_record_that_sends_one_method_and_builds_for_another_is_refused" \
    "a write told the builder it was a read carries no proof, silently"
run_on "$(spec_filler 32)$(filler 75)$(record_with_methods "sneakyWrite" "POST" "GET")"
assert_exit_nonzero "$RC" "the disagreement is refused"
assert_contains "$OUT" "sneakyWrite" "the refusal names the function"
assert_contains "$OUT" "send one method and tell the header builder another" \
    "and names the condition"
assert_contains "$OUT" "no proof" "and says what the consequence is"

# ⚠️ The discriminating half: agreement must PASS, or the rule would forbid every
# request rather than the mismatched ones.
test_case "a_record_whose_methods_agree_is_accepted" \
    "otherwise the rule refuses correct code and tells us nothing"
run_on "$(spec_filler 32)$(filler 75)$(record_with_methods "honestWrite" "POST" "POST")"
assert_exit_zero "$RC" "matching methods are fine"

# ⚠️ `spec.method` on both sides is ONE expression read twice, not two statements
# that can disagree — so it must not be reported. A rule that demanded literals
# would fire on every plan-backed request in the file.
test_case "spec_method_on_both_sides_is_not_a_disagreement" \
    "one expression read twice cannot disagree with itself"
run_on "$(spec_filler 32)$(filler 75)
viaSpec : String -> Cmd msg
viaSpec arg =
    Http.request
        { method = spec.method
        , headers = httpHeaders spec.method SameOrigin (Session token)
        , url = spec.url
        , body = Http.emptyBody
        , expect = Http.expectWhatever Done
        , timeout = standardTimeout
        , tracker = Nothing
        }
"
assert_exit_zero "$RC" "spec.method on both sides is not duplication"

summarise
