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
#   baseUrl ++ …                     built from our own base
#   spec.url                         a RequestSpec's url, built upstream from baseUrl
#   Url.Builder.absolute …           an absolute PATH, so our origin
#   Url.Builder.crossOrigin baseUrl  our origin named explicitly
#   "/…"                             a literal relative path
SAME_ORIGIN = [
    re.compile(r"^\s*baseUrl\b"),
    re.compile(r"^\s*spec\.url\s*$"),
    re.compile(r"^\s*Url\.Builder\.absolute\b"),
    re.compile(r"^\s*Url\.Builder\.crossOrigin\s+baseUrl\b"),
    re.compile(r'^\s*"/'),
]

records = 0
violations = []
unprovable = []

for match in RECORD.finditer(src):
    body = match.group(0)
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
    first_line = url_expr.split("\n")[0].strip()

    provable = any(p.match(first_line) for p in SAME_ORIGIN)
    declares_same_origin = re.search(r"\bSameOrigin\b", body) is not None

    if not provable:
        unprovable.append((name, line_no, first_line[:48]))
        if declares_same_origin:
            violations.append((name, line_no, first_line[:48]))

# ⛔ The floor, checked BEFORE the verdict. A parser that saw three records and
# found nothing has not cleared this file.
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
