#!/usr/bin/env bash
#
# check-prose-assertions.sh — negative view assertions anchored on prose that can pass vacuously.
#
# WHAT IT CHECKS
#   Every `hasNot [ Selector.text "…" ]` in frontend/tests/. Asserting the ABSENCE of a
#   string only means something if that exact string is what the view would render when
#   the bug is present. Two ways it stops meaning anything: the needle matches no literal
#   anywhere in frontend/src/, so it can never appear and the assertion is a tautology; or
#   it is a strict substring of some OTHER literal, so it passes for the wrong reason.
#
# WHY THE ALLOWLIST LIVES INSIDE THE PYTHON, NOT IN A `$(cat <<…)`
#   It used to be `ALLOWLIST=$(cat <<'LIST' … LIST)` above the python heredoc. Under bash
#   3.2 — which is every macOS /bin/bash — that does not PARSE. bash 3.2 scans `$(…)` for
#   the closing paren with its ordinary quote-tracking tokenizer and does not treat a
#   here-document body inside it as data, so one apostrophe in the prose
#   ("…is SourceApproval's filter tab") opened a single-quote state that never closed. The
#   scan ran past the LIST terminator, past the `)`, and on into the python heredoc, where
#   quoting finally rebalanced and bash died on a line of Python:
#       check-prose-assertions.sh: line 43: syntax error near unexpected token `('
#   bash 5 parses `$(…)` by recursive descent and handles the here-document correctly, so
#   CI was green for as long as this gate had existed while the gate was dead on every
#   developer machine. One top-level here-document has no such hazard — bash reads its body
#   line-by-line as data under both. Do not reintroduce a `$(cat <<…)` here.
#
# Usage:
#   scripts/check-prose-assertions.sh            # fail on risky assertions
#   scripts/check-prose-assertions.sh --list     # every assertion, with its verdict
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import glob
import re
import sys

mode = sys.argv[1]

# (test file relative to frontend/tests/, needle, why it is safe despite the finding)
ALLOWLIST = [
    ("NavigationProgramTest.elm", "The Power of Habit",
     "fixture book title, not an affordance — renders only if the bug returns"),
    ("Page/ProfileTest.elm", "Ada Lovelace",
     "fixture author name, not an affordance"),
    ("MainNavTest.elm", "Antilibrary",
     "renders Main.viewNav ALONE; 'In your Antilibrary' is bookshelf-page copy"),
    ("MainNavTest.elm", "Reading Pile",
     "renders Main.viewNav ALONE; 'In your Reading Pile' is bookshelf-page copy"),
    ("MainNavTest.elm", "Sign In",
     "renders Main.viewNav ALONE; 'Back to Sign In' is login-card copy"),
    ("MainNavTest.elm", "Admin",
     "renders Main.viewNav ALONE; 'Admin sign-in' is the admin gate, a different view"),
    ("AdminRemovalRequestsTest.elm", "Approve",
     # The apostrophe here is load-bearing: it is the exact character that broke the
     # old `$(cat <<…)` under bash 3.2, so leaving it in place means any reintroduction
     # of that shape fails immediately instead of years later.
     "renders the queue ALONE; 'Approved' is SourceApproval's filter tab"),
    ("SessionExpiryTest.elm", "closed your session",
     "supersets are ALL expiry-banner variants; matching any is the intent"),
    ("Page/BookshelfReadOnlyTest.elm", "Could not load your",
     "supersets are ALL owner-error variants; matching any is intended"),
    ("Page/ForgotPasswordNoticeTest.elm", "60 seconds",
     "the superset 'wait 60 seconds' is EXACTLY the copy being guarded against — "
     "a retry-after the response did not carry"),
    ("Page/AdminInvitesTest.elm", "STK-4F2A-9C1D-XXXX",
     "show-once code: runtime data, not source copy — the sibling test proves the SAME "
     "literal renders from the create response, so the absence here cannot pass vacuously"),
    ("Page/BookshelfProgramTest.elm", "Fetching your Library…",
     "copy is concatenated at render — Fetching plus whose plus label — so no single source "
     "literal exists; the sibling ensureViewHas proves the exact text renders, so the "
     "absence cannot pass vacuously"),
]
allow = {(f, needle): why for f, needle, why in ALLOWLIST}

src_literals = set()
for path in glob.glob("frontend/src/**/*.elm", recursive=True):
    with open(path, encoding="utf-8") as fh:
        src_literals.update(re.findall(r'"([^"\\\n]{2,})"', fh.read()))

NEG = re.compile(r'(?:hasNot|expectViewHasNot)\s*\[\s*Selector\.text\s+"([^"]+)"')

findings, listed, used_allow = [], [], set()
for path in glob.glob("frontend/tests/**/*.elm", recursive=True):
    rel = path.replace("frontend/tests/", "")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for m in NEG.finditer(text):
        lineno = text.count("\n", 0, m.start()) + 1
        needle = m.group(1)
        key = f"{rel}:{lineno}"
        exact = needle in src_literals
        supers = [s for s in src_literals if needle in s and s != needle]
        matches_nothing = not exact and not supers

        if matches_nothing:
            reason = "MATCHES NOTHING — no literal in frontend/src/ contains this text"
        elif supers:
            reason = f"can also match: {supers[:3]}"
        else:
            reason = ""

        verdict = "safe"
        if matches_nothing or supers:
            if (rel, needle) in allow:
                verdict = "allowlisted"
                used_allow.add((rel, needle))
            else:
                verdict = "RISK"
        listed.append((key, needle, verdict, reason))
        if verdict == "RISK":
            findings.append((key, needle, reason))

# An allowlist entry that no longer suppresses anything is dead config: the test was
# deleted, renamed, or its needle stopped being risky. Left alone it rots into a licence
# nobody reviewed, so it fails the same way check-route-clients.sh fails a stale entry.
stale = [(f, needle) for f, needle, _ in ALLOWLIST if (f, needle) not in used_allow]

if mode == "--list":
    print(f"{len(listed)} prose negative assertion(s):\n")
    for key, needle, verdict, reason in sorted(listed):
        mark = {"safe": "  ok ", "allowlisted": "  -- ", "RISK": "  !! "}[verdict]
        print(f'{mark}{key}  "{needle}"')
        if verdict == "allowlisted":
            print(f"        allowlisted: {allow[(key.rsplit(':', 1)[0], needle)]}")
        elif reason:
            print(f"        {reason}")
    for f, needle in stale:
        print(f'  ?? {f}  "{needle}"  <- allowlist entry no longer applies')
    sys.exit(0)

failed = False

if findings:
    failed = True
    print("Prose negative assertions that can pass vacuously:\n")
    for key, needle, reason in findings:
        print(f"  {key}")
        print(f'    asserts absence of "{needle}" — {reason}')
        print("    → Anchor on a `data-testid` instead, or allowlist it with a reason.\n")
    print(f"{len(findings)} risky assertion(s). Run with --list to see all of them.")

if stale:
    failed = True
    print(f"\n{len(stale)} allowlist entr(ies) no longer apply — delete them from ALLOWLIST:")
    for f, needle in stale:
        print(f'  {f}  "{needle}"')
    print("  The assertion was removed, or it stopped being risky. Either way the")
    print("  exemption is now unreviewed licence for whatever takes its place.")

if failed:
    sys.exit(1)

print(f"No risky prose negative assertions ({len(listed)} checked, {len(allow)} allowlisted).")
sys.exit(0)
PY
