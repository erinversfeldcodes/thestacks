#!/usr/bin/env bash
# check-prose-assertions.sh — find negative Elm test assertions that can pass vacuously.
#
# WHY THIS EXISTS
#
# `Query.hasNot [ Selector.text "X" ]` asserts an affordance is ABSENT. `Selector.text` matches on a
# SUBSTRING, so if "X" is a strict substring of some other text the app renders, the assertion can be
# satisfied by that other element — and then it passes whether the thing it guards is present or not.
#
# Two real instances, both found the hard way:
#
#   1. `BookshelfReadOnlyTest` asserted no *"Add shelf"* button in a read-only view. The button says
#      **"Add a shelf"**. The assertion matched nothing at all, so it passed regardless — and would
#      have kept passing if the organiser had leaked into a read-only view, which is the single thing
#      it existed to prevent. A SECURITY guarantee, disarmed by a copy edit.
#   2. `AdminSourceApprovalTest` asserted no *"Approve"* button on a decided source. The page's filter
#      tab reads **"Approved"** — a superstring — so the assertion matched the tab and passed while
#      the buttons were present. Caught only because the test failed when it should have succeeded.
#
# THE TWO RULES THIS CHECKS
#
# The two instances above fail in OPPOSITE ways, and a check that only knows one of them misses the
# other. This was proven by probe: an early version implemented only rule B and did **not** flag the
# reintroduced "Add shelf" assertion, while its own header claimed that was the motivating case.
#
#   A. **MATCHES NOTHING** — "X" appears nowhere in `frontend/src/`, so the assertion can never fail.
#      This is instance 1: "Add shelf" is not a substring of "Add a shelf"; it is simply absent.
#   B. **MATCHES THE WRONG THING** — "X" is a strict substring of some other rendered literal, so the
#      selector can bind to that instead. This is instance 2: "Approve" ⊂ "Approved".
#
# Both are *possibility* checks, not proofs — hence the allowlist.
#
# ⚠️ Note what this deliberately does NOT do: the naive check ("is the string absent from src?") would
# have MISSED instance 1 above, because "Add a shelf" *is* in src — only the assertion's "Add shelf"
# was not. Absence from source is the wrong signal; near-collision is the right one.
#
# ⚠️ **Known limitation, stated rather than hidden: this has no view scope.** It compares against every
# literal in `frontend/src/`, but a collision only *bites* when both strings can render in the view
# under test. `MainNavTest` renders `Main.viewNav` alone, so "Admin" colliding with "Admin sign-in"
# (a different view entirely) is inert. Which view a test renders is not statically determinable here,
# so the check deliberately over-reports and the allowlist carries the reasoning.
#
# That makes this a **prompt to review**, not a proof of a bug. Its real value is forward-looking: a
# NEW prose negative that collides with existing copy cannot land without someone looking at it.
#
# Usage:
#   scripts/check-prose-assertions.sh            # report; exit 1 if an unlisted risk is found
#   scripts/check-prose-assertions.sh --list     # print every prose negative with its verdict
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

# Reviewed prose negatives that cannot do the wrong thing. Keyed on **file + the asserted text**, not
# file:line — a line-number allowlist rots the moment anyone adds a comment above the assertion, and
# then this check starts failing on entries that were already reviewed. (Observed immediately: adding
# an explanatory comment shifted a line and un-allowlisted it.)
#
# Each entry MUST carry a reason. Adding one is a claim that you looked.
ALLOWLIST=$(cat <<'LIST'
NavigationProgramTest.elm|The Power of Habit|fixture book title, not an affordance — renders only if the bug returns
Page/ProfileTest.elm|Ada Lovelace|fixture author name, not an affordance
MainViewTest.elm|View Antilibrary|deliberate "stays deleted" guard for pre-#235 copy — matches nothing BY DESIGN
MainViewTest.elm|Add a Book|deliberate "stays deleted" guard for pre-#235 copy
MainNavTest.elm|Antilibrary|renders Main.viewNav ALONE; "In your Antilibrary" is bookshelf-page copy
MainNavTest.elm|Reading Pile|renders Main.viewNav ALONE; "In your Reading Pile" is bookshelf-page copy
MainNavTest.elm|Sign In|renders Main.viewNav ALONE; "Back to Sign In" is login-card copy
MainNavTest.elm|Admin|renders Main.viewNav ALONE; "Admin sign-in" is the #303 gate, a different view
Page/SettingsHubTest.elm|Notifications|renders the settings hub; "Notifications — The Stacks" is a <title>
AdminRemovalRequestsTest.elm|Approve|renders the queue ALONE; "Approved" is SourceApproval's filter tab
SessionExpiryTest.elm|closed your session|supersets are ALL expiry-banner variants; matching any is the intent
Page/BookshelfReadOnlyTest.elm|Could not load your|supersets are ALL owner-error variants; matching any is intended
LIST
)

python3 - "$MODE" "$ALLOWLIST" <<'PY'
import os, re, sys, glob

mode, allowlist_raw = sys.argv[1], sys.argv[2]
allow = {}
for line in allowlist_raw.strip().splitlines():
    parts = line.split("|")
    if len(parts) >= 3:
        allow[(parts[0].strip(), parts[1].strip())] = parts[2].strip()

# Every string literal the app renders.
src_literals = []
for path in glob.glob("frontend/src/**/*.elm", recursive=True):
    with open(path, encoding="utf-8") as fh:
        # NOTE: exclude newlines. Without that, the pattern spans from one quote to the next
        # ACROSS lines and captures whole code blocks as if they were rendered copy, producing
        # nonsense "can also match" candidates and false RISK verdicts.
        src_literals.extend(re.findall(r'"([^"\\\n]{2,})"', fh.read()))
src_literals = list(set(src_literals))

# Whole-file scan with DOTALL-ish whitespace: `hasNot` and its selector are routinely on separate
# lines, and a per-line regex silently missed every one of those — including the original defect this
# script exists to catch. Found by probe, not by review.
NEG = re.compile(r'(?:hasNot|expectViewHasNot)\s*\[\s*Selector\.text\s+"([^"]+)"')

findings, listed = [], []
for path in glob.glob("frontend/tests/**/*.elm", recursive=True):
    rel = path.replace("frontend/tests/", "")
    text = open(path, encoding="utf-8").read()
    for m in NEG.finditer(text):
            lineno = text.count("\n", 0, m.start()) + 1
            needle = m.group(1)
            key = f"{rel}:{lineno}"
            exact = needle in src_literals
            # Rule B: another rendered literal that CONTAINS this one.
            supers = [s for s in src_literals if needle in s and s != needle]
            # Rule A: nothing renders it at all, so the assertion can never fail.
            matches_nothing = not exact and not supers

            if matches_nothing:
                reason = "MATCHES NOTHING — no literal in frontend/src/ contains this text"
            elif supers:
                reason = f"can also match: {supers[:3]}"
            else:
                reason = ""

            verdict = "safe"
            if matches_nothing or supers:
                verdict = "allowlisted" if (rel, needle) in allow else "RISK"
            listed.append((key, needle, verdict, reason))
            if verdict == "RISK":
                findings.append((key, needle, reason))

if mode == "--list":
    print(f"{len(listed)} prose negative assertion(s):\n")
    for key, needle, verdict, reason in sorted(listed):
        mark = {"safe": "  ok ", "allowlisted": "  -- ", "RISK": "  !! "}[verdict]
        print(f'{mark}{key}  "{needle}"')
        if verdict == "allowlisted":
            print(f"        allowlisted: {allow[(key.rsplit(':', 1)[0], needle)]}")
        elif reason:
            print(f"        {reason}")
    sys.exit(0)

if findings:
    print("Prose negative assertions that can pass vacuously:\n")
    for key, needle, reason in findings:
        print(f'  {key}')
        print(f'    asserts absence of "{needle}" — {reason}')
        print(f'    → Anchor on a `data-testid` instead, or allowlist it with a reason.\n')
    print(f"{len(findings)} risky assertion(s). Run with --list to see all of them.")
    sys.exit(1)

print(f"No risky prose negative assertions ({len(listed)} checked, {len(allow)} allowlisted).")
sys.exit(0)
PY
