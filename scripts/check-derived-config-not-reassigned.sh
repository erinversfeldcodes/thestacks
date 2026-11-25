#!/usr/bin/env bash
# A config key DERIVED from a reader (an env var, a module call) and then
# REASSIGNED to a bare literal later in the same file is a silent clobber: the
# derivation is dead and the value a reader sees is not the one declared.
# runtime.exs once derived `upload_dir` (honouring UPLOAD_DIR) and then, inside
# the PHX_SERVER branch a server always takes, set it to a literal "/tmp/uploads"
# — so the declared value could never win. This catches that shape.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import re
import sys

CONFIGS = sorted(set(glob.glob("apps/core/config/*.exs") + glob.glob("config/*.exs")))

MIN_CONFIG_FILES = 2
if len(CONFIGS) < MIN_CONFIG_FILES:
    print(
        f"FAIL check-derived-config-not-reassigned: only {len(CONFIGS)} config file(s) "
        f"found; floor is {MIN_CONFIG_FILES}. A vacuous scan is a refusal.",
        file=sys.stderr,
    )
    sys.exit(1)

ASSIGN = re.compile(r"^\s*([a-z_]\w*):\s*(\S.*?),?\s*$")
DERIVED = re.compile(
    r"\bSystem\.get_env\b|\bApplication\.(?:get_env|fetch_env)\b|\b[A-Z]\w*(?:\.\w+)+\("
)
LITERAL = re.compile(r"""^(?:"[^"]*"|'[^']*'|~[A-Za-z]|[-+]?\d[\d_]*|true|false|nil|:\w+)""")

violations = []
for path in CONFIGS:
    occ = {}
    for i, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
        m = ASSIGN.match(line)
        if m:
            occ.setdefault(m.group(1), []).append((i, m.group(2)))
    for key, items in occ.items():
        if len(items) < 2:
            continue
        for a, (ln_a, val_a) in enumerate(items):
            if not DERIVED.search(val_a):
                continue
            for ln_b, val_b in items[a + 1 :]:
                if LITERAL.match(val_b.strip()):
                    violations.append((path, ln_a, key, ln_b, val_b.strip()[:40]))
                    break

if violations:
    print("FAIL check-derived-config-not-reassigned: a derived config key is reclobbered by a literal:", file=sys.stderr)
    for path, ln_a, key, ln_b, lit in violations:
        print(f"  {path}: `{key}` derived at line {ln_a}, then set to literal `{lit}` at line {ln_b}.", file=sys.stderr)
    sys.exit(1)

print(f"check-derived-config-not-reassigned: OK ({len(CONFIGS)} config file(s) scanned).")
PY
