#!/usr/bin/env bash
# scripts/security-squawk-test-wrapper.sh
#
# Runs squawk against a single migration fixture file with the exact same
# rule configuration `security-squawk.sh` uses. Used by
# test/platform/squawk_destructive_test.sh to verify that each destructive
# fixture trips its corresponding rule (and the safe fixture does not).
#
# Usage: security-squawk-test-wrapper.sh <path-to-migration.exs>
#
# Exit codes:
#   0 — squawk accepted the fixture (no violations, or no raw SQL to lint)
#   1 — squawk rejected the fixture

set -uo pipefail

migration="${1:?usage: $0 <migration.exs>}"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed" >&2
    exit 0
fi

# Extract SQL from execute() blocks — same logic as security-squawk.sh.
sql_block="$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
blocks = []
blocks += [m.group(1) for m in re.finditer(r"execute\s*\(\s*\"\"\"(.*?)\"\"\"", src, re.DOTALL)]
blocks += [m.group(1) for m in re.finditer(r"execute\s*\(\s*\"([^\"]+)\"\s*\)", src)]
for b in blocks:
    if "#{" in b:
        continue
    if re.search(r"DO\s*\$\$", b, re.IGNORECASE):
        continue
    stmt = b.strip()
    if not stmt.endswith(";"):
        stmt += ";"
    print(stmt)
' "$migration" 2>/dev/null || true)"

if [[ -z "$sql_block" ]]; then
    echo "no raw SQL in fixture — skipping"
    exit 0
fi

tmpfile="$(mktemp)"
mv "$tmpfile" "$tmpfile.sql"
tmpfile="$tmpfile.sql"
trap 'rm -f "$tmpfile"' EXIT
echo "$sql_block" > "$tmpfile"

# Match security-squawk.sh: destructive rules on by default, timeouts and
# the PG11+ false-positive rule excluded.
squawk \
    --assume-in-transaction \
    --exclude=require-timeout-settings,adding-field-with-default \
    "$tmpfile"
