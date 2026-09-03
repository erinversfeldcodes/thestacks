#!/usr/bin/env bash
# Can a reader actually GET to every page that exists?
#
# This exists because a whole feature shipped that nobody could reach. `/groups`
# was built, routed, tested and green, and the only thing linking to it was the
# group DETAIL page — which you could only arrive at from `/groups`. A closed
# loop with no way in. Someone could be invited to a group, accept, and then have
# no route back short of remembering the URL.
#
# ⚠️ THE OBVIOUS VERSION OF THIS GATE CANNOT CATCH THAT. Counting inbound
# references passes `/groups`, because it HAS one. Reachability is a graph
# question — start from the surfaces a reader always has, and walk. Anything the
# walk never lands on is unreachable no matter how many times it is mentioned.
#
# The other trap is the route -> page-module map the walk needs. Two regex
# approaches failed before this one: a filename convention misses every nested
# module (the blog pages live at Page/Blog/Archive.elm), and parsing initPage
# loosely produced fourteen false positives including /costs, which is linked
# from the About essay. What works is matching only KNOWN import aliases inside a
# branch bounded at the next branch — an unbounded window bleeds into the next
# route and quietly makes everything look reachable.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import os
import re
import sys

SRC = "frontend/src"
MAIN = os.path.join(SRC, "Main.elm")
ROUTE_MODULE = os.path.join(SRC, "Navigation", "Route.elm")

# The surfaces a reader always has. Everything else must be reachable FROM here.
ROOTS = [MAIN, os.path.join(SRC, "Page", "Home.elm")]

# A route may be legitimately unreachable by link. The entry must say why, and a
# stale entry fails the gate — an exemption for nothing hides the next real one.
EXEMPT = {
    "ConfirmEmail": "arrives from a confirmation email; an in-app link is meaningless",
    "ResetPassword": "arrives from a password-reset email, same reason",
    "ForgotPassword": "a mode of the login page, reached from the sign-in form itself",
    "ResendConfirmation": "a mode of the login page, same reason",
    "NotFound": "the fallback for an unmatched URL; nothing links to it by design",
}

# Routes whose page module neither the branch scan nor the filename conventions
# can find. Validated below: an entry naming a route or file that does not exist
# fails, so this cannot rot into a list nobody remembers.
OVERRIDES = {}

main = open(MAIN, encoding="utf-8").read()
route_src = open(ROUTE_MODULE, encoding="utf-8").read()


def code_only(text):
    """Comments and string literals blanked, line structure preserved.

    Without this the walk passes on prose: `titled "My Groups"` contains the word
    Groups, and so did the comment explaining why Groups needed a nav entry.
    Either one convinced an earlier version that the route was linked while it
    demonstrably was not.
    """
    text = re.sub(r"\{-.*?-\}", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r"--[^\n]*", lambda m: " " * len(m.group(0)), text)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', lambda m: " " * len(m.group(0)), text)
    return text


routes = [
    line.strip().lstrip("=|").strip().split()[0]
    for line in re.search(r"^type Route\b(.*?)(?=\n\n)", route_src, re.S | re.M).group(1).split("\n")
    if line.strip().startswith(("=", "|"))
]

parser_paths = {}
for ctor, body in re.findall(r"Parser\.map\s+(?:Route\.)?(\w+)\s+\(([^)]*)\)", route_src):
    segs = re.findall(r's\s+"([^"]+)"', body)
    if segs:
        parser_paths[ctor] = "/" + "/".join(segs)
# `Parser.map Home Parser.top` has no segments, so the pattern above cannot see
# it and the root looked unreachable — the one page every reader starts on.
for ctor in re.findall(r"Parser\.map\s+(?:Route\.)?(\w+)\s+Parser\.top", route_src):
    parser_paths[ctor] = "/"

alias_to_file = {}
for module, alias in re.findall(r"^import\s+(Page\.[\w.]+)\s+as\s+(\w+)", main, re.M):
    path = os.path.join(SRC, *module.split(".")) + ".elm"
    if os.path.isfile(path):
        alias_to_file[alias] = path

BRANCH = re.compile(r"^        ([A-Z]\w*)(?:\s+[\w_]+)*\s*->\s*$")
lines = main.split("\n")


def camel_split_path(route):
    """`BlogPost` -> Page/Blog/Post.elm, `AdminInvites` -> Page/Admin/Invites.elm."""
    m = re.match(r"([A-Z][a-z]+)([A-Z]\w*)$", route)
    if not m:
        return None
    return os.path.join(SRC, "Page", m.group(1), m.group(2)) + ".elm"


def page_files_for(route):
    if route in OVERRIDES:
        return [OVERRIDES[route]]

    found = set()
    for i, line in enumerate(lines):
        m = BRANCH.match(line)
        if not m or m.group(1) != route:
            continue
        body = []
        for nxt in lines[i + 1 :]:
            if BRANCH.match(nxt):
                break
            if nxt.strip() and not nxt.startswith("         "):
                break
            body.append(nxt)
        for alias in re.findall(r"\b(\w+)\.", "\n".join(body)):
            if alias in alias_to_file:
                found.add(alias_to_file[alias])
    if found:
        return sorted(found)

    for cand in (os.path.join(SRC, "Page", route) + ".elm", camel_split_path(route)):
        if cand and os.path.isfile(cand):
            return [cand]
    return []


texts = {}


def read(path):
    if path not in texts:
        texts[path] = open(path, encoding="utf-8").read()
    return texts[path]


def links_to(text, route):
    """Whether `text` offers a way TO route — not merely mentions it."""
    code = code_only(text)
    if re.search(rf"toPath\s+\(?\s*(?:Route\.)?{route}\b", code):
        return True
    path = parser_paths.get(route)
    if path and re.search(rf'href\s+"{re.escape(path)}"', text):
        return True
    for line in code.split("\n"):
        # `import Page.Groups as Groups` names a module, not the route; so does
        # `Groups.NoOut`. Missing this made every route sharing a name with a page
        # module look linked.
        if line.lstrip().startswith(("import ", "module ")):
            continue
        if not re.search(rf"\b(?:Route\.)?{route}\b(?!\.)", line):
            continue
        # A case branch HANDLES a route; it does not offer a way to it.
        if re.match(rf"\s*\|?\s*(?:Route\.)?{route}\b[^-]*->", line):
            continue
        return True
    return False


reachable = set(EXEMPT)
frontier = [p for p in ROOTS if os.path.isfile(p)]
seen = set(frontier)

while frontier:
    nxt = []
    for f in frontier:
        text = read(f)
        for route in routes:
            if route in reachable or not links_to(text, route):
                continue
            reachable.add(route)
            for pf in page_files_for(route):
                if pf not in seen:
                    seen.add(pf)
                    nxt.append(pf)
    frontier = nxt

unreachable = [(r, parser_paths.get(r) or "(no literal path)") for r in routes if r not in reachable]
stale = [r for r in EXEMPT if r not in routes]
stale += [r for r in OVERRIDES if r not in routes or not os.path.isfile(OVERRIDES[r])]

failed = False

if unreachable:
    failed = True
    print(f"FAIL: {len(unreachable)} route(s) a reader cannot get to:", file=sys.stderr)
    for route, path in unreachable:
        print(f"  {route:<28} {path}", file=sys.stderr)
    print(
        "\nEach of these exists and is routed, but nothing a reader can reach links\n"
        "to it — it may still be MENTIONED, including from a page that is itself\n"
        "only reachable through it. Link it from where someone would look, or add\n"
        "it to EXEMPT in this script with the reason it is deliberately URL-only.",
        file=sys.stderr,
    )

if stale:
    failed = True
    print(f"FAIL: {len(stale)} stale EXEMPT/OVERRIDE entr(ies):", file=sys.stderr)
    for r in stale:
        print(f"  {r}", file=sys.stderr)

if not failed:
    print(f"OK: all {len(routes) - len(EXEMPT)} linkable route(s) are reachable from the chrome or the home.")

sys.exit(1 if failed else 0)
PY
