#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

PSEUDO_COLLISION_BUDGET=0

python3 - "$MODE" "$PSEUDO_COLLISION_BUDGET" <<'PY'
import re, sys
from collections import defaultdict

mode, budget = sys.argv[1], int(sys.argv[2])
path = "frontend/css/main.css"
raw = open(path, encoding="utf-8").read()
css = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)

problems, ratcheted = [], []

if css.count("{") != css.count("}"):
    problems.append(f"unbalanced braces: {css.count('{')} open, {css.count('}')} close")

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

for head, in_media, pos in rules:
    body = body_of(pos)
    if "{" in body:
        offending = next((l.strip() for l in body.split("\n") if "{" in l), body[:60])
        problems.append(
            f"rule `{head[:60]}` has a `{{` inside its body: `{offending[:60]}` — a selector list "
            "ending in `{` followed by more selectors is unparseable"
        )

for head, in_media, pos in rules:
    if re.search(r"\[class[*^$|~]?=", head):
        problems.append(
            f"attribute selector on `class`: `{head[:70]}` — it matches classes nobody enumerated, "
            "so it cannot be scoped and collides at equal specificity with single-class rules"
        )

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

    Searches the comment-stripped source, as check-orphan-classes.sh does, so a class named only in
    a CSS comment — an example, or a note about a rule someone deleted — does not read as styled.
    """
    return re.search(r"\." + re.escape(cls) + r"(?![\w-])", css) is not None

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

# There is deliberately NO hook exemption below, and check-orphan-classes.sh's header is the
# argument for its absence: the exemption it used to carry was a substring match that handed out 14
# bogus passes, and tightening it to real selector syntax still protected seven classes a live drive
# found unstyled. A hook belongs in `data-testid`, which needs no rule because it is not a class.
# A second allowlist here would be the same mistake under a new name.
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
    elif _v["bare"] and any(("__" in _m or "--" in _m) for _m in _v["bare"]):
        # The partly-styled rule above is structurally blind to this case: it compares bare members
        # against styled ones, so a block with NO styled member never reaches it. That is the shape a
        # brand-new component has on the day it ships, and three surfaces — the listing-removal page,
        # the shelf organiser, the profile shelf feed — went out through exactly this hole, rendering
        # as raw browser chrome. A block is judged whole here: it needs at least one `__`/`--` member,
        # so this names components rather than restating every loose class the orphan gate already has.
        problems.append(
            f"block `{_b}` is WHOLLY unstyled: every one of its {len(_v['bare'])} member(s) "
            f"{_v['bare']} lacks a rule, so the entire component renders unstyled. The partly-styled "
            "rule cannot see this — it needs a styled member to compare against. Add the rules, or "
            "move the names to `data-testid` if they are only hooks."
        )

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
