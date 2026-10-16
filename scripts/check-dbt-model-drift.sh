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

# The event keys themselves, for the inverse check further down.
mapped_events = set(re.findall(r'"([a-z_.]+)"\s*=>', mapping.group(1)))

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

# ---------------------------------------------------------------------------
# And the inverse: every event the handler SUBSCRIBES to must either map to
# models or be declared as deliberately keyless.
#
# The check above catches a mapping that points at a deleted model. It cannot
# catch an event with no mapping key at all — `handle_event/1` falls to
# `Map.get(@model_mapping, type) -> nil -> :ok`, enqueues nothing and returns
# success. That is the direction that bites on the day an emitter comes BACK:
# the registry can promise a handler "stays wired" and be telling the truth
# about the subscription while the handler does nothing.
#
# So the handler declares its intentional gaps in @subscribed_without_models,
# each with a reason, and this gate fails on any subscribed event that is in
# neither map.
REGISTRY = "apps/core/lib/stacks/events/registry.ex"

try:
    registry_src = open(REGISTRY, encoding="utf-8").read()
except OSError as exc:
    print(f"FAIL: cannot read {REGISTRY}: {exc}", file=sys.stderr)
    sys.exit(1)

registry_block = re.search(r"@registry\s+%\{(.*?)\n  \}", registry_src, re.DOTALL)
if not registry_block:
    print(f"FAIL: no @registry block found in {REGISTRY}.", file=sys.stderr)
    sys.exit(1)

subscribed = {
    event
    for event, handlers in re.findall(
        r'"([a-z_.]+)"\s*=>\s*\[([^\]]*)\]', registry_block.group(1)
    )
    if "DbtRefreshHandler" in handlers
}

keyless_block = re.search(
    r"@subscribed_without_models\s+%\{(.*?)\n  \}", handler_src, re.DOTALL
)
if not keyless_block:
    print(
        f"FAIL: no @subscribed_without_models block found in {HANDLER}.\n"
        "This gate reads it to tell a deliberate keyless subscription from a forgotten "
        "mapping. If it was removed, the distinction is gone — restore it, or declare an "
        "empty map if every subscription now maps to models.",
        file=sys.stderr,
    )
    sys.exit(1)

declared_keyless = set(re.findall(r'"([a-z_.]+)"\s*=>', keyless_block.group(1)))

unaccounted = sorted(subscribed - mapped_events - declared_keyless)
if unaccounted:
    print(
        "FAIL: the dbt refresh handler is subscribed to events it cannot act on.",
        file=sys.stderr,
    )
    for event in unaccounted:
        print(f"  {event}", file=sys.stderr)
    print(
        f"\nEach reaches `handle_event/1`, matches no mapping, enqueues nothing and returns :ok — "
        f"a handler that reads as wiring and refreshes nothing. Either map its models, unsubscribe "
        f"it in {REGISTRY}, or declare it in @subscribed_without_models with the reason.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"OK: all {len(subscribed)} dbt-refresh subscription(s) either map to models "
    f"or are declared keyless ({len(declared_keyless)} declared)."
)
PY

# ──────────────────────────────────────────────────────────────────────────────
# Two warehouse-governance set differences, proposed by the mart-deletion review
# and deliberately not built at the time.
#
# They are here rather than in a new script because they are the same shape as
# the refresh-map check above — a declared set against a referenced set — and
# because the review's own note was to land them together, before the next
# warehouse deletion rather than after it.
# ──────────────────────────────────────────────────────────────────────────────
python3 - <<'PY'
import glob
import os
import re
import sys

import yaml

failed = False

# ── (a) every mart commits to a reader, or says it is still waiting ──────────
#
# `docs/decisions/010-contract-first-derived-data.md` names this mechanism as
# missing. The motivating fact: of the four surviving marts only
# `mart_community_read_count` has an actual consumer — the other three appear
# only in the refresh map, each kept for a different strength of reason. So the
# rule the next person inherits ("every mart has a named consumer") is NOT the
# rule the warehouse follows, and the difference was not decidable without
# re-litigating the whole set, which a 180-line issue had just had to do.
#
# Prose in the description cannot carry this: it already said "NO CONSUMER" on
# three marts and nothing could read that. A structured key can, and the
# distinction it forces is the useful one — `reader` is a commitment, and
# `pending_reader` is an admission with a reason attached.
MARTS_SCHEMA = "dbt/models/marts/schema.yml"
mart_files = {
    os.path.basename(p)[:-4] for p in glob.glob("dbt/models/marts/*.sql")
}

try:
    marts_doc = yaml.safe_load(open(MARTS_SCHEMA, encoding="utf-8").read()) or {}
except OSError as exc:
    print(f"FAIL: cannot read {MARTS_SCHEMA}: {exc}", file=sys.stderr)
    sys.exit(1)

declared = {}
for model in marts_doc.get("models") or []:
    meta = ((model.get("config") or {}).get("meta") or {})
    meta.update(model.get("meta") or {})  # tolerate the pre-1.10 placement
    declared[model["name"]] = meta

uncommitted = sorted(
    name
    for name in mart_files
    if not (declared.get(name, {}).get("reader") or declared.get(name, {}).get("pending_reader"))
)
undeclared = sorted(mart_files - set(declared))

if undeclared:
    failed = True
    print(
        f"FAIL: {len(undeclared)} mart(s) have a model file but no entry in {MARTS_SCHEMA}:",
        file=sys.stderr,
    )
    for name in undeclared:
        print(f"  {name}", file=sys.stderr)

if uncommitted:
    failed = True
    print(
        f"FAIL: {len(uncommitted)} mart(s) name neither a reader nor a pending_reader:",
        file=sys.stderr,
    )
    for name in uncommitted:
        print(f"  {name}", file=sys.stderr)
    print(
        "\nEvery mart costs a refresh on every run, so each one owes an answer to "
        "'who reads this?'. Add under the model in "
        f"{MARTS_SCHEMA}:\n"
        "    config:\n"
        "      meta:\n"
        "        reader: Module.function        # an actual consumer, or\n"
        "        pending_reader: <why it is kept, and against what>\n"
        "\nA mart that can claim neither is a mart to delete — which is the "
        "decision this gate exists to force while it is still cheap.",
        file=sys.stderr,
    )

if not (undeclared or uncommitted):
    readers = sum(1 for m in declared.values() if m.get("reader"))
    pending = sum(1 for m in declared.values() if m.get("pending_reader") and not m.get("reader"))
    print(
        f"OK: all {len(mart_files)} mart(s) commit to a reader "
        f"({readers} with a consumer, {pending} pending with a stated reason)."
    )

# ── (b) declared dbt sources that no model references ────────────────────────
#
# ⚠️ `check-source-childs` from dbt-checkpoint already performs this check and
# already fires — it was examined and REJECTED as the carrier. Its only
# exemption mechanisms are file-level `--exclude`/`--config`, the installed
# package has no per-node meta key, and all sources share ONE `sources.yml` —
# so exempting the one legitimate case would disable the check for all 41.
#
# Built as a set difference here instead, with the exemption carried by the
# source's own `description`. That is the point: it makes the description
# load-bearing rather than decorative.
SOURCES = "dbt/models/staging/sources.yml"
KEEP_MARKER = "DELIBERATELY HAS NO CONSUMING MODEL"

try:
    sources_doc = yaml.safe_load(open(SOURCES, encoding="utf-8").read()) or {}
except OSError as exc:
    print(f"FAIL: cannot read {SOURCES}: {exc}", file=sys.stderr)
    sys.exit(1)

declared_sources = {}
for source in sources_doc.get("sources") or []:
    for table in source.get("tables") or []:
        declared_sources[table["name"]] = table.get("description") or ""

referenced = set()
for path in glob.glob("dbt/models/**/*.sql", recursive=True):
    body = open(path, encoding="utf-8").read()
    for _src, table in re.findall(
        r"source\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]\s*\)", body
    ):
        referenced.add(table)

unreferenced = sorted(set(declared_sources) - referenced)
unexplained = [t for t in unreferenced if KEEP_MARKER not in declared_sources[t].upper()]

if unexplained:
    failed = True
    print(
        f"FAIL: {len(unexplained)} declared source(s) are referenced by no model and say nothing "
        "about why:",
        file=sys.stderr,
    )
    for table in unexplained:
        print(f"  {table}", file=sys.stderr)
    print(
        f"\nA source nobody reads is either drift or a decision. If it is a decision, say so in "
        f"its `description` in {SOURCES} using the words '{KEEP_MARKER}' plus the reason; "
        "otherwise remove the declaration.",
        file=sys.stderr,
    )
else:
    kept = len(unreferenced)
    print(
        f"OK: {len(declared_sources)} declared source(s), {len(referenced & set(declared_sources))} "
        f"referenced, {kept} unreferenced and explained."
    )

sys.exit(1 if failed else 0)
PY
