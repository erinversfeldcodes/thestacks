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
import pathlib
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

# ⛔ A FRACTION OF AN INDEPENDENT ENUMERATION, plus an absolute minimum.
#
# An empty violation list is what a clean tree produces AND what a broken
# discovery produces, so the population has to be floored. A bare constant —
# this used to be a flat minimum of 60 against ~154 discovered — would sit
# happily through a 60% erosion of discovery while still reporting clean.
#
# ⚠️ The sibling sigpipe gate takes a fraction of a LARGER denominator: it floors
# the pipefail-bearing count (137) against all discovered scripts (147), two
# genuinely different populations. That shape does NOT transfer here, because the
# population this gate floors IS its discovered set, and asking whether it is at
# least half of itself is vacuous for every value.
#
# So the denominator is a SECOND, INDEPENDENT enumeration: the filesystem, which
# knows nothing about git's index or its pathspecs. If git-based discovery ever
# returns less than half of what the filesystem can see, the DISCOVERY is broken
# rather than the repository being small. Measured today: 154 via git, 165 via
# the filesystem — the gap is vendored and generated output the exclusions below
# do not catch, which is why this is a fraction rather than an equality.
FS_EXCLUDE = ("/node_modules/", "/.git/", "/.venv/", "/_build/", "/deps/", "/elm-stuff/")
fs_scripts = [
    str(path)
    for path in pathlib.Path(".").rglob("*.sh")
    if path.is_file() and not any(frag in f"/{path}/" for frag in FS_EXCLUDE)
]

# The absolute minimum still matters: a fraction of zero is zero and passes, so
# a total failure of BOTH enumerations would otherwise read as a clean sweep.
ABSOLUTE_MIN = 60
floor = max(len(fs_scripts) // 2, ABSOLUTE_MIN)

if len(scripts) < floor:
    print(
        f"FAIL: git discovery found {len(scripts)} shell script(s); the filesystem shows "
        f"{len(fs_scripts)}, so the floor is {floor}.",
        file=sys.stderr,
    )
    print(
        "       Two independent enumerations disagree by more than half, which means the\n"
        "       DISCOVERY is broken rather than the repository being small. An empty\n"
        "       violation list over an eroded corpus is exactly the result this floor\n"
        "       exists to refuse. This is a refusal, not a pass.",
        file=sys.stderr,
    )
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
