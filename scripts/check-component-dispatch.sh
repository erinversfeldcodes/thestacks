#!/usr/bin/env bash
# A component that exposes `update` is a component that expects to be driven.
# If nothing dispatches to it, its messages can never arrive — the feature is
# present, compiles, and is unreachable.
#
# This exists because that failure is invisible to everything else we run. A
# merge once dropped a whole feature's wiring out of Main.elm — the import, the
# model field, the Msg variant, the update branch and the view call — and
# `elm make` was green, 1945 elm-tests were green, and the only thing that
# noticed was elm-review complaining that an export had become unused. Compilers
# check that what you wrote type-checks, not that anyone calls it.
#
# The roster is DISCOVERED, never listed: every module under Components/ whose
# exposing line offers `update` or `updateWithEffect`. Adding a component adds it
# to the check automatically, which is the property that makes the gate outlive
# the person who wrote it.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import os
import re
import sys

SRC = "frontend/src"

# A component may be deliberately undispatched. The entry must name WHY, and it
# can only excuse a component that exists — a stale entry fails the gate rather
# than silently excusing nothing, so this map cannot rot into a list of names
# nobody remembers.
EXEMPT = {}


def exposing_line(path):
    """The module's exposing list, read by counting parens rather than by regex.

    A non-greedy `(.*?)` stops at the first `)`, which in Elm is usually the one
    inside `Msg(..)` — so it silently returns a truncated list and the gate
    checks less than it claims to. That is the failure this whole script exists
    to prevent, so it is worth the extra lines here.
    """
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    start = text.find("exposing")
    if start == -1:
        return ""
    open_paren = text.find("(", start)
    if open_paren == -1:
        return ""

    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
    return ""


def module_name(path):
    rel = os.path.relpath(path, SRC)
    return rel[:-4].replace(os.sep, ".") if rel.endswith(".elm") else rel


drivable = {}
for path in sorted(glob.glob(f"{SRC}/Components/**/*.elm", recursive=True)):
    exposed = exposing_line(path)
    offered = [n for n in ("updateWithEffect", "update") if re.search(rf"\b{n}\b", exposed)]
    if offered:
        drivable[module_name(path)] = (path, offered)

# A dispatcher is any OTHER module that calls one of those functions. Derived
# from the call sites themselves rather than from a list of known dispatchers,
# so a component driven from a page counts exactly as much as one driven from
# Main — the question is whether anything drives it, not who.
sources = [
    p for p in glob.glob(f"{SRC}/**/*.elm", recursive=True) if os.path.isfile(p)
]

def local_names_for(body, module):
    """Every name `module` can be called by INSIDE this file.

    Elm lets you rename on import, and this codebase does it constantly
    (`import Components.PlacementCard as Card`). Matching only the module's own
    last segment would report every aliased component as undispatched — a gate
    that cries wolf gets switched off, so the alias has to be resolved rather
    than assumed away.
    """
    names = {module, module.split(".")[-1]}
    for alias in re.findall(rf"^import\s+{re.escape(module)}\s+as\s+([\w.]+)", body, re.M):
        names.add(alias)
    return names


orphans = []
for module, (path, offered) in sorted(drivable.items()):
    dispatched = False
    for candidate in sources:
        if os.path.abspath(candidate) == os.path.abspath(path):
            continue
        with open(candidate, encoding="utf-8") as handle:
            body = handle.read()
        # Only a file that imports the module can dispatch to it; this also stops
        # a same-named function on an unrelated module counting as a dispatch.
        if not re.search(rf"^import\s+{re.escape(module)}\b", body, re.M):
            continue
        for name in local_names_for(body, module):
            if any(re.search(rf"\b{re.escape(name)}\.{fn}\b", body) for fn in offered):
                dispatched = True
                break
        if dispatched:
            break
    if not dispatched and module not in EXEMPT:
        orphans.append((module, path, offered))

stale = [m for m in EXEMPT if m not in drivable]

failed = False

if orphans:
    failed = True
    print(
        f"FAIL: {len(orphans)} component(s) expose an update function that nothing dispatches:",
        file=sys.stderr,
    )
    for module, path, offered in orphans:
        print(f"  {module:<44} exposes {'/'.join(offered)}  ({path})", file=sys.stderr)
    print(
        "\nA component with an update nobody calls cannot receive its own messages — the\n"
        "feature is present and unreachable. Either wire it up where it belongs, or add\n"
        "it to EXEMPT in this script with the reason it is deliberately undriven.",
        file=sys.stderr,
    )

if stale:
    failed = True
    print(
        f"FAIL: {len(stale)} EXEMPT entr(ies) name a component that no longer exposes an update:",
        file=sys.stderr,
    )
    for module in stale:
        print(f"  {module}", file=sys.stderr)
    print("Remove the entry — an exemption for nothing hides the next real one.", file=sys.stderr)

if not failed:
    print(f"OK: all {len(drivable)} drivable component(s) are dispatched.")

sys.exit(1 if failed else 0)
PY
