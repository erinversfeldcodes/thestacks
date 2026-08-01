#!/usr/bin/env bash
# check-session-expiry-coverage.sh — every page that makes a mandatorily-authenticated
# `Api.*` call must route a 401 to the global session-expiry interceptor (Issue #361).
#
# WHY THIS EXISTS
#
# A 401 on a request that definitely carried a credential means one thing: the session is
# gone. Answering it with "Please try again" is a lie — retrying cannot work, and the
# reader retypes a password into a form whose session no longer exists. `Page/Settings/`
# `Password`, `Profile` and `Notifications` each did exactly that, driven live 2026-07-30.
#
# ⚠️ **There was already a test for this, and it was green the whole time.**
# `frontend/tests/Page/SessionExpiryPagesTest.elm` (#178) asserts the contract on EIGHT
# pages, named by hand in its import list. The three above were not among them. That is
# the failure mode this gate exists to remove: a hand-written roster of covered pages
# cannot report what is missing from it, because what is missing from it is the report.
# The project has paid for this twice already (#173/#178, then #303/#309).
#
# THE RULE, AND HOW THE ROSTER IS DERIVED
#
# Nothing here is a list of pages. The roster is a set difference, recomputed on every run:
#
#   1. Read `frontend/src/Api.elm`. An endpoint is MANDATORILY AUTHENTICATED when its
#      `Authorization` header is unconditional — `headers = authedHeaders ...` (the #361
#      wrapper) or the legacy `headers = [ Http.header "Authorization" ... ]`.
#
#      Optional-auth endpoints are excluded, and the distinction is the whole point:
#      `headers = authHeaders maybeToken` (or an inline `case maybeToken of`) means the
#      request is valid anonymously, so its 401 is NOT an expiry signal and must not be
#      routed as one. `getProfile`, `getListings`, `getBlogPosts` and `searchUsers` are
#      in that group.
#
#   2. Read every module under `frontend/src/Page/`. A page is IN SCOPE when it names any
#      endpoint from (1).
#
#   3. Every in-scope page must (a) declare a `SessionExpired` constructor, (b) expose its
#      type with `(..)` so `Main` can match on it, and (c) actually return it somewhere.
#      (c) matters: declaring the constructor and never using it compiles, satisfies a
#      grep, and routes nothing.
#
#   4. Every `onExpired = <Ctor>` handed to `Api.authed` must name a message the page
#      routes to `SessionExpired`. This is the link no Elm test can reach — the `Cmd` that
#      carries the handler is opaque, so `ApiAuthedTest` can prove "a 401 produces
#      `onExpired`" and `SessionExpiryPagesTest` can prove "the expiry message produces
#      `SessionExpired`", and neither can prove they are the same message.
#
# A page added tomorrow is checked the moment it makes an authed call. Nobody edits a list.
#
# EXEMPTIONS
#
# `EXEMPT` below is an exemption map, NOT a coverage roster — the direction matters. It can
# only ever remove NAMED files that already exist; it can never cause a new page to go
# unchecked, which is the rot that killed the hand-written list. Each entry carries its
# reason and the gate prints them on every run, so an exemption cannot go quiet.
#
# Usage:
#   scripts/check-session-expiry-coverage.sh          # fail if any authed page drops a 401
#   scripts/check-session-expiry-coverage.sh --list   # every page in scope and its verdict
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

# See EXEMPTIONS in the header. Only ever shrinks the checked set, and only for a file
# that must already exist — a stale entry is itself a failure.
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


# ---- 1. which Api endpoints carry a credential unconditionally ---------------------

MANDATORY = re.compile(
    r"headers\s*=\s*(authedHeaders\b|\[\s*Http\.header\s+\"Authorization\")"
)
OPTIONAL = re.compile(r"headers\s*=\s*(authHeaders\b|$)", re.M)

api_text = read(API)
authed_endpoints = set()
for name, body in top_level_definitions(api_text).items():
    if name in ("authedHeaders", "authHeaders"):
        # The header builders themselves, not endpoints.
        continue
    if MANDATORY.search(body) and not OPTIONAL.search(body):
        authed_endpoints.add(name)

if not authed_endpoints:
    print("FAIL: found no mandatorily-authenticated endpoints in " + API + ".")
    print("That cannot be right, so the parser has drifted from the source rather than")
    print("the source having become safe. Fix this script before trusting a green run.")
    sys.exit(1)


# ---- 2/3/4. every page that calls one must route its 401 ---------------------------


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
    """Does a `<constructor> ->` case branch produce `SessionExpired`?"""
    for match in re.finditer(r"^(\s+)" + re.escape(constructor) + r"\s*->\s*$", text, re.M):
        rest = text[match.end():]
        branch = []
        for line in rest.split("\n"):
            # A line at or left of the branch's own indent ends it.
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
    if not calls:
        continue

    if path in EXEMPT:
        in_scope.append((path, calls, "exempt"))
        continue

    header = module_header(text)
    type_name, declaration = declaring_type(text)
    # Neither the `exposing (...)` list nor the type declaration counts as USING the
    # constructor — both are satisfied by a page that declares it and routes nothing.
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
                "hands `Api.authed` an `onExpired` the page does not route to "
                "`SessionExpired`: " + ", ".join(unrouted) + ". The 401 is detected and "
                "then dropped.",
            )
        )
        continue

    in_scope.append((path, calls, "ok"))

stale = sorted(set(EXEMPT) - {path for path, _, _ in in_scope})

if mode == "--list":
    print("Mandatorily-authenticated Api endpoints: " + str(len(authed_endpoints)))
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

for path, reason in sorted(EXEMPT.items()):
    print("note: " + path + " is exempt — " + reason)

if stale:
    print("")
    print("FAIL: stale exemption(s). These files no longer make an authed Api call, or no")
    print("longer exist. An exemption that protects nothing is a claim nobody is checking:")
    for path in stale:
        print("  - " + path)
    sys.exit(1)

if findings:
    print("")
    print(
        "FAIL: "
        + str(len(findings))
        + " page(s) make a mandatorily-authenticated Api call and drop the 401."
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
    + " pages making mandatorily-authenticated Api calls route their 401 "
    + "("
    + str(len(authed_endpoints))
    + " such endpoints in Api.elm)."
)
PY
