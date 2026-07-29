#!/usr/bin/env bash
# check-admin-token-routing.sh — every admin call site must use `adminTokenFor` (Issue #309).
#
# WHY THIS EXISTS
#
# `/api/admin/*` sits behind an MFA-verified admin session (`typ: "admin_session"`, IP- and
# boot_id-bound) and 401s anything else. Four admin surfaces were built, routed, unit-tested and
# **unreachable** because the SPA handed them the ordinary Guardian token (#303). Repointing
# `initPage` fixed the page load and left the `update` handlers on the old token — so the list loaded
# and every action 401'd. Two entry points; one fixed.
#
# ⚠️ **No Elm test can catch this, and that is measured rather than assumed.** Every page-level admin
# test receives the token as an *argument*, so it cannot notice that `Main` chose the wrong one. A
# mutation probe setting `adminToken = Nothing` at one update site reintroduced the defect verbatim
# and left **all 1285 Elm tests passing** (#309).
#
# A `ProgramTest` was considered and rejected: the existing simulated-effects tests hand-write their
# own copy of the request under test, so they assert against a mirror of the real code rather than the
# real code. #302 found exactly that shape passing vacuously. A source-level invariant cannot be
# fooled by a mirror.
#
# THE RULE
#
# In `frontend/src/Main.elm`, any binding named `adminToken`, and any `initPage` call, must take its
# value from `adminTokenFor` — never `model.adminAuth` directly, never `model.auth`, never a literal.
# Reading the field once, in one named place, is what makes the entry points incapable of disagreeing.
#
# Usage:
#   scripts/check-admin-token-routing.sh          # fail if any admin call site bypasses the resolver
#   scripts/check-admin-token-routing.sh --list    # show every admin call site and its source
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import re, sys

mode = sys.argv[1]
path = "frontend/src/Main.elm"
text = open(path, encoding="utf-8").read()
lines = text.split("\n")

RESOLVER = "adminTokenFor"

# The resolver itself is the one place allowed to read the field.
definition = [i for i, l in enumerate(lines) if l.startswith(f"{RESOLVER} model")]
if not definition:
    print(f"FAIL: {RESOLVER}/1 is not defined in {path}.")
    print("The whole guarantee is that the admin token is read in exactly one named place.")
    sys.exit(1)
resolver_line = definition[0]

findings, sites = [], []

# ⚠️ The resolver's BODY is checked, not only its call sites.
#
# Found by probing this very check: replacing the body with `Maybe.map .token model.auth` — i.e.
# handing the admin endpoints the ORDINARY session token, which is defect 1 of #303 verbatim — left
# this guard passing and all 1285 Elm tests passing. Naming the read in one place reduced five
# vulnerable sites to one; it did not protect the one.
body = lines[resolver_line + 1].strip() if resolver_line + 1 < len(lines) else ""
if body != "model.adminAuth":
    findings.append(
        (
            resolver_line + 2,
            f"{RESOLVER} returns `{body}`, not `model.adminAuth`. The admin endpoints require an "
            "MFA-verified admin session and 401 anything else — returning the ordinary session here "
            "is #303's original defect with a better name on it.",
        )
    )
sites.append((resolver_line + 2, "resolver body", body, body == "model.adminAuth"))

for i, line in enumerate(lines):
    stripped = line.strip()

    # An `adminToken = <expr>` binding. The value may be on the same line or the next.
    m = re.match(r"adminToken\s*=\s*(.*)$", stripped)
    if m:
        value = m.group(1).strip() or (lines[i + 1].strip() if i + 1 < len(lines) else "")
        ok = value.startswith(RESOLVER)
        sites.append((i + 1, "adminToken binding", value, ok))
        if not ok:
            findings.append((i + 1, f"adminToken = {value}"))

    # `initPage config route auth <adminToken> prev` — the 4th argument.
    #
    # Read across the following lines, because the call is routinely broken over five of them and a
    # single-line check reported a false bypass on the first one it met. A guard that cries wolf on a
    # correct call site is a guard someone switches off.
    if "initPage " in stripped and not stripped.startswith("initPage :") and not stripped.startswith("initPage config route"):
        window = " ".join(l.strip() for l in lines[i : i + 6])
        ok = RESOLVER in window
        sites.append((i + 1, "initPage call", stripped[:80], ok))
        if not ok:
            findings.append((i + 1, f"{stripped[:60]} … (no {RESOLVER} within 6 lines)"))

    # A direct field read anywhere outside the resolver is the bypass this exists to stop.
    if "model.adminAuth" in stripped and i != resolver_line + 1:
        sites.append((i + 1, "DIRECT FIELD READ", stripped[:80], False))
        findings.append((i + 1, f"reads model.adminAuth directly: {stripped[:70]}"))

if mode == "--list":
    print(f"{len(sites)} admin token call site(s) in {path}:\n")
    for lineno, kind, value, ok in sites:
        print(f"  {'ok ' if ok else '!! '} {path}:{lineno}  [{kind}]  {value}")
    sys.exit(0)

if findings:
    print("Admin call sites that bypass the token resolver:\n")
    for lineno, what in findings:
        print(f"  {path}:{lineno}")
        print(f"    {what}")
        print(f"    -> must be `{RESOLVER} model`. Two entry points disagreeing about which token")
        print("       to send is what made four admin surfaces unreachable (#303).\n")
    print(f"{len(findings)} bypass(es). No Elm test can catch this — see the header.")
    sys.exit(1)

print(f"All {len(sites)} admin token call site(s) use {RESOLVER} ({path}).")
sys.exit(0)
PY
