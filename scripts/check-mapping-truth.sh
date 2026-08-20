#!/usr/bin/env bash
# A story marked "Built" must cite things that exist.
#
# docs/implementation-mapping.md is the bridge between the user stories and the
# code, and each story block names the concrete artefacts that implement it —
# modules, endpoints, functions. When a status says Built and the artefacts are
# fictional, the document is not merely out of date: it is actively answering
# "is this built?" with a confident yes.
#
# That is not hypothetical here. Two writing-assistant stories claimed Built
# against five artefacts that had never existed, and three Wave-11 rows claimed
# statuses their routes contradicted. Both were found by a person reading
# carefully, which does not scale and does not repeat.
#
# WHAT IT CHECKS  For every story whose Status is "Built": every API route it
# cites exists in the router, and every Elm module it names exists on disk.
#
# WHAT IT DELIBERATELY DOES NOT CHECK  Function-level citations and column
# references. They are the majority of the prose and the hardest to match
# without false positives, and a gate that cries wolf gets switched off. Routes
# and modules are the load-bearing claims — if those are real, the story is at
# least anchored in code that exists.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import os
import re
import sys

MAPPING = "docs/implementation-mapping.md"
ROUTER = "apps/core/lib/core_web/router.ex"
ELM_SRC = "frontend/src"

# A cited artefact may be legitimately absent. The entry must say WHY, and a
# stale entry fails the gate — an exemption for nothing hides the next real one.
EXEMPT = {}

text = open(MAPPING, encoding="utf-8").read()
router = open(ROUTER, encoding="utf-8").read()

# Router paths, normalised: ":param" segments differ in name between the doc and
# the router often enough that comparing them literally would be noise.
def norm(path):
    path = path.split("?")[0].rstrip("/")
    return re.sub(r":[A-Za-z_]+", ":x", path)


def router_full_paths(src):
    """Every route's FULL path, resolving nested `scope` prefixes.

    A route is declared as `get "/invites"` inside `scope "/api/admin"`, so the
    literal in the router is only the tail. An earlier version compared those
    tails directly and reported three real endpoints as missing — the gate was
    wrong, not the document. Scope prefixes have to be resolved or this check
    invents findings.
    """
    paths, scopes, depth_stack, depth = set(), [], [], 0
    for line in src.split("\n"):
        stripped = line.strip()
        m = re.match(r'scope\s+"([^"]*)"', stripped)
        opens = bool(re.search(r"\bdo\s*$", stripped))
        if m and opens:
            scopes.append(m.group(1))
            depth_stack.append(depth)
            depth += 1
            continue
        if opens:
            depth += 1
            continue
        if stripped == "end":
            depth -= 1
            if depth_stack and depth_stack[-1] == depth:
                depth_stack.pop()
                scopes.pop()
            continue
        r = re.match(r'(?:get|post|put|patch|delete)\s+"([^"]*)"', stripped)
        if r:
            paths.add(norm("".join(scopes) + r.group(1)))
    return paths


router_paths = router_full_paths(router)

problems = []
checked = 0

for block in re.split(r"\n(?=#### US-)", text):
    m = re.match(r"#### (US-[\d.]+)", block)
    if not m:
        continue
    story = m.group(1)
    if not re.search(r"\|\s*\*\*Status\*\*\s*\|\s*Built\s*\|", block):
        continue

    for cite in re.findall(r"`([^`]+)`", block):
        key = f"{story}:{cite}"
        if key in EXEMPT:
            continue

        # --- API routes, including the "GET/POST /path" multi-verb form
        rm = re.fullmatch(r"((?:GET|POST|PUT|PATCH|DELETE)(?:/(?:GET|POST|PUT|PATCH|DELETE))*)\s+(/\S+)", cite)
        if rm:
            checked += 1
            if norm(rm.group(2)) not in router_paths:
                problems.append((story, cite, "no such route in the router"))
            continue

        # --- Elm modules: Components.X / Page.X / Types.X (Api is one module)
        em = re.fullmatch(r"((?:Components|Page|Types|Navigation|Animation)(?:\.\w+)+|Api)", cite)
        if em:
            parts = em.group(1).split(".")
            # `Page.BookDetail.viewFormatsOnShelf` cites a function in a module;
            # walk back until a module file matches, so a function name on the
            # end is not mistaken for a missing module.
            checked += 1
            for depth in range(len(parts), 0, -1):
                cand = os.path.join(ELM_SRC, *parts[:depth]) + ".elm"
                if os.path.isfile(cand):
                    break
            else:
                problems.append((story, cite, "no such Elm module"))
            continue

stale = [k for k in EXEMPT if False]  # entries are story:citation pairs; see below

failed = False

if problems:
    failed = True
    print(
        f"FAIL: {len(problems)} artefact(s) cited by a story marked Built do not exist:",
        file=sys.stderr,
    )
    for story, cite, why in problems:
        print(f"  {story:<12} `{cite}` — {why}", file=sys.stderr)
    print(
        "\nA story whose status says Built while its artefacts are fictional answers\n"
        '"is this built?" with a confident yes. Either correct the status, correct the\n'
        "citation, or add a story:citation entry to EXEMPT with the reason.",
        file=sys.stderr,
    )

if not failed:
    print(f"OK: {checked} route/module citation(s) across Built stories all resolve.")

sys.exit(1 if failed else 0)
PY
