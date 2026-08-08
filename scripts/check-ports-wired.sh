#!/usr/bin/env bash
# check-ports-wired.sh — every Elm outbound port (a `Cmd`) must have a JavaScript
# subscriber, and every `app.ports.X` the JS touches must be a real declared port
# (Issue #366).
#
# WHY THIS EXISTS
#
# An Elm `port foo : ... -> Cmd msg` that nothing `app.ports.foo.subscribe`s in JS
# compiles, type-checks, and runs — the `Cmd` is simply dropped on the floor. No
# error, no warning, in Elm or in JS. The feature just silently does nothing.
#
# ⚠️ **This was not hypothetical.** `saveOnboardingCompleted` (an outbound `Cmd`)
# and `onOnboardingStatus` (an inbound `Sub`) were both declared in `Main.elm` and
# both UNWIRED in `app.js` (#395). The consequence was user-visible: finishing
# onboarding never persisted, so the overlay re-triggered on every reload. It
# survived because nothing connects the two sides — exactly the gap this gate
# closes. The mirror of that failure is a JS `app.ports.typo.send(...)` naming a
# port that no longer exists, which throws at runtime the first time it fires.
#
# THE RULE, AND HOW THE SETS ARE DERIVED
#
# Nothing here is a list of ports. Both sides are harvested on every run:
#
#   1. Elm ports from `frontend/src/**/*.elm` (the `port module`). Direction is the
#      signature tail: `-> Cmd msg` is OUTBOUND (Elm→JS, needs a `.subscribe`);
#      `-> Sub msg` is INBOUND (JS→Elm, fed by a `.send`).
#   2. JS references from `apps/core/assets/**/*.js`: `app.ports.<name>.subscribe`
#      and `app.ports.<name>.send`.
#
#   FAIL when: an OUTBOUND port has no `.subscribe` (a dropped Cmd — the #395 bug),
#   or the JS references a port name that is not declared in Elm (a typo / a port
#   removed out from under its JS).
#
#   REPORT (do not fail) an INBOUND port with no `.send`: a Sub nobody feeds is
#   inert but harmless, and is sometimes a deliberately-reserved hook. Printed so
#   it cannot go quiet, but it does not gate.
#
#   Fail closed: a port declaration the parser cannot read is a failure, not a skip.
#
# Usage:
#   scripts/check-ports-wired.sh          # fail on a dropped Cmd or an undeclared JS ref
#   scripts/check-ports-wired.sh --list   # every port and its wiring verdict
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1
MODE="${1:-check}"

python3 - "$MODE" <<'PY'
import glob
import re
import sys

mode = sys.argv[1]

ELM_GLOBS = ["frontend/src/**/*.elm", "frontend/src/*.elm"]
JS_GLOBS = ["apps/core/assets/**/*.js", "apps/core/assets/*.js"]

# ---- 1. harvest Elm ports + direction --------------------------------------
# A port declaration is a single line: `port name : <sig>`. OUTBOUND ends in
# `Cmd msg`, INBOUND ends in `Sub msg`. Anything else is unparseable → fail closed.
ports = {}          # name -> "out" | "in"
unparseable = []
seen_files = set()
for pattern in ELM_GLOBS:
    for path in glob.glob(pattern, recursive=True):
        if path in seen_files:
            continue
        seen_files.add(path)
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                m = re.match(r"^port\s+([a-zA-Z0-9_]+)\s*:", line)
                if not m:
                    continue
                name = m.group(1)
                if re.search(r"->\s*Cmd\s+\w+\s*$", line.strip()):
                    ports[name] = "out"
                elif re.search(r"->\s*Sub\s+\w+\s*$", line.strip()):
                    ports[name] = "in"
                else:
                    unparseable.append((name, line.strip()))

# ---- 2. harvest JS wiring --------------------------------------------------
subscribes = set()   # app.ports.X.subscribe
sends = set()        # app.ports.X.send
js_refs = set()      # every app.ports.X referenced
seen_js = set()
for pattern in JS_GLOBS:
    for path in glob.glob(pattern, recursive=True):
        if path in seen_js or "node_modules" in path:
            continue
        seen_js.add(path)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for name in re.findall(r"app\.ports\.([A-Za-z0-9_]+)\.subscribe", text):
            subscribes.add(name); js_refs.add(name)
        for name in re.findall(r"app\.ports\.([A-Za-z0-9_]+)\.send", text):
            sends.add(name); js_refs.add(name)

# ---- 3. verdicts -----------------------------------------------------------
failures = []
warnings = []

for name, direction in sorted(ports.items()):
    if direction == "out" and name not in subscribes:
        failures.append(f"OUTBOUND port `{name}` (Cmd) has no `app.ports.{name}.subscribe` — "
                        f"its Cmd is dropped silently (the #395 shape).")
    if direction == "in" and name not in sends:
        warnings.append(f"INBOUND port `{name}` (Sub) is never fed by `app.ports.{name}.send` "
                        f"— inert; reserved hook or dead. Not gating.")

for name in sorted(js_refs):
    if name not in ports:
        failures.append(f"JS references `app.ports.{name}` but no Elm `port {name}` is declared "
                        f"— a typo or a port removed out from under its JS (throws at runtime).")

for name, line in unparseable:
    failures.append(f"port `{name}` has an unreadable signature (not `-> Cmd msg` / `-> Sub msg`): "
                    f"{line}")

# ---- output ----------------------------------------------------------------
if mode == "--list":
    print(f"Elm ports: {len(ports)}  |  JS subscribes: {len(subscribes)}  sends: {len(sends)}")
    for name, direction in sorted(ports.items()):
        wired = (name in subscribes) if direction == "out" else (name in sends)
        arrow = "Elm->JS" if direction == "out" else "JS->Elm"
        print(f"  [{ 'OK ' if wired else 'MISS' }] {name:<28} {arrow} ({'subscribe' if direction=='out' else 'send'})")

for w in warnings:
    print(f"note: {w}")

if failures:
    print(f"\ncheck-ports-wired: {len(failures)} failure(s):")
    for f in failures:
        print(f"  ✗ {f}")
    sys.exit(1)

print(f"\ncheck-ports-wired: OK — {len(ports)} ports, every Cmd subscribed and every JS ref declared.")
PY
