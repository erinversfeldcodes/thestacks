#!/usr/bin/env bash
# A request that attaches a credential must have a PROVABLY same-origin URL.
#
# ⛔ WHY THIS IS A SCRIPT AND NOT AN ELM TEST, which is the whole reason it
# exists in this form.
#
# `Api.requestHeaders` takes a `Destination` — `SameOrigin` or `CrossOrigin` —
# and returns no credential for the latter. But **the destination is DECLARED by
# the caller, not derived from the URL**, so `requestHeaders SameOrigin (Session
# token)` against an external URL still attaches the token. The precedence
# inside the builder defends `CrossOrigin` + `Session`, which nobody writes by
# accident; it does nothing against `SameOrigin` at a foreign URL, which is the
# ordinary-looking value a hurried caller reaches for.
#
# ⚖️ Guarding a DECLARED value requires relating it to something DERIVED, and the
# module receiving the declaration is structurally the wrong place for that
# check. So the check lives outside, and it relates the declared destination to
# the URL expression beside it.
#
# ⚠️ **Elm has no reflection**, so no Elm test can enumerate the request
# functions. The alternative was an Elm test over a hand-maintained list of
# request specs — but that list is itself a population claim with nothing
# holding it, and it would drift exactly like the inventories this campaign has
# corrected four times. A drifted list reads as coverage.
#
# ⛔ WHAT IT DOES NOT CHECK. It reads TEXT. It cannot follow a URL through a
# function call, and it does not try to — the rule below is that an
# unrecognisable URL expression must declare `CrossOrigin` or be rewritten into
# a recognisable form. That keeps the check total: there is no third outcome
# where the gate shrugs.
#
# ⛔ AND THE RULE IS ASYMMETRIC IN THE DANGEROUS DIRECTION, which this gate
# cannot fix and must therefore say out loud.
#
# An unrecognisable URL has exactly ONE declaration this gate permits, and it is
# `CrossOrigin` — the one that drops the CSRF proof. So when the gate cannot
# read a URL it pushes the author toward the insecure answer, and then reports
# green for it. That is not hypothetical: the photo-upload PUT declared
# `CrossOrigin` for a route on our OWN origin, carried no `x-csrf-token`, and
# every upload in every browser was refused with `403 absent_header` while this
# gate passed.
#
# ⚖️ Why it is not fixed here. The second question — "may this request declare
# CrossOrigin at all?" — is a question about where the URL POINTS, and a gate
# that reads text cannot answer it for an expression it already admits it cannot
# follow. Adding a checked-reason allowlist would move the judgement into a
# comment, and this repository has already shipped a guard whose allowlist
# carried a written justification that was simply false with nothing checking
# it. A justification a machine cannot check is a sentence, not a guard.
#
# ⚖️ Where it IS fixable: make the wrong declaration unrepresentable rather than
# detectable — an opaque same-origin URL type that encodes its own path
# segments, so a request to our own origin cannot be constructed as cross-origin
# and cannot take a credential parameter. That is a type-system change in
# `Api.elm`, it retires this gate rather than extending it, and it is tracked
# separately. Until then this header is the record that the asymmetry is known
# and deliberate, not overlooked.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

API="frontend/src/Api.elm"

if [[ ! -f "$API" ]]; then
    echo "FAIL: $API not found, so this gate cannot look." >&2
    exit 1
fi

# ⛔ A FLOOR ON RECORDS PARSED, NOT ON FINDINGS — and this is the one thing this
# gate deliberately does NOT copy from `check-session-expiry-coverage.sh`.
#
# That gate's floor is `if not authed_endpoints`: emptiness. So a change taking
# its population from 71 matching sites down to ONE leaves it green, classifying
# one endpoint and printing "1" as though that were the population. A floor at
# zero is satisfied by almost-total loss.
#
# This floors on how many request records the parser SAW. "I found no
# violations" and "I could not look" are the same output otherwise, and that
# distinction is the one five sweeps in this campaign failed on.
MIN_REQUEST_RECORDS=70

python3 - "$API" "$MIN_REQUEST_RECORDS" <<'PY'
import re
import sys

path, floor = sys.argv[1], int(sys.argv[2])
src = open(path, encoding="utf-8").read()
lines = src.split("\n")

# ⚠️ A request record is one carrying BOTH `method =` and `headers =`. That
# excludes the adapter records which also have a `url` field — `proto.url` in
# `fromProtoDiscoveredSource` is a DiscoveredSource being mapped, not a request,
# and a `url`-keyed scan would have counted it.
RECORD = re.compile(r"\{(?:[^{}]|\{[^{}]*\})*\}", re.S)

# ⛔ THE PROVABLY-SAME-ORIGIN FORMS, enumerated as SYNTAX rather than as a list
# of blessed call sites. An allowlist of sites needs maintaining and rots; a list
# of recognised expression shapes is a property of the language, and anything
# outside it is required to declare its destination instead.
#
# ⛔ EVERY FORM MUST BEGIN WITH A LITERAL PATH, and two of these rules did not
# until review caught them. The guarantee is positional: **once a url starts with
# `/x`, nothing appended after it can change the origin.** So the question is
# only ever "what are the first characters", and a rule that does not pin those
# proves nothing.
#
# ⚠️ `baseUrl` is `""`. So `baseUrl ++ X` is literally `X`, and the old rule
# "leads with `baseUrl`" guaranteed NOTHING — `baseUrl ++ someVariable` passed,
# and that variable could hold `https://evil.test/`. One site in `Api.elm`
# relied on exactly that (`getGroupFeed`, which bound its whole path); it now
# leads with the literal. The rule reads `baseUrl ++ "/…"`.
#
# ⚠️ `Url.Builder.absolute` DOES NOT ENCODE ITS PATH SEGMENTS. Its whole body is
#     absolute pathSegments params = "/" ++ String.join "/" pathSegments ++ toQuery params
# and `percentEncode` is applied only to query keys and values. So
# `absolute [ "/evil.test" ] []` yields `//evil.test` — a protocol-relative URL
# that leaves the origin entirely, and `absolute [ "", "evil.test" ]` does the
# same. The rule therefore requires a LITERAL first segment that does not itself
# begin with `/` and is not empty. All four call sites already comply; the point
# is that they now comply by rule rather than by luck.
#
#   Api.Url.toString …               derived from a SameOriginUrl — see below
#   baseUrl ++ "/…"                  our own base, then a literal path
#   "/…"                             a literal relative path
#
# ⛔ `Api.Url.toString` IS THE ONLY ONE OF THESE THAT IS A PROOF RATHER THAN A
# RECOGNISED SHAPE. The others say "this text looks like a path"; that one says
# the value came from `Api.Url.SameOriginUrl`, whose sole constructor cannot
# build a URL that leaves our origin. A String can leave that type and cannot
# enter it, so anything `toString` returns was constructed safely — whatever the
# expression beside it looks like.
#
# ⚠️ `Url.Builder.absolute` and `Url.Builder.crossOrigin baseUrl` are GONE from
# this list, and not because they stopped appearing. `absolute` never encodes
# path segments, so `absolute [ "/evil.test" ]` yields `//evil.test` and left
# this gate accepting an expression that escapes; `crossOrigin baseUrl` was
# same-origin only because `baseUrl` happens to be `""`, which its own name
# invites someone to change. Both were rewritten to `Api.Url.path`.
SAME_ORIGIN = [
    re.compile(r"^\s*Api\.Url\.toString\b"),
    re.compile(r'^\s*baseUrl\s*\+\+\s*"/'),
    re.compile(r'^\s*"/'),
    re.compile(r"^\s*spec\.url\s*$"),
]

# ⛔ `spec.url` IS AN INHERITED CLAIM, so the population it inherits from has to
# be checked — and until review it was not.
#
# `Effect.perform` sends any `RequestPlan` with `Api.authHeaders plan.token`,
# which hardcodes `httpHeaders SameOrigin (Optional …)`. `RequestPlan` has NO
# destination field, so a plan cannot declare one and there is no `SameOrigin`
# token at the call site for the check above to relate to a URL. The hardcode is
# correct only if every `RequestSpec` url is same-origin by construction — which
# was true, and true by nobody's design.
#
# ⚠️ So this is the declaration the plan path cannot make for itself, made once
# over the whole population instead of at each of its call sites.
# SPEC_SAME_ORIGIN was here. It is gone: `RequestSpec.url` is an
# `Api.Url.SameOriginUrl`, so the compiler makes this statement on every build.

def strip_elm_comments(text):
    """Blank Elm comments, keeping line structure so line numbers stay true.

    ⛔ MEASURED THE FIRST TIME THIS GATE MET REAL CODE, and it is this
    repository's most-recorded gate failure: **a gate reading its own subject
    matter as configuration.**

    `putFileToR2` declares `CrossOrigin NoCredential` and carries a comment
    explaining that a `SameOrigin` claim there would attach a bearer token to a
    third-party host. The gate matched the word `SameOrigin` IN THAT COMMENT and
    reported the one correctly-declared cross-origin request in the file as the
    violation — while the comment said exactly why it was not.

    ⚠️ So the text explaining the rule was the text that broke it. Any file
    discussing this gate will contain its keywords as prose, which makes
    stripping a precondition rather than a refinement.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("{-", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("{-", j):
                    depth += 1
                    j += 2
                elif text.startswith("-}", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


records = 0
violations = []
unprovable = []

for match in RECORD.finditer(src):
    body = strip_elm_comments(match.group(0))
    if "method =" not in body or "headers =" not in body:
        continue

    records += 1
    line_no = src[: match.start()].count("\n") + 1

    # The enclosing top-level definition, for a message that names a function
    # rather than a line.
    name = "?"
    for i in range(line_no - 1, -1, -1):
        m = re.match(r"^([a-z][A-Za-z0-9_]*)\s*:", lines[i])
        if m:
            name = m.group(1)
            break

    url_match = re.search(r"url\s*=\s*(.*?)(?=\n\s*,|\n\s*\})", body, re.S)
    url_expr = url_match.group(1).strip() if url_match else ""

    # ⚠️ NORMALISED to one line rather than read first-line-only. `elm-format`
    # breaks a long url across lines and puts the `++` at the START of the
    # continuation, so `url =\n    baseUrl\n        ++ "/api/x"` has `baseUrl`
    # alone on its first line — and a first-line match sees a bare `baseUrl`,
    # which the tightened rule correctly refuses. The expression is one
    # expression; reading one line of it was an accident of formatting.
    flattened = re.sub(r"\s+", " ", url_expr).strip()

    provable = any(p.match(flattened) for p in SAME_ORIGIN)
    declares_same_origin = re.search(r"\bSameOrigin\b", body) is not None

    if not provable:
        unprovable.append((name, line_no, flattened[:48]))
        if declares_same_origin:
            violations.append((name, line_no, flattened[:48]))

# ── the method a header call is told must be the method the record sends ────
#
# ⛔ TWO STATEMENTS OF ONE FACT IN ONE RECORD, and the disagreement is silent in
# the dangerous direction. `requestHeaders` decides whether to attach the CSRF
# token from the method it is GIVEN; the request is sent with the method in the
# record's own field. `method = "POST"` beside `httpHeaders "GET" …` produces a
# write with no proof, and every test that does not read the header still passes.
#
# ⚖️ The duplication is accepted deliberately — the alternative is each call site
# deciding whether to add the header, which is 45 chances to decide wrongly with
# nothing able to tell a considered omission from a forgotten one. What makes it
# safe is that both literals sit in the SAME record, so the check is textual.
#
# ⚠️ `spec.method` on both sides is NOT duplication: it is one expression read
# twice, so it cannot disagree with itself. Those sites need no agreement check
# and get none.
mismatched = []

for match in RECORD.finditer(src):
    body = strip_elm_comments(match.group(0))
    if "method =" not in body or "headers =" not in body:
        continue

    declared = re.search(r'method\s*=\s*("(?:[A-Za-z]+)"|spec\.method)', body)
    # ⚠️ ONLY a method-shaped first argument. An earlier version accepted any
    # identifier and matched `requestHeaders SameOrigin (…)` — reading the
    # DESTINATION as the method and reporting every correct call as a
    # disagreement. A call that passes no method at all does not compile, so
    # there is nothing for this rule to catch there.
    passed = re.search(
        r"headers\s*=\s*(?:httpHeaders|requestHeaders|Api\.httpHeaders|Api\.requestHeaders"
        r"|authedHeaders|authHeaders)\s+(\"[A-Za-z]+\"|[a-zA-Z_][A-Za-z0-9_]*\.method)",
        body,
    )
    if not declared or not passed:
        continue

    if declared.group(1) != passed.group(1):
        line_no = src[: match.start()].count("\n") + 1
        name = "?"
        for i in range(line_no - 1, -1, -1):
            m = re.match(r"^([a-z][A-Za-z0-9_]*)\s*:", lines[i])
            if m:
                name = m.group(1)
                break
        mismatched.append((name, line_no, declared.group(1), passed.group(1)))

if mismatched:
    print(
        f"FAIL: {len(mismatched)} request(s) send one method and tell the header builder another:",
        file=sys.stderr,
    )
    for name, line_no, declared_m, passed_m in mismatched:
        print(
            f"  {path}:{line_no}  {name}  sends {declared_m}, builds headers for {passed_m}",
            file=sys.stderr,
        )
    print(
        "\n⛔ The CSRF token is attached on the method the BUILDER is told about, and the\n"
        "request is sent with the method in the record's own field. When they disagree a\n"
        "state-changing request can go out with no proof, and nothing that does not read\n"
        "the header will notice.\n"
        "\n"
        "Pass the record's own method, verbatim.",
        file=sys.stderr,
    )
    raise SystemExit(1)

# ── the plan path: RETIRED, because the type now carries it ──────────────────
#
# ⛔ A `MIN_SPEC_BUILDERS` floor and a per-spec URL check used to live here, and
# both are gone because `RequestSpec.url` is an `Api.Url.SameOriginUrl` rather
# than a `String`. `Api.Url.path` is its only constructor and cannot produce a
# URL that leaves our origin — percent-encoding every segment and dropping the
# empty ones, the second of which is what `Url.Builder.absolute` omits and why
# building on it would have reproduced the hole.
#
# ⚖️ So the question this half asked — "is every spec's URL provably
# same-origin?" — is no longer a property of a corpus to be counted. It is the
# field's type, checked by the compiler on every build, with no population floor
# to drift and no comment-stripping pass to get wrong.
#
# ⚠️ WHAT REMAINS BELOW IS NOT REDUNDANT. The record half above covers direct
# `Http.request` sites, whose `url` is still a plain `String`, and there are
# about sixty-six of them. They move onto the plan as part of the `Cmd msg`
# migration; only then does this script have nothing left to say and the whole
# file go. Deleting it today would lose a guarantee for every one of them.

# ⛔ THE RECORD FLOOR, CHECKED BEFORE THE VERDICT — and it went missing.
#
# Retiring the spec half spliced this out with it, so `MIN_REQUEST_RECORDS` was
# still being parsed and passed in while nothing compared anything to it. The
# gate's own suite caught it on the case written for exactly this
# ("a_corpus_below_the_floor_is_refused_even_with_no_violations", got exit 0) —
# which is what that case is for, and why a gate change has to land with its
# suite rather than after it.
if records < floor:
    print(
        f"FAIL: parsed only {records} request record(s) in {path}; expected at least {floor}.",
        file=sys.stderr,
    )
    print("      A clean result over a corpus this small is the parser having drifted from", file=sys.stderr)
    print("      the source, not the source having become safe — which is indistinguishable", file=sys.stderr)
    print("      from a real pass if the floor is on findings instead of on records.", file=sys.stderr)
    raise SystemExit(1)

print(
    f"    RequestSpec urls are type-checked (Api.Url.SameOriginUrl), not parsed here; "
    f"which is what justifies the hardcoded SameOrigin in Effect.perform."
)

# ⚠️ Reported on the GREEN path, not only on failure: a check that prints
# nothing when it passes cannot be told from one that never ran.
print(
    f"OK: {records} request record(s) parsed in {path}; "
    f"every credential-bearing URL is provably same-origin."
)

# ⚠️ Reported, not failed. A request with an unprovable URL that declares
# nothing is not yet a violation — it may be un-migrated, or it may legitimately
# take its URL as an argument. It becomes a violation the moment it claims
# `SameOrigin`. Printing the set keeps it from being discovered later as a
# surprise.
if unprovable:
    # ⛔ THIS NOW FAILS, AND UNTIL TODAY IT DID NOT.
    #
    # The file opens "A request that attaches a credential must have a PROVABLY
    # same-origin URL" — and for direct `Http.request` records this list was
    # printed to stdout and the script exited 0. The one `SystemExit(1)` in this
    # half was the population floor. So the headline claim was advisory: a fresh
    # off-origin URL in a credential-bearing request would have been described
    # in the CI log and passed the gate.
    #
    # ⚖️ It can enforce now because the population is clean: every spec URL is
    # an `Api.Url.SameOriginUrl` by type, and `Api.Url.toString` is accepted as
    # the proof it is. Enforcing earlier would have failed on fifteen sites that
    # were in fact safe, which is presumably why it never did.
    print(
        f"FAIL: {len(unprovable)} request(s) attach a credential to a URL this "
        f"gate cannot prove is same-origin:",
        file=sys.stderr,
    )
    for name, line_no, expr in unprovable:
        print(f"  {path}:{line_no}  {name}  url = {expr}", file=sys.stderr)
    print(
        "\n⛔ Build it through `Api.Url.path`, whose result cannot leave our\n"
        "origin, and hand it over with `Api.Url.toString`. There is no longer a\n"
        "destination to declare — the type is the declaration.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
