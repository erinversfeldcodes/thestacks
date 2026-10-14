#!/usr/bin/env bash
set -uo pipefail

# ⚠️ The `|| echo .` below is why the vacuity guards further down are not
# hypothetical. With git absent or the tree not a repository, REPO_ROOT becomes
# `.`, the cd is a no-op, and every glob resolves against whatever directory the
# caller happened to be in — matching nothing. Ways in: a source tarball or a
# Docker build context that excludes `.git` (this repo's .dockerignore does), git
# missing from PATH in a minimal container or hook environment, or any future move
# of the Elm source root. The `2>/dev/null` swallows the only signal, so without
# those guards the gate reports a clean pass in every one of those cases.
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

# Anti-vacuity, both halves. Without this the gate reports "OK — 0 ports" and
# exits 0 when its globs match nothing — which is indistinguishable from a clean
# run and is exactly how a gate stops being a gate. The sibling transport check
# has had this guard since it was written; this one did not, and a platform
# review found it by deleting the frontend tree and watching the gate pass.
#
# Both directions matter: no Elm files means the port DECLARATIONS are missing,
# and no JS files means the SUBSCRIPTIONS are, and either way every comparison
# below becomes trivially satisfied.
if not seen_files:
    print("FAIL: found no Elm sources under frontend/src.")
    print("That cannot be right, so the scan has drifted from the source rather than")
    print("the app having stopped declaring ports. Fix this script before trusting it.")
    sys.exit(1)

# And the ROSTER, not just the files — a strictly stronger check than the one
# above, because it also catches the case where the files are found and nothing
# is harvested from them: a drifted `port` regex, a moved `port module`, an Elm
# syntax change. Files present with zero ports parsed would satisfy the check
# above and still compare two empty sets.
#
# Zero ports is always drift, never an achievement: this SPA is a port module
# and carries 21 of them.
if not ports:
    print("FAIL: found no `port` declarations under frontend/src.")
    print("The SPA is a `port module`, so zero ports means this scan stopped")
    print("matching the source, not that the app stopped using ports.")
    print("Fix this script before trusting it.")
    sys.exit(1)

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

if not seen_js:
    print("FAIL: found no JavaScript under apps/core/assets.")
    print("That cannot be right, so the scan has drifted from the source rather than")
    print("the app having stopped subscribing to ports. Fix this script before trusting it.")
    sys.exit(1)

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
