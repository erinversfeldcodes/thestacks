#!/usr/bin/env bash
# An anonymously-reachable route must be metered, or say why it is not.
#
# The public blog archive shipped through a scope that carried `:optional_auth`
# but no rate limiter, while every sibling public scope had one. So did the
# catalogue and the listings — the heaviest anonymous reads on the platform.
# Nothing caught it: the routes worked, the tests passed, and rate limiting is
# disabled in the test environment anyway, so no test could have noticed.
#
# WHAT IT CHECKS  Every route in a scope whose pipeline reaches anonymous
# callers pipes through a `:rate_limit_*` pipeline, unless it is allowlisted
# here with a reason.
#
# A scope is treated as anonymously reachable unless it requires a real
# identity: `:authenticated`, `:admin`, `:partner_auth` and `:sse_auth` all
# establish a caller before the action runs, and each carries its own limits.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import sys

ROUTER = "apps/core/lib/core_web/router.ex"

# Anonymous and deliberately unmetered. Each entry must say WHY; a stale entry
# fails the gate, so an exemption cannot outlive the reason for it.
EXEMPT = {
    "GET /api/health": "liveness probe — the platform that polls it is the reason it exists",
    "GET /api/health/ready": "readiness probe, same reason",
    "GET /api/auth/confirm/:token": "single-use token; guessing is bounded by the token space, not by request count",
    "GET /api/auth/confirm-email-change/:token": "single-use token, as above",
    "GET /api/auth/revert-email-change/:token": "single-use token, as above",
    "PUT /api/upload/:image_id/data": "presigned single-use image PUT; the init call that mints the id is metered",
    "POST /api/internal/vision/associate": "internal callback, not routable from the internet",
    "POST /api/internal/smoke/circuit_breakers": "internal smoke hook, not routable from the internet",
}

# Pipelines that establish a caller before the action runs.
IDENTIFIED = (":authenticated", ":admin", ":partner_auth", ":sse_auth")

src = open(ROUTER, encoding="utf-8").read()

scope_re = re.compile(r'scope\s+"([^"]*)"')
route_re = re.compile(r'(get|post|put|patch|delete)\s+"([^"]*)"')

stack, unmetered = [], []
for line in src.split("\n"):
    st = line.strip()
    m = scope_re.match(st)
    if m and st.endswith("do"):
        stack.append({"path": m.group(1), "pipes": ""})
        continue
    if st.startswith("pipe_through") and stack:
        stack[-1]["pipes"] = st
        continue
    if st == "end" and stack:
        stack.pop()
        continue
    r = route_re.match(st)
    if r and stack:
        pipes = " ".join(s["pipes"] for s in stack)
        # The SPA catch-all serves static assets, not API actions.
        if ":spa" in pipes:
            continue
        if any(p in pipes for p in IDENTIFIED):
            continue
        if "rate_limit" in pipes:
            continue
        full = "".join(s["path"] for s in stack) + r.group(2)
        unmetered.append(f"{r.group(1).upper()} {full}")

problems = [r for r in unmetered if r not in EXEMPT]
stale = sorted(k for k in EXEMPT if k not in unmetered)

failed = False

if problems:
    failed = True
    print(
        f"FAIL: {len(problems)} anonymously-reachable route(s) with no rate limiter:",
        file=sys.stderr,
    )
    for r in problems:
        print(f"  {r}", file=sys.stderr)
    print(
        "\nAdd a :rate_limit_* pipeline to the scope, or add the route to EXEMPT with\n"
        "the reason it is safe unmetered. Note that rate limiting is disabled in the\n"
        "test environment, so no test will catch this for you.",
        file=sys.stderr,
    )

if stale:
    failed = True
    print(
        f"\nFAIL: {len(stale)} EXEMPT entr(y/ies) no longer match an unmetered route — "
        "the route is now metered, gone, or renamed. Remove them:",
        file=sys.stderr,
    )
    for k in stale:
        print(f"  {k}", file=sys.stderr)

if not failed:
    print(
        f"OK: every anonymously-reachable route is metered, or exempt with a reason "
        f"({len(EXEMPT)} exempt)."
    )

sys.exit(1 if failed else 0)
PY
