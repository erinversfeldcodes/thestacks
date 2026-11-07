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
    print("FAIL: Api.specTimeout not found, so its file-body branches went unchecked.")
    print("If it was renamed or inlined, update this check in the same change — the")
    print("branches it guards are unreachable from elm-test and have no other cover.")
    sys.exit(1)

body = spec_timeout.group(1)
for constructor in ("FileBody", "MultipartFile"):
    clause = re.search(
        r"^\s*" + constructor + r"[^\n]*->\s*\n\s*([A-Za-z_][A-Za-z0-9_.]*)", body, re.M
    )
    if not clause:
        print("FAIL: Api.specTimeout has no " + constructor + " branch.")
        print("A file-carrying request would fall through to the standard 15s timeout,")
        print("which is the regression this branch exists to prevent.")
        sys.exit(1)
    if clause.group(1) != "uploadTimeout":
        print(
            "FAIL: Api.specTimeout returns "
            + clause.group(1)
            + " for "
            + constructor
            + ", not uploadTimeout."
        )
        print("A request carrying a file needs the long timeout BECAUSE it carries a file.")
        print("elm-test cannot catch this: `File` has no constructor, so the branch is")
        print("unreachable from a unit test and stays green when it is wrong.")
        sys.exit(1)

if findings:
    print("FAIL: " + str(len(findings)) + " unbounded HTTP request(s) under frontend/src/.")
    print("A request that can hang forever makes its page's `Failure` branch unreachable: the")
    print("reader is left on a spinner with no end and no explanation.")
    print("")
    for path, number, reason in findings:
        print("  " + path + ":" + str(number))
        print("      " + reason)
    sys.exit(1)

print(
    "OK: all "
    + str(len(sites))
    + " HTTP request(s) under frontend/src/ are bounded in time."
)
PY
