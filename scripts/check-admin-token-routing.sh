#!/usr/bin/env bash
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

definition = [i for i, l in enumerate(lines) if l.startswith(f"{RESOLVER} model")]
if not definition:
    print(f"FAIL: {RESOLVER}/1 is not defined in {path}.")
    print("The whole guarantee is that the admin token is read in exactly one named place.")
    sys.exit(1)
resolver_line = definition[0]

findings, sites = [], []

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

    m = re.match(r"adminToken\s*=\s*(.*)$", stripped)
    if m:
        value = m.group(1).strip() or (lines[i + 1].strip() if i + 1 < len(lines) else "")
        ok = value.startswith(RESOLVER)
        sites.append((i + 1, "adminToken binding", value, ok))
        if not ok:
            findings.append((i + 1, f"adminToken = {value}"))

    if "initPage " in stripped and not stripped.startswith("initPage :") and not stripped.startswith("initPage config route"):
        window = " ".join(l.strip() for l in lines[i : i + 6])
        ok = RESOLVER in window
        sites.append((i + 1, "initPage call", stripped[:80], ok))
        if not ok:
            findings.append((i + 1, f"{stripped[:60]} … (no {RESOLVER} within 6 lines)"))

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
