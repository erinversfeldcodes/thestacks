#!/usr/bin/env bash
# check-css.sh — the stylesheet's own gate. There has never been one.
#
# WHY THIS EXISTS
#
# `frontend/css/main.css` is ~6,000 lines, append-only in practice, and **nothing in `just verify`
# looks at it**. Not its syntax, not its specificity, not its collisions. `mix format` and
# `elm-format` do not touch CSS; there is no CSS linter (#301's Reviewer Context says so plainly);
# and no test can see any of it, because a test asserts a class is in the DOM, never that the class
# does anything.
#
# That gap is not theoretical. Three defects were introduced in a single change on 2026-07-29 and all
# three passed the full gate:
#
#   1. **Syntactically broken CSS.** A selector list ended in `{` and was followed by another selector
#      list. `just verify` returned exit 0 on a stylesheet a browser cannot parse.
#   2. **A silent capture.** `[class$="__link"]:hover` has the same specificity as
#      `.app-nav__link:hover` and sat later in the file, so it took over the **primary navigation's**
#      hover colour. An attribute selector cannot be scoped to "the classes I just added".
#   3. **Five links stuck in their hover state**, because the hover selector list was emitted once
#      without `:hover` and once with.
#
# Generalising defect 2 found **seven more pre-existing instances** of the same trap, which is the
# real argument for this file: the mistake is systematic, not personal.
#
# WHAT IT CHECKS
#
#   A. **Well-formedness.** Balanced braces, and no rule whose body contains a nested selector — the
#      shape defect 1 took.
#   B. **`[class...=]` attribute selectors.** Banned outright. Their whole problem is that they match
#      classes the author never enumerated, so they cannot be scoped, and they collide at equal
#      specificity with the single-class rules they were never meant to touch.
#   C. **A modifier overridden by its base under a pseudo-class.** `.b--m` is (0,1,0) and loses to
#      `.b:hover` (0,2,0), so an *active* tab reverts to inactive colours the moment it is hovered and
#      a *disabled* button brightens under the cursor. Ratcheted, because instances pre-date this.
#   D. **The same single-class selector setting the same property in two rules** outside `@media` —
#      one silently wins and the loser reads as dead code. Inside `@media` this is a responsive
#      override and correct, which is why the check is media-aware: without that it reported 48 and
#      only 5 were real.
#
# Usage:
#   scripts/check-css.sh            # gate
#   scripts/check-css.sh --list     # every finding, including ratcheted ones
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

# Modifier/pseudo-class collisions that pre-date this check. Lower it as they are fixed; never raise.
# 2026-07-29: 7 found by generalising a defect introduced that day; all 7 fixed, so the floor is 0.
PSEUDO_COLLISION_BUDGET=0

python3 - "$MODE" "$PSEUDO_COLLISION_BUDGET" <<'PY'
import re, sys
from collections import defaultdict

mode, budget = sys.argv[1], int(sys.argv[2])
path = "frontend/css/main.css"
raw = open(path, encoding="utf-8").read()
css = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)

problems, ratcheted = [], []

# ---- A. well-formedness -----------------------------------------------------
if css.count("{") != css.count("}"):
    problems.append(f"unbalanced braces: {css.count('{')} open, {css.count('}')} close")

# Walk with a depth counter, tracking @-block context so media queries are distinguishable.
rules, depth, at_block, buf, i = [], 0, [], "", 0
while i < len(css):
    c = css[i]
    if c == "{":
        head = buf.strip()
        buf = ""
        if head.startswith("@"):
            at_block.append(depth)
        else:
            rules.append((head, len(at_block) > 0, i))
        depth += 1
    elif c == "}":
        depth -= 1
        if at_block and at_block[-1] == depth:
            at_block.pop()
        buf = ""
    else:
        buf += c
    i += 1


def body_of(pos):
    j, d = pos + 1, 1
    while j < len(css) and d:
        if css[j] == "{":
            d += 1
        elif css[j] == "}":
            d -= 1
        j += 1
    return css[pos + 1 : j - 1]


def props_of(body):
    return {d.split(":")[0].strip() for d in body.split(";") if ":" in d and "{" not in d}


def decls_of(body):
    """{property: normalised value} for a rule body — later duplicate wins, as the cascade does."""
    out = {}
    for d in body.split(";"):
        if ":" in d and "{" not in d:
            k, _, v = d.partition(":")
            out[k.strip().lower()] = re.sub(r"\s+", " ", v).strip().lower()
    return out


# A rule body containing `{` — defect 1's exact and unambiguous shape.
#
# ⚠️ The first version of this check tried to recognise a *selector-looking line* and produced 24 false
# positives: it flagged the continuation lines of multi-line declarations
# (`background: radial-gradient(...),` wrapped over several lines) in the armchair and parchment rules.
# A check that fires on correct code is one someone switches off, so it was replaced with the precise
# test: a declaration block cannot legally contain a brace, so a brace in a body means a nested rule.
for head, in_media, pos in rules:
    body = body_of(pos)
    if "{" in body:
        offending = next((l.strip() for l in body.split("\n") if "{" in l), body[:60])
        problems.append(
            f"rule `{head[:60]}` has a `{{` inside its body: `{offending[:60]}` — a selector list "
            "ending in `{` followed by more selectors is unparseable"
        )

# ---- B. class attribute selectors ------------------------------------------
for head, in_media, pos in rules:
    if re.search(r"\[class[*^$|~]?=", head):
        problems.append(
            f"attribute selector on `class`: `{head[:70]}` — it matches classes nobody enumerated, "
            "so it cannot be scoped and collides at equal specificity with single-class rules"
        )

# ---- C. modifier vs base-under-pseudo-class --------------------------------
base_pseudo, modifiers = defaultdict(dict), defaultdict(dict)
for head, in_media, pos in rules:
    p = props_of(body_of(pos))
    for one in head.split(","):
        one = one.strip()
        m = re.fullmatch(r"\.([a-zA-Z][\w-]*?):(hover|focus|active|focus-visible)", one)
        if m:
            base_pseudo[m.group(1)].setdefault(m.group(2), set()).update(p)
        m2 = re.fullmatch(r"\.([a-zA-Z][\w-]*?)--([\w-]+)", one)
        if m2:
            modifiers[m2.group(1)].setdefault(one, set()).update(p)

# A modifier that declares its OWN pseudo-class rule has already resolved the collision — that is the
# fix, so the check must recognise it or it flags the repair as the defect.
mod_pseudo = defaultdict(set)
for head, in_media, pos in rules:
    p = props_of(body_of(pos))
    for one in head.split(","):
        one = one.strip()
        m = re.fullmatch(r"(\.[a-zA-Z][\w-]*--[\w-]+):(hover|focus|active|focus-visible)", one)
        if m:
            mod_pseudo[f"{m.group(1)}:{m.group(2)}"].update(p)

collisions = []
for base, mods in modifiers.items():
    for pseudo, pprops in base_pseudo.get(base, {}).items():
        for modsel, mprops in mods.items():
            shared = sorted((mprops & pprops) - mod_pseudo.get(f"{modsel}:{pseudo}", set()))
            if shared:
                collisions.append(
                    f"{modsel} loses to .{base}:{pseudo} on {shared} — the modifier is (0,1,0), the "
                    f"pseudo-class rule is (0,2,0), so hovering reverts the modifier's own state"
                )

# ---- E. every `page--<route>` wrapper has a rule ---------------------------
#
# A FAMILY check, because the individual failures were invisible: four of 25 `page--*` variants had no
# rule, and all four were exempt from the orphan gate as "test hooks". Driving found two of them; the
# other two were on routes nobody had opened. A family that shares a role should be checked as one.
import glob as _glob

src = ""
for _f in _glob.glob("frontend/src/**/*.elm", recursive=True):
    src += open(_f, encoding="utf-8", errors="ignore").read()

declared = set(re.findall(r"page--[a-z0-9-]+", src))

def has_rule(cls):
    """Is there a rule for exactly this class?

    ⚠️ NOT `f".{cls}" in raw`. That substring test is what let a probe slip past: renaming
    `.form-field__label` to `.form-field__label-DISABLED` still *contains* `.form-field__label`, so the
    check reported no finding and passed. Precisely the substring flaw that had handed out 14 bogus
    hook exemptions, reproduced in the check written to catch its consequences. A trailing word or
    hyphen character means it is a different class.
    """
    return re.search(r"\." + re.escape(cls) + r"(?![\w-])", raw) is not None


declared_classes = set()
for _lit in re.findall(r'class\s+"([^"\n]+)"', src):
    for _tok in _lit.split():
        if re.fullmatch(r"[a-z][a-z0-9_-]*", _tok):
            declared_classes.add(_tok)
styled = {v for v in declared if has_rule(v)}
for missing in sorted(declared - styled):
    problems.append(
        f".{missing} is used in an Elm view and has no rule — every `page--<route>` wrapper needs one, "
        "and this family had four unstyled at once while the orphan gate read zero"
    )

# ---- F. BEM sibling gaps ---------------------------------------------------
#
# A block with SOME members styled and some not. This generalises the seven that only a live drive
# found: nobody designs a table with a styled wrapper and an unstyled row, so a partly-styled block is
# an oversight almost by definition. 45 were found this way, on routes a drive would have had to visit
# one by one — `audit-log` had one styled member and six bare.
#
# Ratcheted at 0. If a block legitimately needs an unstyled member, style it as a no-op and say why:
# `user-menu__backdrop` is transparent BY DESIGN and still needs a rule, or it has no size and catches
# no clicks.
blocks = {}
for _cls in sorted(declared_classes):
    _b = re.split(r"__|--", _cls)[0]
    blocks.setdefault(_b, {"styled": [], "bare": []})
    blocks[_b]["styled" if has_rule(_cls) else "bare"].append(_cls)

for _b, _v in sorted(blocks.items()):
    if _v["bare"] and _v["styled"]:
        problems.append(
            f"block `{_b}` is partly styled: {len(_v['styled'])} member(s) have rules and "
            f"{_v['bare']} do not — a partly-styled block is an oversight, not a decision"
        )

# ---- D. same class, same property, twice, outside @media -------------------
byclass = defaultdict(list)
for head, in_media, pos in rules:
    if in_media:
        continue
    p = props_of(body_of(pos))
    for one in head.split(","):
        one = one.strip()
        if re.fullmatch(r"\.[a-zA-Z][\w-]*", one):
            byclass[one].append(p)

for cls, occ in byclass.items():
    for a in range(len(occ)):
        for b in range(a + 1, len(occ)):
            shared = sorted(occ[a] & occ[b])
            if shared:
                problems.append(
                    f"{cls} sets {shared} in two separate rules outside @media — the later silently "
                    "wins and the earlier reads as live code that does nothing"
                )

# ---- G. a base rule placed AFTER its own modifier (order silently defeats it) ----
#
# Check C only catches base-beats-modifier UNDER A PSEUDO-CLASS (`.b:hover` at (0,2,0) beating `.b--m`
# at (0,1,0)). The plainer case (#365) it never saw: a base `.b` and a modifier `.b--m` are BOTH
# single-class, so their specificity is EQUAL (0,1,0) — and at equal specificity the rule defined LATER
# in the file wins. So a base rule sitting *after* its own modifier overrides it, and the modifier is
# inert. That silently killed the amber on three `.login-card__notice--*` surfaces: the base
# `.login-card__notice` sat ~3500 lines below its modifiers, so its accent-green `background`/`color`
# and its `margin`/`padding` SHORTHANDS beat the modifiers' amber and their `margin-bottom` longhand.
#
# Shorthand-vs-longhand is half the damage, so a `background` base vs a `background-color` modifier, or
# a `margin` base vs a `margin-bottom` modifier, MUST count as a collision. `_atoms()` expands each
# property to the set of atomic sub-properties it controls; two properties collide when those sets
# intersect.
ORDER_COLLISION_BUDGET = 0


def _atoms(prop):
    prop = prop.strip().lower()
    if prop in ("margin", "padding"):
        return {f"{prop}-top", f"{prop}-right", f"{prop}-bottom", f"{prop}-left"}
    if re.fullmatch(r"(margin|padding)-(top|right|bottom|left)", prop):
        return {prop}
    if prop == "background":
        return {"background-color", "background-image", "background-position",
                "background-repeat", "background-size", "background-attachment"}
    if prop.startswith("background-"):
        return {prop}
    if prop == "border":
        return {"border-top", "border-right", "border-bottom", "border-left"}
    if prop in ("border-top", "border-right", "border-bottom", "border-left"):
        return {prop}
    if re.fullmatch(r"border-(top|right|bottom|left)-(width|style|color)", prop):
        return {"border-" + prop.split("-")[1]}
    if prop in ("border-width", "border-style", "border-color"):
        return {"border-top", "border-right", "border-bottom", "border-left"}
    if prop == "font":
        return {"font-family", "font-size", "font-style", "font-weight", "line-height"}
    if prop in ("font-family", "font-size", "font-style", "font-weight", "font-variant", "line-height"):
        return {prop}
    return {prop}


plain_base, plain_mod = defaultdict(list), defaultdict(list)
for head, in_media, pos in rules:
    if in_media:
        continue
    decls = decls_of(body_of(pos))
    for one in head.split(","):
        one = one.strip()
        mb = re.fullmatch(r"\.([a-zA-Z][\w-]*)", one)  # a PLAIN single-class selector only
        if not mb:
            continue
        name = mb.group(1)
        mm = re.fullmatch(r"([a-zA-Z][\w-]*?)--[\w-]+", name)
        if mm:
            plain_mod[mm.group(1)].append((one, pos, decls))
        else:
            plain_base[name].append((pos, decls))


def _defeats(bdecls, mdecls):
    """Which modifier declarations a later base rule actually defeats.

    Value-aware on purpose. A base redeclaring a property with the SAME value it already has is a
    harmless redundancy, not a defeated modifier (e.g. `.b--loading{position:relative}` under a later
    `.b{position:relative}`), and a gate that fires on correct code is one someone switches off — the
    lesson check A already learned. So a same-NAMED property counts only when the values DIFFER. But
    shorthand-vs-longhand (base `background`/`margin` beating modifier `background-color`/`margin-bottom`)
    counts ALWAYS: it is the fragile pattern #365 calls out, and the shorthand resets components the
    modifier never mentioned regardless of the visible value.
    """
    hits = set()
    for mp, mv in mdecls.items():
        for bp, bv in bdecls.items():
            if bp == mp:
                if bv != mv:
                    hits.add(mp)
            elif _atoms(bp) & _atoms(mp):  # shorthand-vs-longhand across different names
                hits.add(f"{mp} (via base `{bp}`)")
    return hits


order_collisions = []
for base_name, mods in plain_mod.items():
    bases = plain_base.get(base_name, [])
    for modsel, mpos, mdecls in mods:
        # The base rule that WINS for a shared property is the LAST base occurrence. If ANY base
        # occurrence sits after this modifier and actually changes one of its declarations, the base
        # defeats the modifier and the modifier is inert.
        defeated = set()
        for bpos, bdecls in bases:
            if bpos > mpos:
                defeated.update(_defeats(bdecls, mdecls))
        if defeated:
            order_collisions.append(
                f".{base_name} (base) is defined AFTER {modsel} and overrides it on "
                f"{sorted(defeated)} at equal specificity (0,1,0) — later wins, so the modifier is inert"
            )

if mode == "--list":
    print(
        f"{len(problems)} problem(s), {len(collisions)} modifier/pseudo collision(s), "
        f"{len(order_collisions)} base-after-modifier order collision(s):\n"
    )
    for p in problems:
        print(f"  !! {p}")
    for c in collisions:
        print(f"  ~~ {c}")
    for c in order_collisions:
        print(f"  >< {c}")
    sys.exit(0)

print(
    f"CSS: {len(rules)} rule(s) checked, {len(problems)} problem(s), "
    f"{len(collisions)} modifier/pseudo collision(s) (budget {budget}), "
    f"{len(order_collisions)} base-after-modifier order collision(s) (budget {ORDER_COLLISION_BUDGET})"
)

failed = False
if problems:
    print("\nProblems that must be fixed:\n")
    for p in problems:
        print(f"  {p}\n")
    failed = True

if len(order_collisions) > ORDER_COLLISION_BUDGET:
    print(f"\n{len(order_collisions) - ORDER_COLLISION_BUDGET} NEW base-after-modifier order collision(s):\n")
    for c in order_collisions:
        print(f"  {c}\n")
    print("Fix by moving the base rule ABOVE its modifiers (or splitting it out of a shared group so it "
          "precedes them). BEM modifiers only win by cascade ORDER when they follow the base.")
    failed = True

if len(collisions) > budget:
    print(f"\n{len(collisions) - budget} NEW modifier/pseudo collision(s):\n")
    for c in collisions:
        print(f"  {c}\n")
    print("Fix by giving the modifier its own pseudo-class rule, e.g. `.b--m:hover`.")
    failed = True
elif len(collisions) < budget:
    print(f"\nBelow budget ({len(collisions)} < {budget}). Lower PSEUDO_COLLISION_BUDGET.")

sys.exit(1 if failed else 0)
PY
