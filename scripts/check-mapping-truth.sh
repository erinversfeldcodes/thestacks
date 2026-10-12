#!/usr/bin/env bash
# A story that describes the system as it stands must cite things that exist.
#
# docs/implementation-mapping.md is the bridge between the user stories and the
# code, and each story block names the concrete artefacts that implement it —
# modules, endpoints, functions. When a block presents itself as current and the
# artefacts are fictional, the document is not merely out of date: it is actively
# answering "is this built?" with a confident yes.
#
# That is not hypothetical here. Two writing-assistant stories claimed Built
# against five artefacts that had never existed, and three status rows claimed
# statuses their routes contradicted. Both were found by a person reading
# carefully, which does not scale and does not repeat.
#
# WHAT IT CHECKS  Every API route cited by an in-scope story exists in the
# router, and every Elm module it names exists on disk.
#
# WHICH STORIES ARE IN SCOPE  An earlier version keyed on `Status | Built |`
# spelled exactly, which covered 36 of 127 stories: any block whose status
# carried a qualifier ("Built (shipped early)", "Built. Email leg deferred")
# fell through the exact match, and the 79 blocks with no status row at all were
# never looked at. Since a block with no status reads as a description of the
# system as it stands, that was the larger blind spot. In scope now:
#
#   * any status beginning "Built", however it is qualified;
#   * any Phase 1 story with no status row — Phase 1 is the shipped phase, so a
#     citation there is a claim about today.
#
# Out of scope, each counted and named in the output so the exclusion is visible
# rather than silent:
#
#   * a status beginning "Not built" — declared aspirational;
#   * a later-phase story with no status row — the artefact names are design
#     intent for work not yet started, and demanding they resolve would turn the
#     gate into noise. Those blocks earn scrutiny when their phase begins.
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


def router_patterns(src):
    """Every route's FULL path segments, resolving nested `scope` prefixes.

    A route is declared as `get "/invites"` inside `scope "/api/admin"`, so the
    literal in the router is only the tail. An earlier version compared those
    tails directly and reported three real endpoints as missing — the gate was
    wrong, not the document. Scope prefixes have to be resolved or this check
    invents findings.
    """
    pats, scopes, depth_stack, depth = set(), [], [], 0
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
            full = "".join(scopes) + r.group(1)
            pats.add(tuple(full.split("?")[0].rstrip("/").split("/")))
    return pats


ROUTER_PATTERNS = router_patterns(router)


def route_exists(cited):
    """Match a cited path against router patterns segment by segment.

    A router `:param` segment matches ANY single cited segment, so a doc that
    cites a concrete instance of a parameterised route — `/api/bookshelves/
    library/placements` against `get "/bookshelves/:bookshelf_name/placements"`
    — resolves. Naming the instance is often the clearer documentation, and
    reporting it as a missing endpoint would push the doc toward being less
    useful in order to satisfy the gate.
    """
    segs = tuple(cited.split("?")[0].rstrip("/").split("/"))
    for pat in ROUTER_PATTERNS:
        if len(pat) != len(segs):
            continue
        if all(p.startswith(":") or p == s for p, s in zip(pat, segs)):
            return True
    return False


# A backtick inside a clause that says the thing does NOT exist is the opposite
# of a citation. Two stories carry exactly that — "no `Page.Upload.Review`,
# `Components.BookReviewCard`, or `Components.BulkProgress` exist" — and reading
# them as claims would have the gate report a story for honestly recording what
# it lacks. Negated spans are skipped and counted, never silently dropped.
# A bare "no" is too weak on its own: a status reading "Built (shipped early, no
# prior story file)" is not denying that anything exists, and an early version of
# this pattern skipped the whole clause — silently disarming the gate for every
# story whose status carried that very common qualifier. A planted citation there
# went unreported. So a bare negator only counts when it actually points at an
# artefact: it must reach a backtick across nothing but connective material —
# no closing paren, and only a few characters. A wider window let "no prior
# story file) via `X`" read as a denial that `X` exists.
NEGATION = re.compile(
    r"(?:(?:\bno\b|\bnone of\b|\bneither\b)[^`|.;\n)]{0,8}`"
    r"|does not exist|do not exist|never existed|was never"
    r"|is not built|are not built|\bunbuilt\b"
    r"|\bnot yet\b\s*(?:built|exist|implemented))",
    re.IGNORECASE,
)


def negated_spans(block):
    """Character ranges of clauses that negate rather than cite.

    Scoped to the whole clause, not forward from the negation word, because the
    negation lands on either side of the artefact in practice: "there are **no**
    `Components.CoverImage` ... modules" puts it before, and
    "`Components.PartnerAvailability` is a Phase 3+ addition, not yet built"
    puts it after. A forward-only span reads the second as a live citation.

    A clause ends at a sentence end, semicolon, or table-cell boundary — far
    enough to cover a list of negated artefacts, short enough not to swallow the
    rest of the cell.
    """
    bounds, pos = [0], 0
    for stop in re.finditer(r"[.;|\n]", block):
        # A period inside a module path is not a sentence end.
        if stop.group() == "." and re.match(r"\.\w", block[stop.start():]):
            continue
        bounds.append(stop.end())
    bounds.append(len(block))
    spans = []
    for lo, hi in zip(bounds, bounds[1:]):
        if NEGATION.search(block[lo:hi]):
            spans.append((lo, hi))
    return spans


ROUTE_CITE = re.compile(
    r"((?:GET|POST|PUT|PATCH|DELETE)(?:/(?:GET|POST|PUT|PATCH|DELETE))*)\s+(/\S+)"
)
MODULE_CITE = re.compile(
    r"((?:Components|Page|Types|Navigation|Animation)(?:\.\w+)+|Api)"
)

problems = []
checked = 0
negated = 0
in_scope = []
out_of_scope = {"declared not built": [], "later-phase design, no status row": []}

for block in re.split(r"\n(?=#### US-)", text):
    m = re.match(r"#### (US-[\d.]+)", block)
    if not m:
        continue
    story = m.group(1)

    status_m = re.search(r"\|\s*\*\*Status\*\*\s*\|\s*(.*?)\s*\|", block)
    status = status_m.group(1) if status_m else ""
    phase_m = re.search(r"\|\s*\*\*Phase\*\*\s*\|\s*(.*?)\s*\|", block)
    phase = phase_m.group(1) if phase_m else ""

    if re.match(r"(?i)not built", status):
        out_of_scope["declared not built"].append(story)
        continue
    if not status and not phase.startswith("Phase 1"):
        out_of_scope["later-phase design, no status row"].append(story)
        continue
    in_scope.append(story)

    skip = negated_spans(block)
    for cm in re.finditer(r"`([^`]+)`", block):
        if any(lo <= cm.start() < hi for lo, hi in skip):
            negated += 1
            continue
        cite = cm.group(1)
        key = f"{story}:{cite}"
        if key in EXEMPT:
            continue

        rm = ROUTE_CITE.fullmatch(cite)
        if rm:
            checked += 1
            if not route_exists(rm.group(2)):
                problems.append((story, cite, "no such route in the router"))
            continue

        em = MODULE_CITE.fullmatch(cite)
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

# An exemption that no longer corresponds to a real problem is worse than no
# exemption: it is a standing permission for a defect that would otherwise be
# caught. The previous version computed this list with a literal `False` and
# never read it, so no exemption could ever go stale.
unresolved = {f"{s}:{c}" for s, c, _ in problems}
stale = sorted(k for k in EXEMPT if k not in unresolved)

failed = False

if problems:
    failed = True
    print(
        f"FAIL: {len(problems)} artefact(s) cited by an in-scope story do not exist:",
        file=sys.stderr,
    )
    for story, cite, why in problems:
        print(f"  {story:<12} `{cite}` — {why}", file=sys.stderr)
    print(
        "\nA story that describes the system as it stands, while its artefacts are\n"
        'fictional, answers "is this built?" with a confident yes. Either correct the\n'
        "status, correct the citation, or add a story:citation entry to EXEMPT with\n"
        "the reason.",
        file=sys.stderr,
    )

if stale:
    failed = True
    print(
        f"\nFAIL: {len(stale)} EXEMPT entr(y/ies) no longer match a real problem — "
        "the citation now resolves, or the story left scope. Remove them:",
        file=sys.stderr,
    )
    for k in stale:
        print(f"  {k}", file=sys.stderr)

if not failed:
    print(
        f"OK: {checked} route/module citation(s) across {len(in_scope)} in-scope "
        f"stor(y/ies) all resolve."
    )
    for reason, stories in out_of_scope.items():
        if stories:
            print(f"    not checked — {reason}: {len(stories)} ({', '.join(stories)})")
    if negated:
        print(f"    {negated} backtick(s) skipped inside a clause saying they do NOT exist")

sys.exit(1 if failed else 0)
PY
