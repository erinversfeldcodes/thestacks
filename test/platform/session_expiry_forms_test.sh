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
        "the legacy inline form — 0 sites now, kept so the two gates fail in the "
        "same direction if check-one-credential-derivation.sh is ever narrowed",
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

# ── the page floor and the verdict are about the same population ────────────
#
# ⛔ They were one page apart. The floor counted every page in scope, the
# success line counted the non-exempt ones, and nothing on a passing run
# printed the larger figure — so the SAME number, 28, was the healthy state in
# the verdict ("all 28 pages … route their 401") and the refused state in the
# floor ("only 28 page(s) are in scope; expected at least 29").
#
# ⚠️ MEASURED, and worse than illegible: because exempting a page keeps it in
# scope, adding one exemption passed the old floor green while the verdict's
# population fell from 28 to 27. A count drifting down under a green run is the
# exact failure that floor's own comment says it exists to prevent.
#
# ⚖️ Asserted as "the floor compares the expression the verdict prints" rather
# than against a literal, because the population legitimately grows. A literal
# here would go stale the next time a page starts making an authed request —
# this suite's sibling gate has already had that defect, where a hardcoded
# population figure outlived the constant it was copied from.
test_case "the_page_floor_counts_the_figure_the_verdict_prints" \
    "a floor and a verdict about populations one apart cannot be reconciled"
if python3 - "$GATE" <<'SAMEPOP'
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()

floor = re.search(r"if len\((\w+)\) < (MIN_[A-Z_]*PAGES[A-Z_]*):", src)
if floor is None:
    print("HARNESS: no page floor of the form `if len(X) < MIN_..PAGES..:` found.")
    print("         Either the floor is gone or it was rewritten; this case cannot")
    print("         tell which, so it fails rather than passing over nothing.")
    raise SystemExit(2)

verdict = re.search(r'"OK: all "\s*\+\s*str\(', src)
if verdict is None:
    print("HARNESS: could not find the success line's population expression.")
    print("         The verdict was reworded or removed; this case cannot tell which,")
    print("         so it fails rather than passing over nothing.")
    raise SystemExit(2)

# ⚠️ The printed expression is read by balancing parentheses rather than by a
# pattern for `len(x)`, so an arithmetic that diverges from the floor —
# `len(in_scope) - len(EXEMPT)`, which is what the verdict used to print — is
# reported as the mismatch it is instead of as an extraction failure.
depth, printed = 1, []
for char in src[verdict.end():]:
    if char == "(":
        depth += 1
    elif char == ")":
        depth -= 1
        if depth == 0:
            break
    printed.append(char)
printed = " ".join("".join(printed).split())

counted, constant = floor.group(1), floor.group(2)

if printed != f"len({counted})":
    print(f"the floor compares len({counted}) against {constant},")
    print(f"but the success line prints {printed}.")
    print("Two populations, one of them never printed on a passing run: the figure in")
    print("the verdict and the figure in the refusal cannot be reconciled by a reader,")
    print("and the same number means healthy in one and broken in the other.")
    raise SystemExit(1)

print(f"OK: floor and verdict both speak about len({counted}).")
SAMEPOP
then
    _record_pass "the floor compares the same expression the success line prints"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then
        _record_fail "HARNESS: the floor or the verdict could not be located — see above"
    else
        _record_fail "the floor and the verdict count different populations — see above"
    fi
fi
assert_contains "$GATE_SRC" "non-exempt page(s)" \
    "and the refusal says what it counted, not just \"in scope\""

test_case "the_page_floor_actually_fires" \
    "a declared floor that never refuses is decoration"
cp "$GATE" "$SANDBOX/pages.sh"
python3 - "$SANDBOX/pages.sh" <<'RAISE'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
p.write_text(re.sub(r"(MIN_[A-Z_]*PAGES[A-Z_]* = )\d+", r"\g<1>999999", s))
RAISE
PAGES_OUT="$(cd "$REPO_ROOT" && bash "$SANDBOX/pages.sh" 2>&1)"
PAGES_RC=$?
assert_exit_nonzero "$PAGES_RC" "an unreachable page floor refuses over the real pages"
assert_contains "$PAGES_OUT" "non-exempt page(s)" "and names the population it counted"

# ── one run reports every class of failure it found ─────────────────────────
#
# ⛔ The stale-exemption refusal used to `sys.exit(1)` before the routing
# findings were printed, and that ordering hid the defect it is most likely to
# accompany: an exemption goes stale when the page it named was renamed or
# stopped matching, which is precisely when a previously-exempt page lands back
# in scope unchecked. MEASURED on the gate as it stood: with the exemption
# pointed at a path that makes no authed request, the run printed the stale note
# and exited, giving no verdict at all on the real `Page/Admin/Session.elm` —
# which by then was in scope and dropping its 401.
#
# ⚖️ Fail-fast is right where the first failure makes later verdicts
# meaningless — the parsed-definitions floor above is that, since a drifted
# parser poisons every classification. A stale exemption poisons nothing.
# ⚠️ RUN TWICE, because a single run cannot tell the defect from a change in the
# exemption list. Dropping the exemption altogether establishes that the
# formerly-exempt page IS a finding; misnaming it establishes that the same
# finding survives alongside the stale note. Without the first run, an exemption
# that later points at a page which routes its 401 properly would make this case
# fail and blame the gate for short-circuiting something that was never there.
test_case "a_stale_exemption_does_not_hide_a_dropped_401" \
    "the class most likely to accompany a finding must not short-circuit it"
cp "$GATE" "$SANDBOX/unexempt.sh"
cp "$GATE" "$SANDBOX/both.sh"
python3 - "$SANDBOX/unexempt.sh" <<'DROP'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
p.write_text(re.sub(r"^EXEMPT = \{.*?^\}$", "EXEMPT = {}", s, count=1, flags=re.S | re.M))
DROP
ALONE_OUT="$(cd "$REPO_ROOT" && bash "$SANDBOX/unexempt.sh" 2>&1)"

if python3 - "$SANDBOX/both.sh" <<'MISNAME'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
# Misname the first exempted path, as a rename would. The file it named is then
# unexempt and in scope, so this one edit produces both failure classes.
m = re.search(r'"(frontend/src/Page/[A-Za-z0-9_/]+)\.elm":', s)
if m is None:
    print("HARNESS: the gate exempts nothing, so this case cannot plant a stale")
    print("         exemption. It proves nothing and fails rather than skipping.")
    raise SystemExit(2)
p.write_text(s.replace(m.group(0), f'"{m.group(1)}Renamed.elm":', 1), encoding="utf-8")
print("planted a rename of " + m.group(1) + ".elm")
MISNAME
then
    BOTH_OUT="$(cd "$REPO_ROOT" && bash "$SANDBOX/both.sh" 2>&1)"
    BOTH_RC=$?
    assert_exit_nonzero "$BOTH_RC" "a stale exemption still refuses"
    assert_contains "$BOTH_OUT" "stale exemption" "and says so"
    if [[ "$ALONE_OUT" != *"drop the 401"* ]]; then
        _record_fail "HARNESS: with the exemption dropped the gate reports no finding, so the exempted page routes its 401 and this plant stages only one failure class. Point it at a page that drops one."
    else
        assert_contains "$BOTH_OUT" "drop the 401" \
            "and the same run still reports the page that drops its 401"
    fi
else
    _record_fail "HARNESS: could not plant a stale exemption — see above"
fi

summarise
