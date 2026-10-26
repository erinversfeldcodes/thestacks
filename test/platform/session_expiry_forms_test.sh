#!/usr/bin/env bash
# test/platform/session_expiry_forms_test.sh
#
# The credential FORMS `scripts/check-session-expiry-coverage.sh` recognises,
# and its floor on definitions parsed.
#
# ⛔ WHY THESE TWO THINGS AND NOT THE WHOLE GATE. The gate had no suite at all,
# and it decides which `Api.elm` endpoints are mandatorily authenticated — and
# therefore which pages must route a 401 to the session-expiry interceptor — by
# matching the credential FORM at each call site.
#
# A 70-site consolidation onto `Api.requestHeaders` is in flight. **The moment a
# site migrates, the old patterns stop matching it**, so an unrecognised new form
# walks the gate's population down silently. And its original floor was
# `if not authed_endpoints` — EMPTINESS — so it would have stayed green all the
# way from 70 to one.
#
# ⚠️ So this covers exactly what changed: the forms, and a floor on what was
# READ rather than on what was found. The gate's other half — page-to-401
# routing — has no coverage here, and that gap predates this change rather than
# being introduced by it. Stated rather than silently inherited.
#
# ⚖️ THE PATTERNS ARE EXTRACTED FROM THE GATE AND RUN, not reimplemented. A
# hand-written stand-in would be wrong in the same direction as the thing it
# checks — which this repository has already done once, where a probe and its
# case failed green together and masked each other. If the extraction stops
# matching, the harness case below fires instead of the suite quietly becoming a
# tautology.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-session-expiry-coverage.sh"

test_case "gate_exists" "the script is present and parses"
assert_path_exists "$GATE" "scripts/check-session-expiry-coverage.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so nothing below exercises the real thing"
fi

test_case "the_recognised_forms_classify_as_declared" \
    "each form driven through the gate's OWN patterns, extracted rather than restated"
if python3 - "$GATE" <<'FORMS'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()


def extract(name):
    """Pull one compiled pattern's source out of the gate and compile it here.

    ⚠️ Extracted rather than reimplemented: a restated regex can be wrong in the
    same direction as the one it checks, and then the case and the gate agree
    while both are broken.
    """
    m = re.search(rf"^{name} = re\.compile\(\n(.*?)^\)", src, re.S | re.M)
    if not m:
        return None
    body = m.group(1)
    parts = re.findall(r'r"((?:[^"\\]|\\.)*)"', body)
    if not parts:
        return None
    flags = re.M if "re.M" in body else 0
    return re.compile("".join(parts), flags)


MANDATORY = extract("MANDATORY")
OPTIONAL = extract("OPTIONAL")

if MANDATORY is None or OPTIONAL is None:
    print("HARNESS: could not extract MANDATORY/OPTIONAL from the gate.")
    print("         The suite cannot show the forms classify, so this is a failure")
    print("         rather than a skip — a differential case that stops extracting")
    print("         becomes a tautology, which is what it exists to prevent.")
    raise SystemExit(2)


def classify(headers_expr):
    body = f'        {{ method = "GET"\n        , headers = {headers_expr}\n        , url = baseUrl ++ "/x"\n        }}'
    return bool(MANDATORY.search(body)) and not bool(OPTIONAL.search(body))


CASES = [
    # (headers expression, expected mandatory?, why it matters)
    (
        '[ Http.header "Authorization" ("Bearer " ++ token) ]',
        True,
        "the legacy inline form — 70 sites still use it",
    ),
    ("authedHeaders authed", True, "the legacy shared derivation, 8 callers"),
    (
        "httpHeaders SameOrigin (Session token)",
        True,
        "THE NEW FORM — unrecognised means the population falls silently as sites migrate",
    ),
    ("authHeaders maybeToken", False, "the legacy optional form takes a Maybe"),
    (
        "httpHeaders SameOrigin (Optional maybeToken)",
        False,
        "the new optional form — why Optional must stay separately nameable",
    ),
    (
        "httpHeaders CrossOrigin NoCredential",
        False,
        "an endpoint that never takes a credential cannot be mandatorily authenticated",
    ),
]

failures = []
for expr, expected, why in CASES:
    got = classify(expr)
    if got != expected:
        failures.append((expr, expected, got, why))

if failures:
    print(f"{len(failures)} form(s) classify wrongly:")
    for expr, expected, got, why in failures:
        want = "MANDATORY" if expected else "not mandatory"
        have = "MANDATORY" if got else "not mandatory"
        print(f"  headers = {expr}")
        print(f"      expected {want}, got {have} — {why}")
    raise SystemExit(1)

print(f"OK: all {len(CASES)} credential forms classify as declared.")
FORMS
then
    _record_pass "all six forms — three mandatory, three not — classify as declared"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then
        _record_fail "HARNESS: the patterns could not be extracted, so this case proves nothing"
    else
        _record_fail "a credential form classifies wrongly — see the lines above"
    fi
fi

# ── the floor is on definitions PARSED, not on findings ─────────────────────
#
# ⛔ The original floor was `if not authed_endpoints`: emptiness. So a change
# taking the population from 70 matching sites to ONE passed green, classified
# one endpoint, and printed "1" as though that were the population. "I found no
# mandatory endpoints" and "I could not read the file" are the same output
# unless the floor is on the reading.
test_case "the_floor_is_on_definitions_parsed" \
    "a findings floor is satisfied by almost-total parser loss"
GATE_SRC="$(cat "$GATE")"
assert_contains "$GATE_SRC" "MIN_PARSED_DEFINITIONS" "a parsed-definitions floor is declared"
assert_contains "$GATE_SRC" "parsed only" "and it refuses by quoting what it read"
assert_contains "$GATE_SRC" "parser having drifted" \
    "and names the cause a findings-based floor cannot distinguish"

# ⚠️ Driven rather than asserted on the source: the floor is raised above the
# real corpus, so the gate must refuse over a file it can read perfectly well.
# That separates "the floor exists" from "the floor fires".
test_case "the_parsed_floor_actually_fires" \
    "a declared floor that never refuses is decoration"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cp "$GATE" "$SANDBOX/gate.sh"
python3 - "$SANDBOX/gate.sh" <<'RAISE'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
p.write_text(re.sub(r"MIN_PARSED_DEFINITIONS = \d+", "MIN_PARSED_DEFINITIONS = 999999", s))
RAISE
OUT="$(cd "$REPO_ROOT" && bash "$SANDBOX/gate.sh" 2>&1)"
RC=$?
assert_exit_nonzero "$RC" "an unreachable floor refuses over the real Api.elm"
assert_contains "$OUT" "parsed only" "and says how many definitions it read"

summarise
