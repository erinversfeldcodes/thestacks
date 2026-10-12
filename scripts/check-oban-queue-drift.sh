#!/usr/bin/env bash
# The documented Oban queues must be the queues that exist.
#
# This gate exists because the architecture doc's queue table had drifted into
# fiction: it listed `vision` at concurrency 2 when the config says 20, and named
# five queues — price_scrape, review_scrape, author_scrape, source_discovery,
# geographic_discovery — that do not exist at all, while omitting `default` and
# `events`, which do. Nobody noticed because nothing compares them.
#
# That particular number matters more than most. Vision queue concurrency is what
# bounds how many images hit Modal at once, so it is the figure you reach for when
# reasoning about GPU pressure and cost — and reaching for the documented 2
# instead of the real 20 gets you an answer that is off by an order of magnitude.
#
# SOURCE OF TRUTH  apps/core/config/config.exs — the `queues:` keyword list.
# CHECKED AGAINST  the "Queue configuration" table in docs/technical-architecture.md.
# Drift in either direction fails: a queue in the config and not the table, a
# queue in the table and not the config, or a concurrency that disagrees.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import sys

CONFIG = "apps/core/config/config.exs"
DOC = "docs/technical-architecture.md"

config_src = open(CONFIG, encoding="utf-8").read()
m = re.search(r"queues:\s*\[([^\]]*)\]", config_src)
if not m:
    print(f"FAIL: no `queues:` list found in {CONFIG}", file=sys.stderr)
    sys.exit(1)

code = {
    name: int(conc)
    for name, conc in re.findall(r"(\w+):\s*(\d+)", m.group(1))
}

doc_src = open(DOC, encoding="utf-8").read()
section = re.search(
    r"\*\*Queue configuration:\*\*(.*?)(?=\n\*\*|\n### )", doc_src, re.S
)
if not section:
    print(f"FAIL: no '**Queue configuration:**' table found in {DOC}", file=sys.stderr)
    sys.exit(1)

doc = {
    name: int(conc)
    for name, conc in re.findall(r"^\|\s*`(\w+)`\s*\|\s*(\d+)\s*\|", section.group(1), re.M)
}

missing_from_doc = sorted(set(code) - set(doc))
missing_from_code = sorted(set(doc) - set(code))
mismatched = sorted(q for q in set(code) & set(doc) if code[q] != doc[q])

if missing_from_doc or missing_from_code or mismatched:
    print("FAIL: the documented Oban queues do not match the configured ones.", file=sys.stderr)
    for q in missing_from_doc:
        print(f"  configured but undocumented:  {q} (concurrency {code[q]})", file=sys.stderr)
    for q in missing_from_code:
        print(f"  documented but not configured: {q} (doc says {doc[q]})", file=sys.stderr)
    for q in mismatched:
        print(
            f"  concurrency disagrees:         {q} — config {code[q]}, doc {doc[q]}",
            file=sys.stderr,
        )
    print(
        f"\nThe config is the source of truth. Update the 'Queue configuration'\n"
        f"table in {DOC} to match, or change the config if the doc is what you meant.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"OK: {len(code)} Oban queue(s) documented exactly as configured.")
PY
