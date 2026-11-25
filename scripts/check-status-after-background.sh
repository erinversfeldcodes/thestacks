#!/usr/bin/env bash
# Refuse a `$?` read that follows a BACKGROUNDED command.
#
# ⛔ WHAT GOES WRONG. `cmd &` launches cmd in the background and returns at once
# with the status of the LAUNCH — 0 unless the shell could not fork. So a `$?`
# on the next line reads 0, not cmd's exit, and a failing background job is read
# as success. MEASURED this very campaign: a `just verify` wrapped in `( … ) &`
# reported its launch status, a failing run looked green, and the real exit had
# to be recovered from the log afterwards.
#
# This is the THIRD shape of one family, and its two siblings refused to be
# folded into each other because a blurred predicate stops being precise:
# `check-status-after-substitution.sh` (a `$(…)` overwrites `$?`) and
# `check-sigpipe-hazards.sh` (a pipeline's `$?` is the last stage's). This one
# needs neither a substitution nor a pipe — just a trailing `&`.
#
# The recorded rule is to capture status where it is set: `out=$(cmd 2>&1);
# rc=$?` for a foreground command, or `cmd & pid=$!; wait "$pid"; rc=$?` when a
# job genuinely must run in the background. A `wait` between the `&` and the
# `$?` makes the read legitimate, so it is not flagged.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import subprocess
import sys

# A lone trailing `&` (background): a `&` at end of a command, NOT `&&`, and NOT
# an fd-dup (`>&`, `|&`). The char before it is any non-&/>/| — so `cmd 2>&1 &`
# (a legitimate background that also redirects) still counts as a background.
LONE_AMP = re.compile(r"[^&>|\s]\s*&\s*$")
DOLLARQ = re.compile(r"\$\?")
WAIT = re.compile(r"\bwait\b")

# Anti-vacuity: the real corpus is ~130 shell scripts; a scan that finds far
# fewer has a broken glob or cwd and must refuse rather than pass empty.
MIN_SH_FILES = 40


def discover():
    """Tracked AND untracked `.sh`, deduplicated — a gate that `git ls-files`
    alone cannot see itself until it is committed, so it would pass on the run
    that first adds it."""
    out = []
    for args in (
        ["git", "ls-files", "*.sh"],
        ["git", "ls-files", "--others", "--exclude-standard", "*.sh"],
    ):
        r = subprocess.run(args, capture_output=True, text=True)
        out.extend(r.stdout.split())
    return sorted(set(p for p in out if p))


def strip_comment(line):
    """Drop a trailing `#` comment, respecting quotes — so this file's own
    header, which spells the hazard out, is not read as a violation."""
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


files = discover()
if len(files) < MIN_SH_FILES:
    print(
        f"FAIL check-status-after-background: found {len(files)} .sh file(s); floor is "
        f"{MIN_SH_FILES}. A vacuous scan is a refusal, not a pass.",
        file=sys.stderr,
    )
    sys.exit(1)

violations = []
for f in files:
    try:
        lines = open(f, encoding="utf-8").read().split("\n")
    except OSError:
        continue
    stripped = [strip_comment(l) for l in lines]
    for i, l in enumerate(stripped):
        if not LONE_AMP.search(l):
            continue
        window = stripped[i + 1 : i + 3]
        if any(WAIT.search(w) for w in window):
            continue  # `cmd & … wait …; rc=$?` is the legitimate form.
        for j, w in enumerate(window, start=i + 1):
            if DOLLARQ.search(w):
                violations.append((f, i + 1, j + 1, lines[i].strip()[:60]))
                break

if violations:
    print(
        "FAIL check-status-after-background: a `$?` is read after a backgrounded command, "
        "so it reads the launch status (0), not the job's:",
        file=sys.stderr,
    )
    for f, amp, q, text in violations:
        print(f"  {f}: `&` at line {amp}, `$?` at line {q}  ({text})", file=sys.stderr)
    print(
        'Capture the status where it is set: `out=$(cmd 2>&1); rc=$?`, or '
        '`cmd & pid=$!; wait "$pid"; rc=$?` when a job must run in the background.',
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"check-status-after-background: OK ({len(files)} .sh scanned; no `$?` read after a lone-`&` background)."
)
PY
