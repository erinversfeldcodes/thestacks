#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

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
Page/ForgotPasswordNoticeTest.elm|60 seconds|#374: the superset "wait 60 seconds" is EXACTLY the copy being guarded against — a retry-after the response did not carry
Page/AdminInvitesTest.elm|STK-4F2A-9C1D-XXXX|US-14.1.3 show-once: runtime data, not source copy — the sibling test proves the SAME literal renders from the create response, so the absence here cannot pass vacuously
Page/BookshelfProgramTest.elm|Fetching your Library…|copy is concatenated at render — Fetching plus whose plus label — so no single source literal exists; the sibling ensureViewHas proves the exact text renders, so the absence cannot pass vacuously
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

src_literals = []
for path in glob.glob("frontend/src/**/*.elm", recursive=True):
    with open(path, encoding="utf-8") as fh:
        src_literals.extend(re.findall(r'"([^"\\\n]{2,})"', fh.read()))
src_literals = list(set(src_literals))

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
