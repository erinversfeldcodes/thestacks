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
# The project's standing rule is that derived data is contract-first: a mart
# exists because something reads it, and the contract says which. That rule had
# no mechanism behind it. The motivating fact: of the four surviving marts only
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

# ── (a2) every incremental model says how a deletion reaches it ──────────────
#
# ⚠️ An incremental model's `is_incremental()` window selects rows whose
# SURVIVING timestamp is newer than the last refresh. A DELETE upstream updates
# no surviving row, so a deleted entity never enters the window and its row
# persists. Measured: a book's `read_count` read 3, one placement was
# hard-deleted, the truth became 2, an incremental refresh selected nothing, and
# the mart still read 3.
#
# This cannot be DETECTED by reading the SQL — whether a window can observe a
# deletion depends on what the upstream relation does with deleted rows, which
# is a fact about the application, not the model. So it is declared, like the
# mart readers above: every incremental model names its `deletion_handling`,
# and the residual window if it has one. Writing that sentence is what makes
# someone notice there IS a window.
incremental_models = sorted(
    os.path.basename(path)[:-4]
    for path in glob.glob("dbt/models/**/*.sql", recursive=True)
    if "materialized='incremental'" in open(path, encoding="utf-8").read()
)

missing_handling = [
    name
    for name in incremental_models
    if not declared.get(name, {}).get("deletion_handling")
]

if missing_handling:
    failed = True
    print(
        f"FAIL: {len(missing_handling)} incremental model(s) do not say how a deletion "
        "reaches them:",
        file=sys.stderr,
    )
    for name in missing_handling:
        print(f"  {name}", file=sys.stderr)
    print(
        "\nAn incremental window keys on surviving rows, so a DELETE upstream is invisible "
        "to it and the row persists — measured once as a community read count stuck at 3 "
        "while the truth was 2. Add under the model's `config: meta:`:\n"
        "        deletion_handling: <the mechanism, and the residual window if any>\n"
        "\nIf the honest answer is 'nothing — it goes stale until the daily full refresh', "
        "that is a valid declaration and is the point: it is then written down instead of "
        "being discovered from a wrong number.",
        file=sys.stderr,
    )
elif incremental_models:
    print(
        f"OK: all {len(incremental_models)} incremental model(s) declare how deletions "
        "reach them."
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

# -- (c) dbt model names named in ELIXIR sources must exist on disk ----------
#
# The surface no gate protected, and the reason it needs one: a fixture naming
# a deleted model is still a valid string. Nothing contradicts it.
#
# The live instance: a dbt-refresh job test used three DELETED models as the
# fixture for its three-model join assertion and KEPT PASSING, because the job
# forwards whatever list it is handed without checking the models exist. The
# test asserted argv joining correctly while documenting a warehouse that was
# gone -- and a reader, or a machine, taking that fixture as a statement about
# the warehouse would be wrong.
#
# Two deletions in a row ticked "docs propagation" after sweeping only docs/.
# The misses outside the docs tree were the ones that could mislead a machine
# rather than merely a reader, and this is the cheapest of them to mechanise:
# the naming convention makes the population decidable.
#
# ⚠️ Model names are read ONLY from STRING LITERALS in NON-COMMENT code, and
# both narrowings were forced by measurement — the first draft scanned raw
# lines and reported ten findings, every one of them noise.
#
#   * **Comments must be stripped.** All eight model-name findings were in
#     comments *documenting those models' own deletion* — in the refresh
#     handler and in the job test that now asserts `refute_enqueued` for them.
#     Flagging those would punish exactly the propagation documentation this
#     rule asks for. The sibling refresh-map gate above already says so about
#     the same file; this gate is the fourth place in this repository where a
#     check read a comment as configuration.
#   * **Only string literals.** `int_param(params, "limit")` in
#     `feedback_admin_controller.ex` is an Elixir FUNCTION, and `int_` is an
#     ordinary abbreviation for integer. A dbt model referenced from Elixir is
#     always a quoted string — the refresh map, a job's `models:` arg — so the
#     quotes are the discriminator that separates a reference from an
#     identifier that merely shares a prefix.
#
# `#(?!\{)` rather than `#` for the comment strip: `#{` opens an Elixir
# interpolation, and treating it as a comment start erases the rest of the line.
# That exact bug made `scripts/check-outbound-test-default.sh` fail open, and
# its own comment records it.
COMMENT = re.compile(r"#(?!\{)[^\n]*")
STRING_LITERAL = re.compile(r'"([^"\n]*)"')
MODEL_TOKEN = re.compile(r"^(?:stg|int|mart)_[a-z0-9_]+$")

# A name may be legitimately mentioned while absent, and the two cases are a
# deletion comment and a synthetic test fixture. Forbidding either would make
# this gate punish the very documentation the rule asks for, and would fire on
# a generator test whose whole job is to feed it invented names. One marker
# covers both: it makes the mention deliberate and reviewable rather than
# indistinguishable from drift.
NO_MODEL_MARKER = "NO SUCH DBT MODEL"

# ⚠️ The proto manifest is EXCLUDED, on the authority of its own comment: its
# `dbt_path` entries are "the path the model returns to, not a claim that it
# exists". A table opted out with `skip_dbt: true` keeps the key because the
# manifest requires it, so a `dbt_path` with no `.sql` behind it is correct by
# design there — and the layer-count gate at the top of this file already
# governs that file from the other direction. Treating those as drift would
# report seven non-defects, which is how a gate teaches people to delete it.
MANIFEST_BASENAME = "persisted.exs"

elixir_mentions = {}
seen_files = set()
for path in glob.glob("apps/core/**/*.ex", recursive=True) + glob.glob(
    "apps/core/**/*.exs", recursive=True
):
    if os.path.basename(path) == MANIFEST_BASENAME:
        continue
    # ⚠️ Deduplicated by real path. `apps/core/assets/proto` is a SYMLINK to
    # `proto/`, so the recursive glob walks the same files twice and would
    # report every finding twice with two different-looking paths — which reads
    # as two sites and is one.
    real = os.path.realpath(path)
    if real in seen_files:
        continue
    seen_files.add(real)
    try:
        body = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    lines = body.splitlines()
    for lineno, raw in enumerate(lines, start=1):
        # The marker counts on the line itself OR on the line directly above —
        # the same rule `scripts/check-e2e-vacuous-guards.sh` uses for its own
        # allow-marker, so the two gates behave the same way for a reader. An
        # inline marker is often the wrong shape: the name usually sits inside a
        # long expression where a trailing comment would not fit.
        previous = lines[lineno - 2] if lineno >= 2 else ""
        if NO_MODEL_MARKER in raw.upper() or NO_MODEL_MARKER in previous.upper():
            continue
        code = COMMENT.sub("", raw)
        for literal in STRING_LITERAL.findall(code):
            if MODEL_TOKEN.match(literal):
                elixir_mentions.setdefault(literal, []).append(f"{path}:{lineno}")

models_on_disk = {
    os.path.basename(p)[: -len(".sql")]
    for p in glob.glob("dbt/models/**/*.sql", recursive=True)
}

# Anti-vacuity. Both populations are derived, and either being empty makes the
# set difference below empty too -- a clean pass over nothing. The scan finding
# no model names at all means the convention or the tree moved, not that Elixir
# stopped referring to the warehouse.
if not models_on_disk:
    failed = True
    print(
        "FAIL: found no dbt models under dbt/models -- the (c) check cannot mean anything.",
        file=sys.stderr,
    )
elif not elixir_mentions:
    failed = True
    print(
        "FAIL: found no stg_/int_/mart_ model names anywhere under apps/core.",
        file=sys.stderr,
    )
    print(
        "This app names models in its refresh map and in its job tests, so zero means this "
        "scan stopped matching the source rather than that the references are gone.",
        file=sys.stderr,
    )
else:
    phantom = sorted(set(elixir_mentions) - models_on_disk)
    if phantom:
        failed = True
        print(
            f"FAIL: {len(phantom)} dbt model name(s) in Elixir sources do not exist on disk:",
            file=sys.stderr,
        )
        for name in phantom:
            sites = elixir_mentions[name]
            shown = ", ".join(sites[:4])
            more = f" (+{len(sites) - 4} more)" if len(sites) > 4 else ""
            print(f"  {name:<40} {shown}{more}", file=sys.stderr)
        print(
            "\nA test fixture or comment naming a deleted model is still a valid string, so "
            "nothing else will ever contradict it -- a job test can keep passing while "
            "documenting a warehouse that is gone. Either restore the model, update the "
            f"reference, or mark the line '{NO_MODEL_MARKER}' when the mention is deliberately "
            "about something that was removed.",
            file=sys.stderr,
        )
    else:
        print(
            f"OK: all {len(elixir_mentions)} dbt model name(s) referenced from Elixir "
            "exist on disk."
        )

sys.exit(1 if failed else 0)
PY
