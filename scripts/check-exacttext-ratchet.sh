#!/usr/bin/env bash
#
# check-exacttext-ratchet.sh — ratchet the count of Selector.text copy matches down.
#
# WHAT IT CHECKS
#   Every `Selector.text` in frontend/tests/. Selector.text is a CONTAINMENT match: a
#   positive copy assertion built on it cannot detect APPENDED text — append " And more."
#   to a rendered sentence and the assertion stays green, so it is an invisible constraint
#   on the words that a natural rewording breaks silently. `exactText` pins the whole
#   string. This counts the containment matches and ratchets the count down as copy
#   assertions convert to exactText.
#
# ⚖️ A RATCHET, NOT A FLOOR, and the direction matters. The count may only fall. It fails
#   when the count RISES (a new containment copy assertion, a regression) AND when it FALLS
#   without MAX_SELECTOR_TEXT being lowered in the same change — because a drop left
#   unrecorded becomes slack the next regression hides inside. Not every Selector.text is
#   copy (some pin a stable control label where containment is fine), so the floor is
#   wherever the legitimate uses plateau, not zero; the audit decides each site, the gate
#   only forbids regression and records progress.
#
# ⚠️ Comments are blanked (nested {- -} and -- lines) before counting, so a Selector.text
#   named in prose is not counted. The stripper is duplicated across sibling check-*.sh
#   gates; extracting one shared helper is a tracked follow-up (RL-503), not this gate's job.
#
# Usage:
#   scripts/check-exacttext-ratchet.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# ⛔ RATCHET. Lower this as copy assertions convert to exactText; never raise it.
# EXACTTEXT_MAX / EXACTTEXT_ROOT override only the platform test, which points the
# gate at a mktemp copy with a planted violation so probes never touch the real tree.
MAX_SELECTOR_TEXT="${EXACTTEXT_MAX:-181}"
TESTS_ROOT="${EXACTTEXT_ROOT:-frontend/tests}"

python3 - "$MAX_SELECTOR_TEXT" "$TESTS_ROOT" <<'PY'
import sys, re, pathlib

max_allowed = int(sys.argv[1])
tests_root = sys.argv[2]


def strip_comments(text):
    # Nesting-aware {- -} removal (Elm block comments nest), then -- line comments.
    out = []
    depth = 0
    i = 0
    n = len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "{-":
            depth += 1
            i += 2
        elif two == "-}" and depth > 0:
            depth -= 1
            i += 2
        elif depth == 0:
            out.append(text[i])
            i += 1
        else:
            i += 1
    code = "".join(out)
    return "\n".join(re.sub(r"--.*$", "", line) for line in code.splitlines())


root = pathlib.Path(tests_root)
files = sorted(root.rglob("*.elm"))
if not files:
    print(f"FAIL: found no Elm test files under {tests_root}/ — gate cannot measure.")
    sys.exit(1)

count = 0
for f in files:
    code = strip_comments(f.read_text())
    count += len(re.findall(r"\bSelector\.text\b", code))

if count > max_allowed:
    print(f"FAIL: {count} Selector.text copy match(es), above the ratchet of {max_allowed}.")
    print("A positive copy assertion on Selector.text cannot detect appended text; use exactText.")
    sys.exit(1)

if count < max_allowed:
    print(f"FAIL: only {count} Selector.text match(es), but the ratchet still says {max_allowed}.")
    print(f"Ground was gained and left unrecorded — lower MAX_SELECTOR_TEXT to {count} in this change.")
    sys.exit(1)

print(f"OK: {count} Selector.text match(es), at the ratchet of {max_allowed}.")
sys.exit(0)
PY
