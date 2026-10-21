#!/usr/bin/env bash
# Refuse a `$?` read in the same command as a substitution that precedes it.
#
# ⛔ WHAT GOES WRONG. A command substitution is a command: it runs, and it sets
# `$?`. So a `$?` appearing later in the SAME command has already been
# overwritten by the substitution, and reads the substitution's status rather
# than the status the author meant.
#
# MEASURED, and it cost real time twice in one session:
#
#     out=$(bash "$g" 2>&1)
#     echo "$(basename "$g") rc=$?"        # <- always the basename's status
#
# `basename` succeeds, so a FAILING gate printed `rc=0` right beside its own
# FAIL text, and `check-script-wiring.sh` was very nearly reported as failing
# open on that evidence.
#
# ⚠️ THIS IS NOT THE SIGPIPE GATE'S PROBLEM, which is why it is a separate
# script. That gate is about a pipeline whose exit status can be 141 instead of
# the one you want; this needs no pipe at all, and folding it in would blur a
# predicate that took five rounds to make precise.
#
# ⛔ THE DISCRIMINATOR MUST NOT FLAG THE MANDATED IDIOM, and the obvious version
# does. `\$\([^)]*\)[^|&]*\$\?` — excluding only `|` and `&` — matches
#
#     out=$(cmd 2>&1); rc=$?
#
# which is CORRECT and is the form this project prescribes: the `;` ends the
# command, the assignment's own status is the substitution's status, and the
# `$?` reads it faithfully. Excluding `;` as well is what separates the two.
#
# MEASURED on seven shapes: with `;` excluded, all seven classify correctly;
# without it, three forms of the prescribed idiom are flagged. Both versions
# report ZERO committed instances today — but there are also zero committed uses
# of `; rc=$?`, so the lenient version is clean only by accident and would fire
# on the first script to follow the project's own rule.
#
# Zero instances is the cheapest moment to add a gate, not a reason to skip it.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import subprocess
import sys

# ⛔ A `$?` in the same command as a preceding substitution. `;`, `&&` and `||`
# all end the command, so a `$?` after one of them is reading the right thing.
HAZARD = re.compile(r"\$\([^)]*\)[^|&;]*\$\?")


def discover_shell_scripts():
    """Tracked and untracked `.sh` files, one list, deduplicated.

    ⚠️ Both halves matter. A sibling gate once reported OK while absent from its
    own corpus, because `git ls-files` cannot see a file that has not been
    committed yet — so it passed on the run that mattered and only began
    checking itself once it was tracked.
    """
    out = []
    for args in (["git", "ls-files", "*.sh"],
                 ["git", "ls-files", "--others", "--exclude-standard", "*.sh"]):
        res = subprocess.run(args, capture_output=True, text=True)
        out.extend(res.stdout.split())
    return sorted(set(p for p in out if p))


def strip_comment(line):
    """Drop a trailing `#` comment, respecting quotes.

    ⚠️ Required, not tidy: this file's own header spells the hazard out as an
    example, and a gate that reads its own documentation as a violation is a
    defect this repository has recorded five times.
    """
    out = []
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and i + 1 < len(line):
                out.append(ch)
                i += 1
                out.append(line[i])
                i += 1
                continue
            if ch == quote:
                quote = None
            out.append(ch)
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


scripts = discover_shell_scripts()

# ⚠️ Anti-vacuity. An empty violation list is what a clean tree produces AND
# what a broken discovery produces. The floor is an absolute minimum rather than
# a fraction, because a fraction of zero is zero and passes.
MIN_SCRIPTS = 60
if len(scripts) < MIN_SCRIPTS:
    print(f"FAIL: discovered only {len(scripts)} shell script(s), expected at least {MIN_SCRIPTS}.", file=sys.stderr)
    print("       Nothing was meaningfully swept. This is a refusal, not a pass.", file=sys.stderr)
    raise SystemExit(1)

violations = []
for path in scripts:
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    for n, raw in enumerate(text.split("\n"), 1):
        line = strip_comment(raw).strip()
        if not line:
            continue
        if HAZARD.search(line):
            violations.append((path, n, line))

if violations:
    print(f"FAIL: {len(violations)} site(s) read `$?` after a substitution in the same command:", file=sys.stderr)
    for path, n, line in violations:
        print(f"  {path}:{n}", file=sys.stderr)
        print(f"      {line}", file=sys.stderr)
    print(
        "\nA command substitution runs before the command it sits in, and sets `$?`. So the\n"
        "`$?` above reads the SUBSTITUTION's status, not the one you meant — and because\n"
        "substitutions usually succeed, the reported status is usually 0. A failing command\n"
        "then prints a successful status beside its own error text.\n\n"
        "Split them: capture the status first, then build the message.\n\n"
        "    out=$(thing 2>&1)\n"
        "    rc=$?\n"
        "    echo \"$(basename \"$f\") rc=$rc\"\n",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(f"OK: {len(scripts)} shell script(s), no `$?` read after a substitution in the same command.")
PY
