#!/usr/bin/env bash
# Every story's Phase cell must name a phase that exists, and nothing else.
#
# The mapping had drifted into three numbering dialects at once. One phase was
# spelled five different ways ("Phase 1 (MVP)", "Phase 1 (extended)", "Phase 1
# (MVP) / Cross-cutting", "Phase 1 (late) / Cross-cutting", "Phase 1 (late MVP) /
# Phase 3 (partner results)"), a stale sub-phase style survived in two docs
# ("Phase 1E.3"), and — worse than either — the cell was being used to smuggle
# STATUS: "Phase 4 (Polish) — **SUPERSEDED by Grafana (#267)**" and
# "Phase 5 (Marketplace) — **Implemented**". Twenty of 122 cells were
# non-canonical.
#
# The scheme, ruled 2026-08-20: the Phase cell holds EXACTLY ONE canonical value.
# Anything else a story needs to say about its phasing — that it spans two, that
# it arrived late, that it is cross-cutting, that it was superseded — goes in an
# adjacent `**Phase note**` row, where it can be read without being parsed.
#
# The canonical set is derived from the mapping's own phase table rather than
# hardcoded here, so adding a phase to that table is all it takes to allow it.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import sys

MAPPING = "docs/implementation-mapping.md"
text = open(MAPPING, encoding="utf-8").read()

# The phase table is the authority: "| **Phase 5** | Marketplace | ..."
# Two row shapes exist and both are legitimate:
#   | **Phase 5** | Marketplace |                    -> "Phase 5 (Marketplace)"
#   | **Phase 1 (extended)** | Auth, Navigation, ... | -> "Phase 1 (extended)"
# In the second the label already carries its own qualifier, so appending the
# name would invent a value nothing uses.
table = set()
# The digit is load-bearing: without it this also matches the `**Phase note**`
# rows, which would admit "Phase note (anything)" as a valid Phase cell and
# turn the gate into a rubber stamp.
for label, name in re.findall(r"^\|\s*\*\*(Phase \d[\w ()]*?)\*\*\s*\|\s*([^|]+?)\s*\|", text, re.M):
    table.add(label if "(" in label else f"{label} ({name.strip()})")
# Two values name no numbered phase and are legitimate: work that belongs to no
# single phase, and work deferred out of the roadmap entirely.
CANON = table | {"Cross-cutting", "Future"}

bad = []
total = 0
for block in re.split(r"\n(?=#### US-)", text):
    m = re.match(r"#### (US-[\d.]+)", block)
    if not m:
        continue
    pm = re.search(r"\|\s*\*\*Phase\*\*\s*\|\s*([^|]+?)\s*\|", block)
    if not pm:
        continue
    total += 1
    if pm.group(1) not in CANON:
        bad.append((m.group(1), pm.group(1)))

# A stale dialect that predates the scheme; it named a sub-phase that no longer
# exists anywhere, so it can only mislead.
stale = []
# Sweep all of docs/ rather than a hand-listed few — the last two survivors were
# hiding in an ADR and a capacity note, not in the files anyone thought to check.
#
# docs/agents/ is EXCLUDED deliberately: the orchestrator has its own gate-phase
# vocabulary ("Phase 2C/2D") that is a different axis entirely, and sweeping it
# would flag correct text.
import glob as _glob

for path in _glob.glob("docs/**/*.md", recursive=True):
    if path.startswith("docs/agents/"):
        continue
    try:
        body = open(path, encoding="utf-8").read()
    except OSError:
        continue
    if re.search(r"Phase \d+[A-Z]\b", body):
        stale.append(path)

if bad or stale:
    print("FAIL: the phase scheme is not being followed.", file=sys.stderr)
    for sid, val in bad:
        print(f"  {sid:<12} Phase cell is not a canonical value: {val!r}", file=sys.stderr)
    for path in stale:
        print(f"  {path}: contains a retired sub-phase identifier (e.g. 'Phase 1E.3')", file=sys.stderr)
    print(
        "\nThe Phase cell holds exactly one value from the mapping's phase table,\n"
        "or 'Cross-cutting', or 'Future'. Anything else the story needs to say about\n"
        "its phasing belongs in an adjacent '**Phase note**' row.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: {total} story Phase cell(s) all name one of {len(CANON)} canonical phases.")
PY
