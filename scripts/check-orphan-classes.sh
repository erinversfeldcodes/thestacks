#!/usr/bin/env bash
# check-orphan-classes.sh — Elm class literals with no CSS rule behind them (Issue #301).
#
# WHY THIS EXISTS
#
# Markup can name a style that does not exist, and **nothing in the test suite can notice**: the class
# IS present in the DOM, so every `Selector.class` assertion passes. Three surfaces shipped fully
# unstyled this way — `/listing-removal`, the shelf organiser, and the profile feed link — rendering as
# raw browser chrome (bulleted lists, default grey buttons) on top of the dark-academic wallpaper. All
# three were found by looking at a deployed preview, not by any check.
#
# `frontend/css/main.css` is the ONLY stylesheet source. Everything under
# `apps/core/priv/static/assets/*.css` is build output — do not count it, and do not edit it.
#
# WHAT COUNTS AS AN ORPHAN
#
# A class used in `frontend/src/**/*.elm` with no matching selector in main.css. EVERY orphan is a
# defect now, and the budget sits at its floor of 0.
#
# ⚠️ There is NO test-hook exemption any more (#310), and its history is the argument for its absence.
# The gate once exempted a class "verified" as a test selector. That verification was a substring
# match and handed out 14 bogus exemptions (`.success` was exempt because `successCopy` appears in a
# test — while rendering unstyled in five Settings surfaces). Tightened to real selector syntax, it
# STILL protected seven visual classes a live drive found unstyled (the masthead, an author card, the
# settings navigation) — because "findable by a test" never implied "invisible to a reader". Even its
# final two members turned out to select on a `data-testid` sitting beside the class, not the class.
# Hooks belong in `data-testid`, which needs no rule because it is not a class.
#
# Usage:
#   scripts/check-orphan-classes.sh            # fail if the orphan count exceeds the budget
#   scripts/check-orphan-classes.sh --list     # every orphan, grouped by component prefix
#   scripts/check-orphan-classes.sh --update   # print the line to paste when the budget legitimately drops
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

# The floor, with nothing exempt from it. Never raise it.
#
# 2026-07-29 (#306): all 309 orphans needing a rule got one. 2026-08-04 (#310): the last two "hooks"
# were styled and the exemption deleted — see the header for why it could never be made sound.
ORPHAN_BUDGET=0

python3 - "$MODE" "$ORPHAN_BUDGET" <<'PY'
import re, sys, glob
from collections import defaultdict

mode, budget = sys.argv[1], int(sys.argv[2])

# Class literals used in Elm views: `class "a b"`, `classList` entries, and `Attr.class "x"`.
#
# ⚠️ #356: `class "a b"` is only the SIMPLE form. Whenever a class depends on state Elm writes a
# COMPUTED form — `class (if cond then "a--selected" else "a")`, `class ("base " ++ fn x)`,
# `classList [ ("a", cond) ]` — and the naive `class\s+"…"` regex is blind to every literal in it,
# because `class` is followed by `(` or `[`, not `"`. That blind spot (42 sites) let
# `.upload-shelf-picker__shelf(--selected)` ship completely unstyled while the gate read `0 unstyled`:
# a class named ONLY inside a computed form is invisible to BOTH halves — it can neither be flagged an
# orphan nor caught as an unstyled surface. So we also harvest every string literal that appears inside
# a balanced `class (…)` / `classList […]` argument region, including inside `if/then/else` and `case`
# branches. Over-collecting class-shaped tokens is safe (a spurious `used` entry can only ADD an orphan
# to investigate, never hide one) — but we drop tokens ending in `-`/`_`, which are concatenation
# PREFIXES (`"marketplace__status-badge--" ++ fn`), not real class names.


def _add_token(token, used):
    if token.endswith("-") or token.endswith("_"):
        return
    if re.fullmatch(r"[a-z][a-z0-9_-]*", token):
        used.add(token)


def _harvest_computed(text, used):
    """Collect string literals inside `class (…)` / `classList […]` argument regions."""
    for m in re.finditer(r"(?<![\w.])(?:[A-Z][\w.]*\.)?(class|classList)\b", text):
        j = m.end()
        while j < len(text) and text[j] in " \t\r\n":
            j += 1
        if j >= len(text) or text[j] not in "([":
            continue  # `class "x"` (simple form, handled below) or something else — skip.
        depth, in_str, k = 0, False, j
        while k < len(text):
            ch = text[k]
            if in_str:
                if ch == "\\":
                    k += 2
                    continue
                if ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        region = text[j : k + 1]
        for literal in re.findall(r'"([^"\n]*)"', region):
            for token in literal.split():
                _add_token(token, used)


used = set()
for path in glob.glob("frontend/src/**/*.elm", recursive=True):
    text = open(path, encoding="utf-8").read()
    for literal in re.findall(r'class\s+"([^"\n]+)"', text):
        for token in literal.split():
            _add_token(token, used)
    _harvest_computed(text, used)

# Selectors defined anywhere in the single stylesheet source.
defined = set()
css = open("frontend/css/main.css", encoding="utf-8").read()
for name in re.findall(r"\.([a-zA-Z][a-zA-Z0-9_-]*)", css):
    defined.add(name)

orphans = sorted(used - defined)


if mode == "--list":
    groups = defaultdict(list)
    for cls in orphans:
        groups[re.split(r"__|--", cls)[0]].append(cls)
    print(f"{len(orphans)} orphan class(es) across {len(groups)} component group(s):\n")
    for prefix, members in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {prefix}  ({len(members)})")
        for m in members:
            print(f"      {m}")
    sys.exit(0)

if mode == "--update":
    print(f"ORPHAN_BUDGET={len(orphans)}")
    sys.exit(0)

print(f"Elm classes: {len(used)}   CSS selectors: {len(defined)}   orphans: {len(orphans)}")

if len(orphans) > budget:
    added = len(orphans) - budget
    print(f"\n{added} NEW orphan class(es) — markup naming a style that does not exist.")
    print("No test can catch this: the class IS in the DOM, so every `Selector.class` assertion passes.")
    print("Either add the rule, or use `data-testid` if it is only a hook.\n")
    print("Most likely culprits (unstyled classes in the groups you probably just touched):")
    groups = defaultdict(list)
    for cls in orphans:
        groups[re.split(r"__|--", cls)[0]].append(cls)
    for prefix, members in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:6]:
        print(f"  {prefix}: {', '.join(members[:6])}{' …' if len(members) > 6 else ''}")
    print("\nRun --list to see all of them.")
    sys.exit(1)

if len(orphans) < budget:
    print(f"\nOrphan count is {budget - len(orphans)} BELOW the budget of {budget}. Lower the ratchet:")
    print(f"  scripts/check-orphan-classes.sh --update   → ORPHAN_BUDGET={len(orphans)}")

sys.exit(0)
PY
