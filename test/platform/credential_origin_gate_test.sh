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

# A `RequestSpec` builder. Every fixture needs enough of these to clear the
# gate's SECOND floor — the one over the plan path — or each case below fails on
# that floor rather than on the thing it asserts.
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
        , headers = httpHeaders "$told" SameOrigin (Session token)
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
assert_contains "$OUT" "75 request record(s) parsed" "and it reports the population it read"

# ── the planted red: a SameOrigin CLAIM the url does not support ─────────────
#
# ⛔ THE CASE THE GATE EXISTS FOR. `url = someArgument` could be any origin, so
# `SameOrigin` beside it is a claim nothing checks — and that is the likely
# mistake, not the exotic one.
test_case "a_SameOrigin_claim_over_an_unprovable_url_is_refused" \
    "declared is not derived, so the claim has to be checked against the URL"
run_on "$(spec_filler 32)$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_nonzero "$RC" "the claim is refused"
assert_contains "$OUT" "declare SameOrigin with a URL that is not" "the refusal names the condition"
assert_contains "$OUT" "uploadToStorage" "and the function, not just a line"
assert_contains "$OUT" "DECLARED, not derived" "and says why the claim cannot be taken"

# ⚠️ The mirror: the SAME unprovable url, declaring CrossOrigin, must PASS. A
# gate that refused both would make an unprovable URL unusable rather than
# undeclared, and `putFileToR2` would have no legal form.
test_case "the_same_unprovable_url_declaring_CrossOrigin_passes" \
    "an unprovable URL is undeclared, not forbidden"
run_on "$(spec_filler 32)$(filler 75)$(record "uploadToStorage" "presignedUrl" "requestHeaders CrossOrigin NoCredential |> List.map toHeader")"
assert_exit_zero "$RC" "declaring CrossOrigin is the legal form for an unprovable URL"

# ── each recognised same-origin form, driven ─────────────────────────────────
#
# ⚠️ The forms are an enumerated SYNTAX list rather than an allowlist of call
# sites, so each shape needs a case: a shape that silently stopped being
# recognised would make every request using it report as unprovable, and the
# gate would be loudly wrong rather than quietly wrong — but only if something
# drives the shape.
test_case "spec_url_is_recognised_as_same_origin" "the plan path builds its url upstream from baseUrl"
run_on "$(spec_filler 32)$(filler 75)$(record "viaSpec" "spec.url" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "spec.url is same-origin by construction"

test_case "absolute_path_builder_is_recognised" "an absolute PATH is our origin"
run_on "$(spec_filler 32)$(filler 75)$(record "viaBuilder" "Url.Builder.absolute [ \"api\", \"thing\" ] []" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
assert_exit_zero "$RC" "Url.Builder.absolute yields a path, not a host"

test_case "a_literal_relative_path_is_recognised" "a leading slash is our origin"
run_on "$(spec_filler 32)$(filler 75)$(record "viaLiteral" "\"/api/thing\"" "requestHeaders SameOrigin (Session token) |> List.map toHeader")"
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
run_on "$(spec_filler 32)$(filler 75)
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

# ── the plan path, which cannot declare a destination at all ────────────────
#
# ⛔ `Effect.RequestPlan` is `{ spec, token, onResponse }` — no destination
# field — and `Effect.perform` sends every plan through `Api.authHeaders`, which
# hardcodes `SameOrigin`. So a spec whose URL leaves our origin carries the
# reader's token there, and NO declaration exists anywhere for this gate's
# per-call-site check to question. The hardcode is justified only by the whole
# `RequestSpec` population, which nothing checked until review asked.
test_case "a_RequestSpec_url_that_leaves_the_origin_is_refused" \
    "a plan cannot declare a destination, so the population is the declaration"
run_on "$(spec_filler 32)$(filler 75)$(spec "runawaySpec" "\"https://evil.test/api/x\"")"
assert_exit_nonzero "$RC" "a spec url off our origin is refused"
assert_contains "$OUT" "runawaySpec" "the refusal names the builder"
assert_contains "$OUT" "cannot declare a destination" "and says why no call site could have said so"
assert_contains "$OUT" "Effect.perform" "and names the function whose hardcode it justifies"

# ⚠️ The spec population needs its OWN floor, for the reason every floor here
# exists: a pattern that stopped matching would report "every spec is
# same-origin" over a population of zero.
test_case "a_spec_population_below_its_floor_is_refused" \
    "otherwise the plan-path check passes by having found nothing to check"
run_on "$(spec_filler 2)$(filler 75)"
assert_exit_nonzero "$RC" "two spec builders is not a checked plan path"
assert_contains "$OUT" "RequestSpec builder(s)" "the refusal quotes what it read"
assert_contains "$OUT" "hardcoded SameOrigin" "and names what the population is justifying"

test_case "the_sub_floor_spec_corpus_contained_no_violations" \
    "so the refusal above is about the population, not about a finding"
assert_not_contains "$OUT" "leaves our origin" \
    "nothing in the small spec corpus is a violation — the floor is what refused it"

# ⚠️ And the green path must SAY it checked the plan path. A check with no
# per-site declaration to point at, printing nothing when it passes, is
# indistinguishable from a check that never ran.
test_case "the_green_run_reports_the_plan_path_population" \
    "a silent success cannot be told from a check that did not run"
run_on "$(spec_filler 32)$(filler 75)"
assert_exit_zero "$RC" "the clean corpus passes"
assert_contains "$OUT" "32 RequestSpec builder(s) parsed" "and reports the plan-path population"

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
