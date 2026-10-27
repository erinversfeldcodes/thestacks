#!/usr/bin/env bash
# The CSRF counter's declared scope must match the router's actual population.
#
# ⛔ WHY THIS EXISTS. The counter's own documentation says it covers "83 of 91
# state-changing routes", and the decision to turn enforcement on is a reading
# of that counter. **A scope figure is the denominator of that reading**, and a
# denominator in prose beside a router that changes is the rot this repository
# keeps recording: a route added tomorrow makes the claim false, nothing fails,
# and a zero on `absent_header` goes on being read as "every write is proven".
#
# ⚖️ So the numbers are derived from `router.ex` and compared to the numbers the
# module declares. A new state-changing route moves the total and this gate says
# so; a new EXEMPT one has to be exempted on purpose.
#
# ⚠️ WHAT IT DOES NOT CHECK: whether each route is correctly classified as
# browser-driven or server-to-server. That is a judgement about the caller, and
# the gate deliberately makes no attempt at it — it checks that the COUNTS are
# what the counter claims, so a change to the population cannot pass unnoticed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

ROUTER="apps/core/lib/core_web/router.ex"
COUNTER="apps/core/lib/stacks_web/plugs/csrf_counter.ex"
METRICS="apps/core/lib/core/prom_ex/plugins/stacks.ex"

for f in "$ROUTER" "$COUNTER" "$METRICS"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: $f not found, so this gate cannot look." >&2
        exit 1
    fi
done

# ⛔ DECLARED, not derived from the file it checks. These are the figures the
# counter's documentation and the metric's description state, and the whole
# point is to compare them against the router — so reading them out of the
# counter would make the gate agree with itself.
EXPECTED_STATE_CHANGING=91
EXPECTED_PARTNER=4
EXPECTED_TEST_HELPERS=4
EXPECTED_IN_SCOPE=83

python3 - "$ROUTER" "$COUNTER" "$METRICS" \
    "$EXPECTED_STATE_CHANGING" "$EXPECTED_PARTNER" "$EXPECTED_TEST_HELPERS" "$EXPECTED_IN_SCOPE" <<'PY'
import re
import sys

router_path, counter_path, metrics_path = sys.argv[1:4]
expected_total, expected_partner, expected_helpers, expected_scope = map(int, sys.argv[4:8])

router = open(router_path, encoding="utf-8").read()
UNSAFE = ("post", "put", "patch", "delete")

scope_stack, pipes_stack, routes = [], [], []
for raw in router.split("\n"):
    line, indent = raw.strip(), len(raw) - len(raw.lstrip())
    m = re.match(r'scope\s+"([^"]*)"', line)
    if m:
        scope_stack = [s for s in scope_stack if s[0] < indent] + [(indent, m.group(1))]
        pipes_stack = [p for p in pipes_stack if p[0] < indent]
        continue
    m = re.match(r"pipe_through\s+\[?([^\]]*)\]?", line)
    if m:
        pipes_stack = [p for p in pipes_stack if p[0] < indent] + [
            (indent, re.findall(r":([a-z_]+)", m.group(1)))
        ]
        continue
    m = re.match(r"(" + "|".join(UNSAFE) + r')\s+"([^"]*)"', line)
    if m:
        routes.append(
            (
                m.group(1).upper(),
                "".join(s for _, s in scope_stack if s) + m.group(2),
                tuple(sorted({p for _, ps in pipes_stack for p in ps})),
            )
        )

# ⚠️ Keyed on the PIPELINE, not the path. Deriving the partner exemption from
# `/partner` in the route path gave 7 and wrongly exempted three browser-driven
# routes — a public registration form and the two admin approve/reject clicks,
# which are exactly the cross-site targets CSRF exists for. An exemption must
# name the property that makes it safe (an Argon2 key and no cookie), not a
# string that correlates with it today.
partner = [r for r in routes if "partner_auth" in r[2]]
helpers = [r for r in routes if "rate_limit_e2e_helper" in r[2] or "/api/test/" in r[1]]
exempt_paths = {r[1] for r in partner} | {r[1] for r in helpers}
in_scope = [r for r in routes if r[1] not in exempt_paths]

# ⛔ A floor on what was READ. A router walk that stopped matching would report
# zero of everything and the equality checks below would all fail — which is
# loud, but for the wrong reason. This names the cause instead.
if len(routes) < 50:
    print(
        f"FAIL: parsed only {len(routes)} state-changing route(s) from {router_path}.",
        file=sys.stderr,
    )
    print(
        "      A verdict over a corpus this small is the walk having drifted from the\n"
        "      router, not the router having shrunk. Fix the parse before trusting any\n"
        "      count below.",
        file=sys.stderr,
    )
    raise SystemExit(1)

problems = []
for label, got, want in [
    ("state-changing routes", len(routes), expected_total),
    ("partner_auth routes", len(partner), expected_partner),
    ("/api/test/* helpers", len(helpers), expected_helpers),
    ("routes in the counter's scope", len(in_scope), expected_scope),
]:
    if got != want:
        problems.append((label, got, want))

# ⚠️ The arithmetic has to hold too, or the four numbers could each be updated
# to match a wrong total.
if len(routes) - len(exempt_paths) != len(in_scope):
    problems.append(("total minus exempt", len(routes) - len(exempt_paths), len(in_scope)))

# ⚠️ And the figure must actually appear where the counter claims it. A gate
# that checked only the router would pass while the documentation said 70.
for path in (counter_path, metrics_path):
    text = open(path, encoding="utf-8").read()
    if f"{expected_scope} of {expected_total}" not in text:
        problems.append((f"the phrase '{expected_scope} of {expected_total}' in {path}", 0, 1))

if problems:
    print("FAIL: the CSRF counter's declared scope does not match the router:", file=sys.stderr)
    for label, got, want in problems:
        print(f"  {label}: found {got}, declared {want}", file=sys.stderr)
    print(
        "\n⛔ This figure is the DENOMINATOR of the decision to turn enforcement on. A\n"
        "zero on `absent_header` over a population nobody has stated is the shape this\n"
        "project has twice mistaken for coverage.\n"
        "\n"
        "If a state-changing route was added: it is in scope, so raise the total and the\n"
        "in-scope count together. If it is genuinely server-to-server, exempt it by\n"
        "PIPELINE and say why — never by path.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(routes)} state-changing route(s) in {router_path}; "
    f"{len(partner)} partner_auth and {len(helpers)} test helpers exempt; "
    f"{len(in_scope)} in the counter's scope, which is what it declares."
)
PY
