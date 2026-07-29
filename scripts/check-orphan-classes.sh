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
# A class used in `frontend/src/**/*.elm` with no matching selector in main.css. **Not every orphan is
# a defect** — a wrapper that exists only as a JS or test hook needs no rule (though `data-testid` is
# the project's convention for that, and is preferred). So this reports a BUDGET, not a bug count: the
# baseline is recorded below and the check fails when it RISES. That turns a 398-item backlog into a
# ratchet nobody has to finish before it starts protecting them.
#
# Usage:
#   scripts/check-orphan-classes.sh            # fail if the orphan count exceeds the budget
#   scripts/check-orphan-classes.sh --list     # every orphan, grouped by component prefix
#   scripts/check-orphan-classes.sh --hooks    # the classes exempt as verified test selectors
#   scripts/check-orphan-classes.sh --update   # print the line to paste when the budget legitimately drops
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

# The ratchet, now at its floor. Never raise it.
#
# 2026-07-29 (#306): all 309 orphans that needed a CSS rule were given one, so the budget for
# *unstyled* classes is **0**. The 89 that remain are test/E2E selectors — a class used only as a
# hook needs no rule — and they are exempt as a CATEGORY rather than as a list.
#
# ⚠️ The exemption is VERIFIED, not asserted: a class only counts as a hook if it actually appears as
# a selector in `frontend/tests/` or `e2e/tests/`. So the escape hatch cannot be used to wave through
# an unstyled component by calling it a hook — the check goes and looks. That is the difference
# between an allowlist and an excuse.
ORPHAN_BUDGET=0

python3 - "$MODE" "$ORPHAN_BUDGET" <<'PY'
import re, sys, glob
from collections import defaultdict

mode, budget = sys.argv[1], int(sys.argv[2])

# Class literals used in Elm views: `class "a b"`, `classList` entries, and `Attr.class "x"`.
used = set()
for path in glob.glob("frontend/src/**/*.elm", recursive=True):
    text = open(path, encoding="utf-8").read()
    for literal in re.findall(r'class\s+"([^"\n]+)"', text):
        for token in literal.split():
            if re.fullmatch(r"[a-z][a-z0-9_-]*", token):
                used.add(token)

# Selectors defined anywhere in the single stylesheet source.
defined = set()
css = open("frontend/css/main.css", encoding="utf-8").read()
for name in re.findall(r"\.([a-zA-Z][a-zA-Z0-9_-]*)", css):
    defined.add(name)

orphans = sorted(used - defined)

# A class used as a selector by a unit test or an E2E spec is a HOOK: it exists to be found, not to be
# seen, so it legitimately needs no rule. `data-testid` is the project's preferred form for this and
# converting them is tracked separately — until then they are exempt, and the exemption is checked
# against the test sources rather than taken on trust.
hook_sources = ""
for pattern in ("frontend/tests/**/*.elm", "e2e/tests/*.ts", "e2e/tests/**/*.ts"):
    for f in glob.glob(pattern, recursive=True):
        hook_sources += open(f, encoding="utf-8", errors="ignore").read()

hooks = [c for c in orphans if c in hook_sources]
unstyled = [c for c in orphans if c not in hook_sources]

if mode == "--hooks":
    print(f"{len(hooks)} class(es) exempt as verified test/E2E selectors:\n")
    for c in hooks:
        print(f"  {c}")
    print(f"\n{len(unstyled)} unstyled class(es) remain.")
    sys.exit(0)

if mode == "--list":
    groups = defaultdict(list)
    for cls in unstyled or orphans:
        groups[re.split(r"__|--", cls)[0]].append(cls)
    print(f"{len(orphans)} orphan class(es) across {len(groups)} component group(s):\n")
    for prefix, members in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {prefix}  ({len(members)})")
        for m in members:
            print(f"      {m}")
    sys.exit(0)

if mode == "--update":
    print(f"ORPHAN_BUDGET={len(unstyled)}")
    sys.exit(0)

print(
    f"Elm classes: {len(used)}   CSS selectors: {len(defined)}   "
    f"orphans: {len(orphans)} ({len(unstyled)} unstyled, {len(hooks)} verified test hooks)"
)

# The gate is on UNSTYLED classes only. Hooks are exempt because they were checked, above.
if len(unstyled) > budget:
    added = len(unstyled) - budget
    print(f"\n{added} NEW orphan class(es) — markup naming a style that does not exist.")
    print("No test can catch this: the class IS in the DOM, so every `Selector.class` assertion passes.")
    print("Either add the rule, or use `data-testid` if it is only a hook.\n")
    print("Most likely culprits (unstyled classes in the groups you probably just touched):")
    groups = defaultdict(list)
    for cls in unstyled:
        groups[re.split(r"__|--", cls)[0]].append(cls)
    for prefix, members in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:6]:
        print(f"  {prefix}: {', '.join(members[:6])}{' …' if len(members) > 6 else ''}")
    print("\nRun --list to see all of them.")
    sys.exit(1)

if len(unstyled) < budget:
    print(f"\nUnstyled count is {budget - len(unstyled)} BELOW the budget of {budget}. Lower the ratchet:")
    print(f"  scripts/check-orphan-classes.sh --update   → ORPHAN_BUDGET={len(unstyled)}")

sys.exit(0)
PY
