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
