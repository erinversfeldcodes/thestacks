#!/usr/bin/env bash
# The documented dbt model counts must match the models on disk.
#
# The architecture doc sketches the three dbt layers and states how many models
# each holds. Those numbers were written once and never checked: staging said
# "30 total staging views" against a real 41, and marts said "16+" against a real
# 15 — a floor the tree had fallen below, which is the direction that quietly
# turns a claim false.
#
# The counts matter beyond tidiness. "All 30 staging models are proto-generated"
# is load-bearing folklore in this project — it is how people reason about what
# `mix proto.sync` owns — and it has been wrong by eleven models.
#
# SOURCE OF TRUTH  dbt/models/{staging,intermediate,marts}/**.sql
# CHECKED AGAINST  the model-tree block in docs/technical-architecture.md.
# "(N total X)" is read as an exact count; "(N+ X)" as a floor.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import re
import sys

DOC = "docs/technical-architecture.md"
doc_src = open(DOC, encoding="utf-8").read()

# "total" is optional so the prose can read naturally in each layer — the doc
# says "41 total staging views" but "10+ intermediate models".
LAYERS = {
    "staging": r"\((\d+)(\+?)\s+(?:total\s+)?staging views\)",
    "intermediate": r"\((\d+)(\+?)\s+(?:total\s+)?intermediate models\)",
    "marts": r"\((\d+)(\+?)\s+(?:total\s+)?mart models\)",
}

problems = []
checked = 0

for layer, pattern in LAYERS.items():
    actual = len(glob.glob(f"dbt/models/{layer}/**/*.sql", recursive=True))
    m = re.search(pattern, doc_src)
    if not m:
        problems.append(f"{layer}: no count claim found in {DOC} (expected a '(N …)' note)")
        continue

    checked += 1
    claimed, floor = int(m.group(1)), m.group(2) == "+"

    if floor and actual < claimed:
        problems.append(
            f"{layer}: doc claims at least {claimed}, found {actual} — the tree fell below its own floor"
        )
    elif not floor and actual != claimed:
        problems.append(f"{layer}: doc claims exactly {claimed}, found {actual}")

if problems:
    print("FAIL: the documented dbt model counts do not match the models on disk.", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print(
        f"\nThe models are the source of truth. Update the layer notes in {DOC}.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: {checked} dbt layer count(s) match the models on disk.")
PY
