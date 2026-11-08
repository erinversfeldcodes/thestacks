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

SRC = "frontend/src/**/*.elm"

SHORTHAND = re.compile(r"\bHttp\.(get|post)\s*$|\bHttp\.(get|post)\s*\{", re.M)
REQUEST = re.compile(r"\bHttp\.request\b")
TIMEOUT = re.compile(r"^\s*,?\s*timeout\s*=\s*(.+?)\s*$", re.M)

def blank_comments(text):
    """Replace every comment's contents with spaces, preserving line structure.

    Prose describing a rule is not an instance of breaking it: the doc comment on
    `Page.CostTransparency.fetchCosts` explains why it is `Http.request` and not `Http.get`,
    and a naive scan read that sentence as a finding. Line numbers are preserved so the
    report still points at real source lines.
    """
    out, index, depth = [], 0, 0
    while index < len(text):
        two = text[index : index + 2]
        if depth == 0 and two == "--":
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            out.append(" " * (end - index))
            index = end
        elif two == "{-":
            depth += 1
            out.append("  ")
            index += 2
        elif two == "-}" and depth > 0:
            depth -= 1
            out.append("  ")
            index += 2
        else:
            out.append(text[index] if (depth == 0 or text[index] == "\n") else " ")
            index += 1
    return "".join(out)

sites, findings = [], []

for path in sorted(glob.glob(SRC, recursive=True)):
    with open(path, encoding="utf-8") as handle:
        lines = blank_comments(handle.read()).split("\n")

    for number, line in enumerate(lines, start=1):
        if SHORTHAND.search(line):
            findings.append(
                (
                    path,
                    number,
                    "uses `Http.get`/`Http.post`, which have no `timeout` field — the request "
                    "is unbounded by construction. Rewrite as `Http.request` with an explicit "
                    "`timeout`.",
                )
            )

        if REQUEST.search(line):
            named, depth, started = None, 0, False
            for follow in lines[number - 1 :]:
                depth += follow.count("{") - follow.count("}")
                started = started or "{" in follow
                if started and depth <= 0:
                    break
                match = TIMEOUT.match(follow)
                if match:
                    named = match.group(1)
                    break
            if named is None:
                findings.append(
                    (path, number, "`Http.request` record names no `timeout` field.")
                )
            elif named == "Nothing":
                findings.append(
                    (
                        path,
                        number,
                        "`timeout = Nothing` — that is not 'unset', it is 'wait forever'. Use "
                        "`Api.standardTimeout` (or `Api.uploadTimeout` for a file body).",
                    )
                )
            else:
                sites.append((path, number, named))

# ⛔ THE BRANCHES BEING RIGHT IS HALF THE CLAIM. THE OTHER HALF IS THAT ANYTHING
# CALLS THEM, AND WITHOUT IT THIS GATE STAYS GREEN ON THE EXACT REGRESSION IT
# NAMES.
#
# MEASURED by the platform reviewer, 2026-11-08: changing `Effect.elm`'s
# `timeout = Api.specTimeout plan.spec` to `timeout = Api.standardTimeout`
# printed "OK: all 3 HTTP request(s) … are bounded in time" and exited 0. The
# outer scan accepts it because `Api.standardTimeout` is a named, non-`Nothing`
# value, so the site counts as bounded. `ApiSpecTimeoutTest.elm` cannot see it
# either — it calls `specTimeout` directly, never through `Effect.perform`.
#
# ⚖️ So the fix was still "one refactor from being undone", which is the
# sentence the block above was written to retire. Every request in the client
# now goes through one `Http.request`, so there is exactly one site to check.
#
# ⛔ THESE COLLECT RATHER THAN EXIT. `lint-elm.sh` was deliberately restructured
# so one run tells you everything instead of peeling failures off one per run,
# and a gate that exits at its first problem makes the reader re-run to find the
# second. Both paths still exit 1; the difference is how much you learn per run.
shape_problems = []
interpreter = ""
for path in glob.glob("frontend/src/Effect.elm"):
    with open(path, encoding="utf-8") as handle:
        interpreter = blank_comments(handle.read())

if not interpreter:
    shape_problems.append(
        "frontend/src/Effect.elm not found, so the plan interpreter went unchecked.\n"
        "Every request reaches the network through it; if it moved, update this check in\n"
        "the same change, because nothing else asserts the timeout is derived at all."
    )
elif not re.search(r"timeout\s*=\s*Api\.specTimeout\b", interpreter):
    shape_problems.append(
        "the plan interpreter does not derive its timeout from Api.specTimeout.\n"
        "`Api.specTimeout` can be perfectly correct and still unused. Hardcoding a\n"
        "timeout here sends every file body with the standard 15s instead of 120s —\n"
        "large uploads cut to an eighth of their budget on a slow connection — and the\n"
        "scan below still reports OK, because a hardcoded name is 'bounded'."
    )

if not sites and not findings:
    print("FAIL: found no HTTP requests under " + SRC + " at all.")
    print("That cannot be right, so this script has drifted from the source rather than the")
    print("source having become safe. Fix the script before trusting a green run.")
    sys.exit(1)

if mode == "--list":
    for path, number, named in sites:
        print("  " + path + ":" + str(number) + "  timeout = " + named)
    print("")
    print("bounded requests: " + str(len(sites)))
    sys.exit(0)

# ⛔ THE PLAN INTERPRETER'S TIMEOUT IS DECIDED BY `Api.specTimeout`, AND NO TEST
# CAN REACH HALF OF IT. Every request now goes through `Effect.perform`, which
# asks `Api.specTimeout plan.spec`; that function returns `uploadTimeout` for the
# two file-carrying bodies and `standardTimeout` otherwise.
#
# ⚠️ `elm/file`'s `File` is opaque with only a decoder — `type File = File`, no
# constructor — so an Elm unit test cannot build one, and the `FileBody` and
# `MultipartFile` branches are unreachable from `elm-test`. MEASURED: cutting
# `FileBody` to `standardTimeout` left 2270 tests green.
#
# That matters because the branch exists to fix a real regression: the upload PUT
# carried `uploadTimeout` (120s) and the plan interpreter hardcoded
# `standardTimeout` (15s), which would have cut large uploads to an eighth of
# their time on a slow connection. A fix no test can see is one refactor from
# being undone, so the shape is checked HERE instead.
api_src = ""
for path in glob.glob("frontend/src/Api.elm"):
    with open(path, encoding="utf-8") as handle:
        api_src = blank_comments(handle.read())

spec_timeout = re.search(
    r"^specTimeout\s*:.*?\n(.*?)(?=\n\n\n|\nspecHttpBody)", api_src, re.S | re.M
)

if not spec_timeout:
    shape_problems.append(
        "Api.specTimeout not found, so its file-body branches went unchecked.\n"
        "If it was renamed or inlined, update this check in the same change — the\n"
        "branches it guards are unreachable from elm-test and have no other cover."
    )

body = spec_timeout.group(1) if spec_timeout else ""

# ⛔ THE FILE-CARRYING CONSTRUCTORS ARE DERIVED FROM THE TYPE, NOT LISTED HERE.
# This pair used to be a literal `("FileBody", "MultipartFile")` while
# `Api.RequestBody` was declared elsewhere, so a constructor added later was
# unguarded. MEASURED: adding `| BlobBody File` with a `BlobBody _ ->
# standardTimeout` branch passed, exit 0.
#
# ⚖️ "Carries a file" is the actual rule, and it is readable off the
# declaration: any constructor whose argument list mentions `File`. Deriving it
# means the guard grows with the type instead of waiting for someone to
# remember this script.
body_type = re.search(r"^type RequestBody\b(.*?)(?=\n\n)", api_src, re.S | re.M)

if not body_type:
    shape_problems.append(
        "Api.RequestBody not found, so the file-carrying constructors could not be\n"
        "derived. If the type was renamed, update this check in the same change."
    )

file_constructors = (
    [
        m.group(1)
        for m in re.finditer(r"[=|]\s*([A-Z][A-Za-z0-9_]*)([^=|\n]*)", body_type.group(1))
        if "File" in m.group(2)
    ]
    if body_type
    else []
)

if body_type and not file_constructors:
    shape_problems.append(
        "no file-carrying constructor found on Api.RequestBody.\n"
        "Either the type changed shape or this derivation has drifted; a scan that finds\n"
        "nothing to check must not pass, because it looks identical to one that passed."
    )

for constructor in file_constructors:
    clause = re.search(
        r"^\s*" + constructor + r"[^\n]*->\s*\n\s*([A-Za-z_][A-Za-z0-9_.]*)", body, re.M
    )
    if not clause:
        shape_problems.append(
            "Api.specTimeout has no " + constructor + " branch.\n"
            "A file-carrying request would fall through to the standard 15s timeout,\n"
            "which is the regression this branch exists to prevent."
        )
    elif clause.group(1) != "uploadTimeout":
        shape_problems.append(
            "Api.specTimeout returns "
            + clause.group(1)
            + " for "
            + constructor
            + ", not uploadTimeout.\n"
            "A request carrying a file needs the long timeout BECAUSE it carries a file.\n"
            "elm-test cannot catch this: `File` has no constructor, so the branch is\n"
            "unreachable from a unit test and stays green when it is wrong."
        )

# ⚖️ Both sections report before either exits, so one run names every problem.
if shape_problems:
    print("FAIL: " + str(len(shape_problems)) + " problem(s) with how the timeout is derived.")
    print("")
    for problem in shape_problems:
        for i, line in enumerate(problem.split("\n")):
            print(("  - " if i == 0 else "    ") + line)
        print("")

if findings:
    print("FAIL: " + str(len(findings)) + " unbounded HTTP request(s) under frontend/src/.")
    print("A request that can hang forever makes its page's `Failure` branch unreachable: the")
    print("reader is left on a spinner with no end and no explanation.")
    print("")
    for path, number, reason in findings:
        print("  " + path + ":" + str(number))
        print("      " + reason)

# ⛔ ONE EXIT FOR BOTH SECTIONS, and this line is load-bearing. While the shape
# checks exited inline it did not matter; now that they collect, an exit keyed
# only on `findings` would print OK and return 0 for a run whose ONLY problem is
# the derivation — the exact case this file exists for.
if shape_problems or findings:
    sys.exit(1)

print(
    "OK: all "
    + str(len(sites))
    + " HTTP request(s) under frontend/src/ are bounded in time."
)
PY
