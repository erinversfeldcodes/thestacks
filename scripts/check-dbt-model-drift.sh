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
import os
import re
import sys

DOC = "docs/technical-architecture.md"
doc_src = open(DOC, encoding="utf-8").read()

# "total" is optional so the prose can read naturally in each layer — the doc
# says "40 total staging views" but "8+ intermediate models".
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

# ---------------------------------------------------------------------------
# Every model named in the event→model refresh map must exist on disk.
#
# WHY THIS IS A GATE AND NOT A TEST. dbt exits 0 on a selector that matches
# nothing: `dbt ls --select mart_gone` prints "does not match any enabled nodes
# / No nodes selected!" and returns 0. So a map entry naming a deleted model
# produces a GREEN dbt run that refreshes nothing, and the warehouse goes stale
# behind it. Proven by planting exactly that: the worker suite stayed green at
# 332 tests, `dbt parse` exited 0, and so did this script before this block
# existed. Nothing at any rung could see it.
#
# The map couples Elixir strings to dbt filenames, which is why neither side's
# own tooling catches a mismatch — the Elixir side has no model list and the dbt
# side never reads the map. A set difference across the boundary is the only
# thing that can.
#
# Model names are read ONLY from the `=> [...]` list literals. The map's own
# comments name several DELETED models on purpose (recording why their keys
# went), so a naive scan of the block would flag the documentation of a
# deletion as a deletion.
HANDLER = "apps/core/lib/stacks/workers/dbt_refresh_handler.ex"

try:
    handler_src = open(HANDLER, encoding="utf-8").read()
except OSError as exc:
    print(f"FAIL: cannot read {HANDLER}: {exc}", file=sys.stderr)
    sys.exit(1)

mapping = re.search(r"@model_mapping\s+%\{(.*?)\n  \}", handler_src, re.DOTALL)
if not mapping:
    print(
        f"FAIL: no @model_mapping block found in {HANDLER}.\n"
        "This gate reads that map to prove every model it names exists. If the map moved "
        "or was renamed, point this check at its new home rather than deleting the check.",
        file=sys.stderr,
    )
    sys.exit(1)

mapped = {
    name
    for list_body in re.findall(r"=>\s*\[([^\]]*)\]", mapping.group(1))
    for name in re.findall(r'"([^"]+)"', list_body)
}

on_disk = {
    os.path.basename(p)[: -len(".sql")]
    for p in glob.glob("dbt/models/**/*.sql", recursive=True)
}

missing = sorted(mapped - on_disk)
if missing:
    print(
        "FAIL: the dbt refresh map names models that do not exist on disk.",
        file=sys.stderr,
    )
    for name in missing:
        print(f"  {name}", file=sys.stderr)
    print(
        f"\nEach would make {HANDLER} enqueue a dbt run whose selector matches nothing — "
        "which dbt reports as success. Either restore the model or remove it from the map, "
        "and if an event loses every model it refreshed, unsubscribe the handler from it too.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: all {len(mapped)} model(s) named in the dbt refresh map exist on disk.")
PY
