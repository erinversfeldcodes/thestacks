#!/usr/bin/env bash
# check-outbound-test-default.sh — every module that talks HTTP to the outside world must be
# behind a config seam, and every such seam must have a `:test` default (Issue #381e).
#
# WHY THIS EXISTS
#
# Twice, months apart, a "flaky test" turned out to be the suite dialling the public internet:
# #377 (DiscoverAuthorSourcesJob reaching authorsite.com through an un-seamed Finch call) and
# #379 (a third-space test geocoding against the live nominatim.openstreetmap.org because the
# `:geocoder` key had no `:test` default and a concurrent test's `delete_env` restore removed
# the one it had put there). Both were found by accident. #381's sweep then found five more
# un-seamed call sites. The class survives because nothing checks the edge: a new client module
# compiles, its tests mock it locally, and the first time anyone learns the seam has no floor
# is when a fuse probe or a lost put_env race dials a real host mid-suite.
#
# THE RULE, AND HOW THE ROSTER IS DERIVED
#
# Nothing here is a list of clients. The roster is recomputed on every run:
#
#   1. A module is an OUTBOUND TRANSPORT when its source contains `Finch.request(`.
#      (Finch is this app's only HTTP client; a new transport library would need adding here,
#      and the self-check below fails loudly if the scan ever finds nothing.)
#
#   2. Every transport module must be selected through a seam: an
#      `Application.get_env(:core, :key, <TheModule>)` (or `__MODULE__` inside the module
#      itself) somewhere under apps/core/lib. A transport nothing selects through a seam is
#      reachable only directly — which is exactly how #377 happened.
#
#   3. Every seam key from (2) must be set in apps/core/config/test.exs, to a module OTHER
#      than the real transport. This is the floor #379 lacked: with a compile-time `:test`
#      default, a runtime `delete_env` restores the MOCK, not the live client.
#
# A client module added tomorrow is checked the moment it calls Finch. Nobody edits a list.
#
# EXEMPTIONS
#
# `EXEMPT` maps a transport module to the reason it needs no seam. It can only shrink the
# checked set for modules that exist — a stale entry is itself a failure.
#
# Usage:
#   scripts/check-outbound-test-default.sh          # fail on an un-seamed or floor-less client
#   scripts/check-outbound-test-default.sh --list   # every transport, its seam key(s), verdict
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import glob
import re
import sys

mode = sys.argv[1]

LIB_GLOB = "apps/core/lib/**/*.ex"
TEST_CONFIG = "apps/core/config/test.exs"

# Transport module -> why it needs no seam. See EXEMPTIONS in the header.
EXEMPT = {
    "Core.PromEx.MetricsPusher": (
        "Unreachable in test by construction: init/1 returns :ignore unless "
        ":metrics_push_url is configured, and test config never sets it. The pusher is a "
        "supervised GenServer, not a client any code path selects — there is nothing to seam."
    ),
}


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def blank_comments(text):
    """Strip `#`-comments so prose about Finch is not read as a call to it."""
    return re.sub(r"#[^\n]*", "", text)


sources = {}
for path in sorted(glob.glob(LIB_GLOB, recursive=True)):
    sources[path] = read(path)

# ---- 1. which modules are outbound transports --------------------------------------

transports = {}  # module name -> defining path
for path, text in sources.items():
    code = blank_comments(text)
    if "Finch.request(" not in code:
        continue
    match = re.search(r"^defmodule\s+([A-Za-z0-9_.]+)\s+do", code, re.M)
    if match:
        transports[match.group(1)] = path

if not transports:
    print("FAIL: found no module calling Finch.request under apps/core/lib.")
    print("That cannot be right, so the scan has drifted from the source rather than the")
    print("app having stopped making HTTP requests. Fix this script before trusting it.")
    sys.exit(1)

# ---- 2. which seam keys select each transport --------------------------------------

# `Application.get_env(:core, :key, Some.Module)` anywhere; `__MODULE__` resolves to the
# module of the file it appears in.
SEAM = re.compile(
    r"Application\.get_env\(\s*:core,\s*:([a-z0-9_]+),\s*([A-Za-z0-9_.]+|__MODULE__)\s*\)"
)

seams = {}  # module -> set of keys
for path, text in sources.items():
    code = blank_comments(text)
    this_module = None
    match = re.search(r"^defmodule\s+([A-Za-z0-9_.]+)\s+do", code, re.M)
    if match:
        this_module = match.group(1)
    for key, default in SEAM.findall(code):
        module = this_module if default == "__MODULE__" else default
        # Elixir aliases mean the default may be written short (rare for these seams —
        # they are written fully qualified by convention); only fully-qualified names
        # (or __MODULE__) resolve here, and an unmatched transport fails below, so a
        # short alias cannot cause a silent pass.
        if module in transports:
            seams.setdefault(module, set()).add(key)

# ---- 3. every seam key must have a :test default that is not the real client -------

test_config = read(TEST_CONFIG)


def test_default(key):
    match = re.search(
        r"^config\s+:core,\s+:" + re.escape(key) + r",\s+([A-Za-z0-9_.]+)", test_config, re.M
    )
    return match.group(1) if match else None


findings, rows = [], []
for module, path in sorted(transports.items()):
    if module in EXEMPT:
        rows.append((module, path, "exempt", ""))
        continue

    keys = sorted(seams.get(module, ()))
    if not keys:
        rows.append((module, path, "UNSEAMED", ""))
        findings.append(
            (
                module,
                path,
                "calls Finch.request but nothing selects it through an "
                "`Application.get_env(:core, :key, ...)` seam. A test cannot swap what it "
                "cannot name — add a seam (see :rss_fetcher) or an exemption with a reason.",
            )
        )
        continue

    floorless = [k for k in keys if test_default(k) is None]
    mock_is_real = [k for k in keys if test_default(k) == module]
    if floorless:
        rows.append((module, path, "NO-TEST-DEFAULT", ",".join(keys)))
        findings.append(
            (
                module,
                path,
                "seam key(s) with no `:test` default in " + TEST_CONFIG + ": "
                + ", ".join(":" + k for k in floorless)
                + ". Without the compile-time floor, a runtime delete_env restores the LIVE "
                "client — the exact mechanics of #379.",
            )
        )
        continue
    if mock_is_real:
        rows.append((module, path, "MOCK-IS-REAL", ",".join(keys)))
        findings.append(
            (
                module,
                path,
                "the `:test` default for " + ", ".join(":" + k for k in mock_is_real)
                + " is the real transport itself — the floor points at the internet.",
            )
        )
        continue

    rows.append((module, path, "ok", ",".join(keys)))

stale = sorted(set(EXEMPT) - set(transports))

if mode == "--list":
    print("Outbound transport modules (Finch.request under apps/core/lib): " + str(len(rows)))
    print("")
    for module, path, verdict, keys in rows:
        print("  [" + verdict + "] " + module + "  (" + path + ")")
        if keys:
            print("      seam key(s): " + keys)
    print("")
    for module, reason in sorted(EXEMPT.items()):
        print("  exempt: " + module)
        print("      " + reason)
    sys.exit(0)

for module, reason in sorted(EXEMPT.items()):
    print("note: " + module + " is exempt — " + reason)

if stale:
    print("")
    print("FAIL: stale exemption(s) — these modules no longer call Finch.request, or no")
    print("longer exist. An exemption that protects nothing is a claim nobody is checking:")
    for module in stale:
        print("  - " + module)
    sys.exit(1)

if findings:
    print("")
    print("FAIL: " + str(len(findings)) + " outbound transport(s) the test suite can reach the")
    print("public internet through. This class produced #377, #379 and the five #381 sites;")
    print("each presented as a flaky test until someone chased it instead of re-running.")
    print("")
    for module, path, reason in findings:
        print("  " + module + "  (" + path + ")")
        print("      " + reason)
    sys.exit(1)

print(
    "OK: all "
    + str(len([r for r in rows if r[2] == "ok"]))
    + " outbound transports are seam-selected with a :test default ("
    + str(len(EXEMPT))
    + " exempt)."
)
PY
