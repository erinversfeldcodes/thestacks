#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import glob
import re
import sys

mode = sys.argv[1]

API = "frontend/src/Api.elm"
PAGE_GLOB = "frontend/src/Page/**/*.elm"

EXEMPT = {
    "frontend/src/Page/Admin/Session.elm": (
        "The admin sign-in gate itself. Its 401s ARE the sign-in failing, and it renders "
        "them inline because 'you cannot sign in' is the page's entire subject. Routing "
        "them to the interceptor would bounce an operator off the admin gate onto the "
        "reader login, losing the message that explains why."
    ),
}

def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()

def top_level_definitions(text):
    """Split an Elm module into (name, body) for each top-level lowercase binding."""
    definitions = {}
    name, buffer = None, []
    for line in text.split("\n"):
        match = re.match(r"^([a-z][A-Za-z0-9_']*)[\s:]", line)
        if match:
            if name:
                definitions.setdefault(name, []).extend(buffer)
            name, buffer = match.group(1), [line]
        elif name is not None:
            buffer.append(line)
    if name:
        definitions.setdefault(name, []).extend(buffer)
    return {key: "\n".join(value) for key, value in definitions.items()}

# ⛔ THREE FORMS. The migration that needed the third one has FINISHED; the
# inline form is kept deliberately, and the reason changed when it did.
#
# `Api.elm`'s 70 inline `Http.header "Authorization"` derivations were
# consolidated onto `Api.requestHeaders` — **the count is now 0, and
# `scripts/check-one-credential-derivation.sh` holds it there**, refusing any
# new site that spells the credential outside the builder.
#
# ⚠️ MEASURED when that gate landed: deleting the inline alternative below
# changes NOTHING — 70 endpoints, 25 pages, byte-identical output. So it is dead
# as far as today's source goes.
#
# ⚖️ It stays anyway, and the argument is composition rather than caution. A
# re-introduced inline derivation is now refused outright by the sibling gate, so
# this pattern is no longer the thing standing between that mistake and a green
# run. What it does instead is make the two gates fail in the same direction: if
# the absence gate is ever narrowed, bypassed, or applied to a corpus that
# excludes some file, an inline site still classifies as mandatorily
# authenticated here rather than silently dropping out of the population a page
# is checked against.
#
# ⚠️ What was WRONG with this comment before, recorded because the prose outlived
# the fact it asserted: it said a migration was "in flight" and that "70 sites
# still use" the inline form. Both were true when written and false within days,
# and nothing checks a comment. The claim that replaces them — that deleting the
# alternative changes no output — is one `git stash` and one run away from being
# verified by anyone who doubts it.
#
# ⚠️ `(?:\s+\S+){1,2}` because the builder gained a METHOD parameter: a call
# now reads `httpHeaders "POST" SameOrigin (Session token)` — two words before
# the constructor where there used to be one. A fixed `\s+\w+\s+` silently
# stopped matching every migrated site, and this gate reported a STALE EXEMPTION
# rather than a drop in population, because the page it exempts had vanished
# from the set. ⚖️ That is the floor working sideways: the definitions still
# parsed, so MIN_PARSED_DEFINITIONS was satisfied, and what caught it was the
# exemption having nothing left to protect.
#
# ⚠️ Matched on the CREDENTIAL CONSTRUCTOR rather than on the wrapper
# function's name, because there are two wrappers — `requestHeaders` returning
# data and `httpHeaders` returning `Http.Header` — and a third would otherwise
# silently fall out of the population. The constructor IS the declaration;
# the function around it is plumbing.
#
# ⚠️ `Session` is the mandatory marker and `Optional` the maybe-authenticated
# one, which is why those constructors must stay separately nameable at the call
# site. They are the only thing distinguishing an endpoint that always needs a
# credential from one that merely accepts it — and that distinction is what
# decides whether a page must route a 401 to the session-expiry interceptor.
MANDATORY = re.compile(
    r"headers\s*=\s*("
    r"authedHeaders\b"
    r"|\[\s*Http\.header\s+\"Authorization\""
    r"|\w*[Hh]eaders(?:\s+\S+){1,2}\s+\(\s*Session\b"
    r")"
)
OPTIONAL = re.compile(
    r"headers\s*=\s*("
    r"authHeaders\b"
    r"|\w*[Hh]eaders(?:\s+\S+){1,2}\s+\(\s*Optional\b"
    r"|\w*[Hh]eaders(?:\s+\S+){1,2}\s+NoCredential\b"
    r"|$)",
    re.M,
)

# ⛔ THE SECOND KEY, and the reason the first one alone had stopped describing
# the codebase. `Api.elm`'s mandatorily-authenticated endpoints are one of TWO
# ways this app sends an authenticated request; the other is a request PLAN,
# `Effect.authed spec token { onExpired = …, onResponse = … }`, built at the
# call site instead of inside `Api`. A plan-based endpoint matched nothing
# above, so `Page.BookDetail`'s ten authenticated requests and
# `Page.Bookshelf.ReadingPile`'s three were invisible here — two pages wholly
# outside a gate that reported "all 26 pages route their 401".
#
# ⚠️ So the population is a SUM, and endpoints migrating from `Api.Authed` onto
# the plan move between the two keys rather than leaving the count. A gate that
# read only the first key would have watched 72 walk down to 0 while printing
# success over whatever was left.
#
# ⛔ MATCHED BY THE CONSTRUCTOR'S NAME, like `authedHeaders` above, and for the
# same reason: a name is greppable per call site. The obligation could have been
# expressed as a flag on the existing constructor — and a `Bool` would have
# blinded this gate completely, because `True` and `False` carry no searchable
# identity and the first site passing a variable would drop out of the
# population with nothing reporting it. `Effect.authed` and `Effect.public` are
# separate named functions, so every site declares which it is in text.
#
# ⚠️ Keep the authenticated plan constructor named `Effect.authed`. Renaming it,
# or wrapping it in a per-page helper, empties this key silently — the same note
# `Api.authedHeaders` carries in its own docstring.
MANDATORY_PLAN = re.compile(r"\bEffect\.authed\b")

BLOCK_COMMENT = re.compile(r"\{-.*?-\}", re.S)
LINE_COMMENT = re.compile(r"^[ \t]*--.*$", re.M)

def code_only(text):
    """The module with its comments removed.

    ⛔ BECAUSE THIS KEY IS A NAME, AND PROSE CAN SAY A NAME. `Effect.authed`'s
    own docstring names itself, and `Api.elm`'s `interceptExpiry` names it too —
    so counting the literal across a corpus that included either file would
    classify a doc comment as a call site, and the population figure would go
    up when somebody wrote a sentence. This repository has the matching defect
    on record in the other direction: an absence assertion that matched the
    prose explaining why the pattern was banned.

    ⚠️ Only whole-line `--` comments are stripped, not trailing ones. A `--`
    inside a string literal is the hazard, and a line whose first characters are
    `--` cannot be one in formatted Elm.
    """
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", text))

def plans_in(text):
    """How many authenticated request plans a module builds."""
    return len(MANDATORY_PLAN.findall(code_only(text)))

api_text = read(API)
definitions = top_level_definitions(api_text)
authed_endpoints = set()
for name, body in definitions.items():
    if name in ("authedHeaders", "authHeaders", "requestHeaders"):
        continue
    if MANDATORY.search(body) and not OPTIONAL.search(body):
        authed_endpoints.add(name)

# ⛔ A FLOOR ON WHAT WAS PARSED, not only on what was found — added 2026-10-26
# because the emptiness check below cannot tell a cleared file from a broken
# parser, and a 70-site migration is about to walk this population down.
#
# MEASURED: `if not authed_endpoints` refuses only at ZERO, so a change taking
# this from 70 matching sites to ONE passes green, classifies one endpoint and
# prints "1" as though that were the population. "I found nothing" and "I could
# not look" are the same output unless the floor is on the reading.
MIN_PARSED_DEFINITIONS = 200

if len(definitions) < MIN_PARSED_DEFINITIONS:
    print(
        f"FAIL: parsed only {len(definitions)} top-level definition(s) in " + API + ";",
        file=sys.stderr,
    )
    print(
        f"      expected at least {MIN_PARSED_DEFINITIONS}. A verdict over a corpus this",
        file=sys.stderr,
    )
    print(
        "      small is the parser having drifted from the source, not the source having",
        file=sys.stderr,
    )
    print("      become safe — and the findings-based floor below cannot tell them apart.", file=sys.stderr)
    sys.exit(1)

# ⚠️ NOT a floor on this key alone any more, and the change is deliberate: a
# completed migration onto request plans empties `Api.elm` of mandatory
# endpoints legitimately, and a gate that refused that would be refusing the
# thing it exists to make safe. The count floor on the SUM below is what catches
# the parser drifting, on either key.
plan_sites = []
for path in sorted(glob.glob(PAGE_GLOB, recursive=True)):
    plan_sites.extend([path] * plans_in(read(path)))

if not authed_endpoints and not plan_sites:
    print("FAIL: found no authenticated requests at all — none in " + API + " and no")
    print("authenticated plans in any page. That cannot be right, so the parser has")
    print("drifted from the source rather than the source having become safe. Fix this")
    print("script before trusting a green run.")
    sys.exit(1)

authenticated_requests = len(authed_endpoints) + len(plan_sites)

def declaring_type(text):
    """The union type declaring `SessionExpired`, as (name, whole declaration)."""
    for match in re.finditer(r"^type ([A-Z][A-Za-z0-9_]*)\b(.*?)(?=^\S|\Z)", text, re.M | re.S):
        if re.search(r"^\s*[=|]\s*SessionExpired\b", match.group(2), re.M):
            return match.group(1), match.group(0)
    return None, None

def module_header(text):
    """The `module ... exposing (...)` block, i.e. everything before the doc comment."""
    return text.split("\n\n", 1)[0]

def routes_to_session_expired(text, constructor):
    """Does a `<constructor> ->` case branch produce `SessionExpired`?

    ⚠️ The constructor may CARRY something. An expiry msg often has to say which
    card to settle or which request died — `SessionGoneMidSave placementId` —
    and an expiry branch that takes an argument is still an expiry branch. A
    pattern insisting on a bare constructor forced every expiry handler to be
    nullary, which is a constraint on the page's design rather than on its
    behaviour, and pages worked around it by handling the 401 somewhere this
    gate could not see.
    """
    args = r"(?:\s+[A-Za-z_][A-Za-z0-9_']*)*"
    for match in re.finditer(r"^(\s+)" + re.escape(constructor) + args + r"\s*->\s*$", text, re.M):
        rest = text[match.end():]
        branch = []
        for line in rest.split("\n"):
            if line.strip() and len(line) - len(line.lstrip()) <= len(match.group(1)):
                break
            branch.append(line)
        if "SessionExpired" in "\n".join(branch):
            return True
    return False

findings, in_scope = [], []

for path in sorted(glob.glob(PAGE_GLOB, recursive=True)):
    text = read(path)
    calls = sorted(name for name in authed_endpoints if re.search(r"\bApi\." + name + r"\b", text))
    plans = plans_in(text)
    if plans:
        # Named in the page's own terms, because a plan's endpoint is not always
        # greppable at the call site — `Effect.authed spec token …` passes a
        # spec a line above. What makes the page in scope is that it sends an
        # authenticated request at all.
        calls = calls + [str(plans) + " authenticated plan(s)"]
    if not calls:
        continue

    if path in EXEMPT:
        in_scope.append((path, calls, "exempt"))
        continue

    header = module_header(text)
    type_name, declaration = declaring_type(text)
    body = text[len(header):]
    if declaration:
        body = body.replace(declaration, "")

    if type_name is None:
        in_scope.append((path, calls, "MISSING"))
        findings.append(
            (
                path,
                calls,
                "declares no `SessionExpired` constructor. Add "
                "`type OutMsg = NoOut | SessionExpired`, return it when the authed "
                "request reports expiry, and route it in `Main` to `handleSessionExpiry`.",
            )
        )
        continue

    if not re.search(r"\b" + type_name + r"\(\.\.\)", header):
        in_scope.append((path, calls, "UNEXPOSED"))
        findings.append(
            (
                path,
                calls,
                "declares `SessionExpired` in `" + type_name + "` but does not expose "
                "`" + type_name + "(..)`, so `Main` cannot match on it.",
            )
        )
        continue

    if "SessionExpired" not in body:
        in_scope.append((path, calls, "UNUSED"))
        findings.append(
            (
                path,
                calls,
                "declares and exposes `SessionExpired` but never returns it. The "
                "constructor exists and routes nothing.",
            )
        )
        continue

    handlers = set(re.findall(r"onExpired\s*=\s*([A-Z][A-Za-z0-9_]*)", text))
    unrouted = sorted(c for c in handlers if not routes_to_session_expired(text, c))
    if unrouted:
        in_scope.append((path, calls, "UNROUTED"))
        findings.append(
            (
                path,
                calls,
                "hands an authenticated request an `onExpired` the page does not route "
                "to `SessionExpired`: " + ", ".join(unrouted) + ". The 401 is detected "
                "and then dropped.",
            )
        )
        continue

    in_scope.append((path, calls, "ok"))

stale = sorted(set(EXEMPT) - {path for path, _, _ in in_scope})

if mode == "--list":
    print("Mandatorily-authenticated Api endpoints: " + str(len(authed_endpoints)))
    print("Authenticated request plans in pages: " + str(len(plan_sites)))
    print("Authenticated requests in all: " + str(authenticated_requests))
    print("Pages in scope: " + str(len(in_scope)))
    print("")
    for path, calls, verdict in in_scope:
        print("  [" + verdict + "] " + path)
        print("      " + ", ".join(calls))
    print("")
    for path, reason in sorted(EXEMPT.items()):
        print("  exempt: " + path)
        print("      " + reason)
    sys.exit(0)

# ⚠️ BOTH FLOORS SIT BELOW `--list` DELIBERATELY. A floor that fires is the
# moment someone needs the listing most — "which page left the population?" —
# and a `--list` that refused to list would send them to read this script
# instead of the picture it can print. The parser floor above is the exception:
# a listing built by a drifted parser is not evidence of anything.
# ⛔ A COUNT FLOOR ON THE POPULATION, not an emptiness check — and the reason
# the figure below is a sum.
#
# MEASURED, on the line that used to stand here: `if not authed_endpoints`
# refuses only at ZERO. A change taking 72 matching sites down to ONE passed
# green, classified one endpoint and printed "1 such endpoints in Api.elm" as
# though that were the population. A floor at zero is satisfied by almost-total
# loss, and the printed number was the only tell.
#
# ⚠️ So this number is a RATCHET, and it is meant to be edited by hand when the
# codebase really does have fewer authenticated requests — a deleted feature, a
# consolidated endpoint. Lowering it is a one-line change that says so in the
# diff, which is the whole point: the alternative is a count that drifts down
# quietly while the verdict stays "OK".
#
# ⚖️ The sum is what is floored, not either key. An endpoint moving from
# `Api.Authed` onto a request plan leaves one key and joins the other, so a
# migration holds this number while rearranging what it is made of.
MIN_AUTHENTICATED_REQUESTS = 100

if authenticated_requests < MIN_AUTHENTICATED_REQUESTS:
    print(
        f"FAIL: found {authenticated_requests} authenticated request(s) "
        f"({len(authed_endpoints)} endpoint(s) in " + API + f", {len(plan_sites)} "
        "authenticated plan(s) in pages);",
        file=sys.stderr,
    )
    print(
        f"      expected at least {MIN_AUTHENTICATED_REQUESTS}. Every verdict below is a",
        file=sys.stderr,
    )
    print(
        "      claim about THIS population, so a population that shrank without anyone",
        file=sys.stderr,
    )
    print(
        "      saying so makes the verdict narrower than it reads. Either a key stopped",
        file=sys.stderr,
    )
    print(
        "      matching the source — check `headers = authedHeaders` and `Effect.authed`",
        file=sys.stderr,
    )
    print(
        "      are still spelled that way — or the requests really are gone, in which",
        file=sys.stderr,
    )
    print(
        "      case lower MIN_AUTHENTICATED_REQUESTS in this script and say why.",
        file=sys.stderr,
    )
    sys.exit(1)

# ⛔ THE SECOND FLOOR, on the dimension the verdict line actually reports.
#
# ⚠️ The population floor above cannot catch this one. An endpoint can stay in
# `Api.elm`, keep matching, keep being counted — and stop being CALLED by a
# page. The sum holds, and the printed claim ("all N pages route their 401")
# quietly covers fewer pages. Flooring the pages in scope is what makes a page
# leaving the gate's view read as a change to look at.
MIN_PAGES_IN_SCOPE = 29

if len(in_scope) < MIN_PAGES_IN_SCOPE:
    print("")
    print(
        "FAIL: only "
        + str(len(in_scope))
        + " page(s) are in scope; expected at least "
        + str(MIN_PAGES_IN_SCOPE)
        + "."
    )
    print("A page drops out of scope when it stops making an authenticated request — or")
    print("when it still makes one by a spelling neither key recognises, which looks")
    print("exactly the same from here. Check the page you changed, then lower")
    print("MIN_PAGES_IN_SCOPE in this script if the page really did stop.")
    sys.exit(1)

for path, reason in sorted(EXEMPT.items()):
    print("note: " + path + " is exempt — " + reason)

if stale:
    print("")
    print("FAIL: stale exemption(s). These files no longer make an authed request, or no")
    print("longer exist. An exemption that protects nothing is a claim nobody is checking:")
    for path in stale:
        print("  - " + path)
    sys.exit(1)

if findings:
    print("")
    print(
        "FAIL: "
        + str(len(findings))
        + " page(s) make a mandatorily-authenticated request and drop the 401."
    )
    print("A 401 there means the session is gone. Whatever the page shows instead — ")
    print('"please try again", "refresh to retry" — is telling the reader to do something')
    print("that cannot work.")
    print("")
    for path, calls, reason in findings:
        print("  " + path)
        print("      authed calls: " + ", ".join(calls))
        print("      " + reason)
    print("")
    print("See frontend/src/Api.elm's `Authed` docs, and `Page/Settings/Password.elm` for")
    print("the smallest complete example.")
    sys.exit(1)

print(
    "OK: all "
    + str(len(in_scope) - len(EXEMPT))
    + " pages making mandatorily-authenticated requests route their 401 "
    + "("
    + str(authenticated_requests)
    + " such requests: "
    + str(len(authed_endpoints))
    + " endpoints in Api.elm + "
    + str(len(plan_sites))
    + " authenticated plans in pages)."
)
PY
