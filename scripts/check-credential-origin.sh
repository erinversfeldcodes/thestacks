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
#   baseUrl ++ "/…"                  our own base, then a literal path
#   "/…"                             a literal relative path
#   Url.Builder.absolute [ "x", … ]  an absolute path from a literal segment
#   Url.Builder.crossOrigin baseUrl  our origin named explicitly
#   spec.url                         a RequestSpec url — checked separately below
SAME_ORIGIN = [
    re.compile(r'^\s*baseUrl\s*\+\+\s*"/'),
    re.compile(r'^\s*"/'),
    re.compile(r'^\s*Url\.Builder\.absolute\s*\[\s*"[^"/][^"]*"'),
    re.compile(r"^\s*Url\.Builder\.crossOrigin\s+baseUrl\b"),
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
SPEC_SAME_ORIGIN = [
    re.compile(r'^\s*baseUrl\s*\+\+\s*"/'),
    re.compile(r'^\s*"/'),
    re.compile(r'^\s*Url\.Builder\.absolute\s*\[\s*"[^"/][^"]*"'),
    re.compile(r"^\s*Url\.Builder\.crossOrigin\s+baseUrl\b"),
]

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

# ── the plan path: every RequestSpec url, since no plan can declare one ──────
#
# ⛔ A FLOOR OF ITS OWN, for the same reason the record floor exists: if the spec
# pattern stopped matching, this would report "every spec is same-origin" over a
# population of zero, which is the same output as a clean run.
MIN_SPEC_BUILDERS = 30

specs = 0
spec_violations = []

for match in re.finditer(r"^([a-z][A-Za-z0-9_']*)\s*:[^\n]*RequestSpec\s*$", src, re.M):
    fname = match.group(1)
    rest = src[match.end() :]
    stop = re.search(r"\n(?=[a-z][A-Za-z0-9_']*\s*:)", rest)
    body = strip_elm_comments(rest[: stop.start()] if stop else rest)

    url_match = re.search(r"url\s*=\s*(.*?)(?=\n\s*,|\n\s*\}|\Z)", body, re.S)
    if not url_match:
        continue

    specs += 1
    flattened = re.sub(r"\s+", " ", url_match.group(1).strip()).strip()
    if not any(p.match(flattened) for p in SPEC_SAME_ORIGIN):
        line_no = src[: match.start()].count("\n") + 1
        spec_violations.append((fname, line_no, flattened[:48]))

# ⛔ The floor, checked BEFORE the verdict. A parser that saw three records and
# found nothing has not cleared this file.
if specs < MIN_SPEC_BUILDERS:
    print(
        f"FAIL: parsed only {specs} RequestSpec builder(s) in {path}; "
        f"expected at least {MIN_SPEC_BUILDERS}.",
        file=sys.stderr,
    )
    print(
        "      `Effect.perform` sends every plan with a hardcoded SameOrigin, so this\n"
        "      population is the only thing justifying that. A verdict over a corpus this\n"
        "      small is the parser having drifted, not the source having become safe.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if spec_violations:
    print(
        f"FAIL: {len(spec_violations)} RequestSpec(s) have a URL that is not provably "
        f"same-origin:",
        file=sys.stderr,
    )
    for fname, line_no, expr in spec_violations:
        print(f"  {path}:{line_no}  {fname}  url = {expr}", file=sys.stderr)
    print(
        "\n⛔ A spec cannot declare a destination. `Effect.RequestPlan` is\n"
        "`{ spec, token, onResponse }` with no destination field, and `Effect.perform`\n"
        "sends it with `Api.authHeaders`, which hardcodes `SameOrigin`. So a spec whose\n"
        "URL leaves our origin would carry the reader's token there, and no declaration\n"
        "exists anywhere for a reviewer or a gate to question.\n"
        "\n"
        "Rewrite the URL to lead with a literal path (`baseUrl ++ \"/…\"`), or give\n"
        "`RequestPlan` a destination field and make `Effect.perform` honour it.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if records < floor:
    print(
        f"FAIL: parsed only {records} request record(s) in {path}; expected at least {floor}.",
        file=sys.stderr,
    )
    print("      A clean result over a corpus this small is the parser having drifted from", file=sys.stderr)
    print("      the source, not the source having become safe — which is indistinguishable", file=sys.stderr)
    print("      from a real pass if the floor is on findings instead of on records.", file=sys.stderr)
    raise SystemExit(1)

if violations:
    print(
        f"FAIL: {len(violations)} request(s) declare SameOrigin with a URL that is not "
        f"provably same-origin:",
        file=sys.stderr,
    )
    for name, line_no, expr in violations:
        print(f"  {path}:{line_no}  {name}  url = {expr}", file=sys.stderr)
    print(
        "\nThe destination is DECLARED, not derived, so `SameOrigin` here is a claim this\n"
        "gate cannot check against the URL beside it. Either rewrite the URL into a\n"
        "recognisable same-origin form (baseUrl ++ …, spec.url, Url.Builder.absolute,\n"
        "a literal \"/path\"), or declare `CrossOrigin` and carry no credential.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {records} request record(s) parsed in {path}; "
    f"none declares SameOrigin with an unprovable URL."
)
# ⚠️ Reported on the GREEN path, not only on failure. The plan-path check has no
# per-call-site declaration to point at, so if it printed nothing when it passed
# there would be no way to tell it from a check that never ran — which is the
# distinction this gate's floors exist to preserve everywhere else.
print(
    f"    {specs} RequestSpec builder(s) parsed; every URL leads with a literal path, "
    f"which is what justifies the hardcoded SameOrigin in Effect.perform."
)

# ⚠️ Reported, not failed. A request with an unprovable URL that declares
# nothing is not yet a violation — it may be un-migrated, or it may legitimately
# take its URL as an argument. It becomes a violation the moment it claims
# `SameOrigin`. Printing the set keeps it from being discovered later as a
# surprise.
if unprovable:
    print(f"    {len(unprovable)} request(s) have a URL this gate cannot prove same-origin:")
    for name, line_no, expr in unprovable:
        print(f"      {path}:{line_no}  {name}  url = {expr}")
    print("    Each must declare CrossOrigin, or be rewritten into a recognisable form,")
    print("    before it can carry a credential.")
PY
