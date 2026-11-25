#!/usr/bin/env bash
# No module but Effect.elm may hand-build a credential-bearing Http.request.
#
# ⛔ WHY. Every request the client sends travels as a RequestSpec, whose url is
# an `Api.Url.SameOriginUrl` — an opaque type constructed only where the
# same-origin fact is known, so the compiler proves on every build that a
# RequestSpec cannot carry a credential to a cross-origin host. But that proof
# covers only the path THROUGH the type. A hand-built `Http.request` takes a
# bare `String` url and a bare header list, so a page that writes
# `Http.request { … headers = Api.planHeaders … }` sends the session credential
# to a url nothing checked — the escape hatch AROUND the type. Measured, not
# hypothetical: swapping one page's `headers = []` for a credential helper
# compiled, 2270 tests passed, and all 19 Elm gates passed.
#
# So this gate holds the line the type cannot: a credential helper
# (`planHeaders` / `bearerHeader` / `cookieSession`) and `Http.request` may meet
# in ONE module, `Effect.elm`, which is where a RequestSpec's credential is
# resolved onto the wire. Anywhere else, route through `Effect.authed` /
# `Effect.public` instead — a RequestSpec, whose url is proven same-origin.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import re
import sys

# The one module allowed to put a resolved credential onto an Http.request.
ALLOWLIST = {"frontend/src/Effect.elm"}

# The helpers that carry a credential into a request's headers. `authHeaders` is
# listed though it does not exist today: if it is ever (re)introduced as a
# credential helper, this gate should already see it rather than wait for the
# list to be updated by hand.
HELPERS = re.compile(r"\b(planHeaders|bearerHeader|cookieSession|authHeaders)\b")
REQUEST = re.compile(r"\bHttp\.request\b")

# Anti-vacuity: the real tree is ~100 modules; a scan that finds far fewer has a
# broken glob or cwd and must refuse rather than pass empty.
MIN_ELM_FILES = 80


def code_only(text):
    # Strip comments BEFORE matching. This file's own prose names `Http.request`
    # and the helpers, and `Api.elm` carries a comment reading "THE LAST
    # Http.request IN THIS MODULE" long after the call itself was removed — a
    # gate that read comments would flag that dead reference as a live request.
    text = re.sub(r"\{-.*?-\}", "", text, flags=re.S)
    text = re.sub(r"^[ \t]*--.*$", "", text, flags=re.M)
    return text


files = sorted(glob.glob("frontend/src/**/*.elm", recursive=True))
if len(files) < MIN_ELM_FILES:
    print(
        f"FAIL check-hand-built-credential-request: scanned {len(files)} .elm file(s); "
        f"floor is {MIN_ELM_FILES}. A vacuous scan is a refusal, not a pass.",
        file=sys.stderr,
    )
    sys.exit(1)

tripping = {}
for f in files:
    code = code_only(open(f, encoding="utf-8").read())
    if REQUEST.search(code):
        helpers = sorted(set(HELPERS.findall(code)))
        if helpers:
            tripping[f] = helpers

# ⛔ Anti-vacuity #2: the sanctioned site MUST still trip. If `Effect.elm` stops
# matching, the detection has broken (comments over-stripped, a helper renamed,
# the file moved) and an empty violation list would be a FALSE pass over a scan
# that no longer sees the one site it was built around. An allowlist entry that
# protects nothing is the exact shape this repository keeps catching.
missing = sorted(a for a in ALLOWLIST if a not in tripping)
if missing:
    print(
        "FAIL check-hand-built-credential-request: an allowlisted credential-request "
        "site no longer trips the scan:",
        file=sys.stderr,
    )
    for m in missing:
        print(f"  {m}", file=sys.stderr)
    print(
        "The detection stopped matching (a renamed helper, a moved file, an over-eager "
        "comment strip) — a stale allowlist would hide that. Fix the scan or the allowlist.",
        file=sys.stderr,
    )
    sys.exit(1)

violations = {f: h for f, h in tripping.items() if f not in ALLOWLIST}
if violations:
    print(
        "FAIL check-hand-built-credential-request: a module outside Effect.elm hand-builds "
        "a credential-bearing Http.request — the SameOriginUrl type proves nothing about a "
        "bare-String Http.request:",
        file=sys.stderr,
    )
    for f, h in sorted(violations.items()):
        print(f"  {f}  (Http.request + {', '.join(h)})", file=sys.stderr)
    print(
        "Route it through Effect.authed / Effect.public (a RequestSpec, url proven "
        "same-origin), or — if it genuinely belongs — add it to ALLOWLIST with a written reason.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"check-hand-built-credential-request: OK ({len(files)} .elm scanned; "
    f"{len(tripping)} credential-request site(s), all {len(ALLOWLIST)} sanctioned: "
    f"{', '.join(sorted(ALLOWLIST))})."
)
PY
