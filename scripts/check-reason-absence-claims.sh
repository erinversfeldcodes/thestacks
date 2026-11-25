#!/usr/bin/env bash
# A free-text reason that claims a TEST FILE does not assert something must be
# true. RL-495's (a) instance: `check-script-wiring.sh`'s allowlist reason said
# `deployed_db_roles_test.exs` "never asserts rolcanlogin" in the SAME commit
# that added that assertion — and the structural wiring check could never see a
# false free-text reason. This verifies every such absence-claim against the
# cited file, so the lie reds instead of ageing into a generated doc.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import os
import re
import sys

PATHS = sorted(
    set(
        glob.glob("scripts/**/*.sh", recursive=True)
        + glob.glob("scripts/**/*.py", recursive=True)
        + glob.glob("test/**/*.sh", recursive=True)
    )
)

# Anti-vacuity floor: a scan that found almost nothing has misfired (a wrong
# glob, a bad cwd) and must refuse rather than pass empty.
MIN_GATE_FILES = 100
if len(PATHS) < MIN_GATE_FILES:
    print(
        f"FAIL check-reason-absence-claims: only {len(PATHS)} gate file(s) found; "
        f"floor is {MIN_GATE_FILES}. A vacuous scan is a refusal, not a pass.",
        file=sys.stderr,
    )
    sys.exit(1)

# A cited test file, then within the same sentence (no `.` sentence-end crossed)
# a negated assertion about a symbol: "<file>_test.exs … never|does not|doesn't|
# did not|cannot … assert[s] <symbol>".
CLAIM = re.compile(
    r"([\w./-]+_test\.exs)"
    r"(?:[^.]|\.(?!\s))*?"
    r"\b(?:never|does not|doesn't|did not|cannot|no longer)\b"
    r"(?:[^.]|\.(?!\s))*?"
    r"\bassert\w*\b\s+[\"'`]?([a-zA-Z_][\w]*)",
    re.IGNORECASE,
)

violations = []
for path in PATHS:
    # This gate's own documentation cites the historical example verbatim; it is
    # not a live allowlist reason, so scanning it would flag the very text that
    # explains the check — the "a gate reads its own comment as config" trap.
    if path.endswith("check-reason-absence-claims.sh"):
        continue
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        continue
    for m in CLAIM.finditer(src):
        test_file, symbol = m.group(1), m.group(2)
        base = os.path.basename(test_file)
        hits = glob.glob(f"**/{base}", recursive=True)
        if not hits:
            continue
        present = any(
            re.search(rf"\b{re.escape(symbol)}\b", open(h, encoding="utf-8").read())
            for h in hits
        )
        if present:
            line = src[: m.start()].count("\n") + 1
            violations.append((path, line, test_file, symbol, hits[0]))

if violations:
    print(
        "FAIL check-reason-absence-claims: a reason claims a test does NOT assert a",
        file=sys.stderr,
    )
    print("symbol that IS present in the cited file:", file=sys.stderr)
    for path, line, tf, sym, hit in violations:
        print(f"  {path}:{line} says {tf} does not assert `{sym}` — but {hit} does.", file=sys.stderr)
    sys.exit(1)

print(f"check-reason-absence-claims: OK ({len(PATHS)} gate files scanned, no false absence-claim).")
PY
