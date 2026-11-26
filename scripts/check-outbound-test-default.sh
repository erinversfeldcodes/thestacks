#!/usr/bin/env bash
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
    """Strip `#`-comments so prose about Finch is not read as a call to it.

    The `(?!\\{)` is load-bearing and was missing. `#[^\\n]*` treats `#{` as the
    start of a comment, so everything after an interpolation on the same line
    was erased -- and this gate FAILED OPEN as a result. A module whose only
    outbound call sits after an interpolation, for instance

        "#{base}/b/#{isbn}" |> then(&Finch.build(:get, &1)) |> Finch.request(name)

    had its `Finch.request(` eaten and dropped out of scope entirely: planted
    unseamed and with no test default, the gate printed `OK: all 11 outbound
    transports are seam-selected` and exited 0. Interpolation before a call is
    ordinary Elixir, so this was not an exotic shape.
    """
    return re.sub(r"#(?!\{)[^\n]*", "", text)

sources = {}
for path in sorted(glob.glob(LIB_GLOB, recursive=True)):
    sources[path] = read(path)

# Outbound calls this gate KNOWS how to reason about. `Finch.request` was the
# only shape when this was written, and the header claimed Finch was the app's
# only HTTP client — which was already false on disk: the object-storage module
# calls `Req.get`, and it never appeared in the roster at all. It happens to be
# seamed correctly, so the gate was silently right about a module it was not
# checking, which is the worst way to be right.
#
# `Finch.stream` is included for the same reason, though no caller exists today:
# a streaming client is an outbound call, and the roster should not have to be
# extended at the moment somebody adds one under deadline.
OUTBOUND = re.compile(
    r"\b(?:Finch\.(?:request|stream)!?|Req\.(?:get|post|put|patch|delete|request)!?)\("
)

# Anything that LOOKS like an HTTP call, whether this gate understands it or
# not. A module matching this but not OUTBOUND is a transport the gate cannot
# see, and it fails below rather than dropping quietly out of scope — which is
# how the next library gets in. Same property the stale-exemption check already
# gives the roster from the other direction.
HTTP_ISH = re.compile(
    r"\b(?:Finch\.|Req\.|HTTPoison\.|Tesla\.|:hackney\.|:httpc\.|Mint\.HTTP\.)\w+!?\("
)

# Calls that LOOK like HTTP to HTTP_ISH and touch no socket. `Finch.build/3`
# allocates a request struct; `Req.new/1` and `Tesla.client/2` build a client.
# A module that only ever does these makes no outbound call.
#
# ⚠️ Why this is subtracted rather than left to trip the check: without it, a
# build-only module FAILED with "extend OUTBOUND to cover the call shape", whose
# remedy would have put a non-transport on the roster and demanded it prove a
# seam it does not need. That is the cry-wolf failure this file's own comment
# names sixty lines below — and a gate that cries wolf gets edited until it is
# quiet.
#
# ⚠️ And why the ORDER of the two fixes mattered: before `blank_comments` stopped
# eating `#{}` interpolation, subtracting these would have turned
# `Finch.build(:get, "#{u}/x") |> Finch.request(name)` from a loud failure into
# an invisible one — the interpolation ate the `Finch.request(`, and only the
# surviving `Finch.build(` was tripping HTTP_ISH. The accidental catch was the
# only thing covering that shape. Removing it before fixing the cause would have
# opened a hole while closing a nuisance.
NON_EXECUTING = re.compile(r"\b(?:Finch\.build|Req\.new|Tesla\.client)!?\(")

def http_ish_beyond_building(code):
    """Does this module make an HTTP-ish call that is not merely building one?"""
    return any(
        not NON_EXECUTING.match(match.group(0))
        for match in HTTP_ISH.finditer(code)
    )

transports = {}   # module name -> defining path
unrecognised = []  # (module, path) making an HTTP call this gate cannot parse
for path, text in sources.items():
    code = blank_comments(text)
    match = re.search(r"^defmodule\s+([A-Za-z0-9_.]+)\s+do", code, re.M)
    if not match:
        continue
    module = match.group(1)

    if OUTBOUND.search(code):
        transports[module] = path
    elif http_ish_beyond_building(code):
        unrecognised.append((module, path))

if not transports:
    print("FAIL: found no module making an outbound HTTP call under apps/core/lib.")
    print("That cannot be right, so the scan has drifted from the source rather than the")
    print("app having stopped making HTTP requests. Fix this script before trusting it.")
    sys.exit(1)

if unrecognised:
    print("FAIL: these modules make an outbound HTTP call this gate does not recognise:")
    for module, path in sorted(unrecognised):
        print(f"  {module}  ({path})")
    print("")
    print("A transport the gate cannot see is a transport with no asserted test floor —")
    print("it drops out of scope silently, which is how the previous one got in. Extend")
    print("OUTBOUND to cover the call shape, then this module joins the roster and has")
    print("to prove its seam like every other.")
    sys.exit(1)

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
        if module in transports:
            seams.setdefault(module, set()).add(key)

# A seam does not have to live in the module that makes the call. The
# object-storage client is selected by a FACADE — `Application.get_env(:core,
# :storage, Stacks.Storage.Local)` in the parent module — so the harvest above
# attributes that key to the DEFAULT it names and never to the production
# implementation, which is the module that actually calls out.
#
# So also attribute a key to every module CONFIG ASSIGNS to it. That module can
# be selected for that key, which is exactly what being behind a seam means. The
# `:test` default check below is unchanged and still has to pass, so this widens
# who is recognised as seamed without weakening what seamed requires.
#
# Without this, bringing the storage client into the roster reported it as
# unseamed when it is seamed — and a gate that cries wolf gets edited until it
# is quiet, which is worse than the gap it was closing.
CONFIG_GLOBS = ["apps/core/config/*.exs", "config/*.exs"]
CONFIG_ASSIGN = re.compile(
    r"^\s*config\s+:core,\s*:([a-z0-9_]+),\s*([A-Za-z0-9_.]+)\s*$", re.M
)
for pattern in CONFIG_GLOBS:
    for path in sorted(glob.glob(pattern)):
        for key, module in CONFIG_ASSIGN.findall(read(path)):
            if module in transports:
                seams.setdefault(module, set()).add(key)

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
                "client — the exact mechanics of the live-client leak this gate exists for.",
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
    print("public internet through. This class has produced seven separate live-client")
    print("leaks in this codebase so far;")
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
