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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed" >&2
    exit 0
fi

# Extract SQL via the shared helper — identical extraction to security-squawk.sh
# (execute() SQL + create index/unique_index DSL translation), so this wrapper
# and the real gate can never disagree about what a migration means (#219).
sql_block="$(python3 "$HERE/extract-migration-sql.py" "$migration" 2>/dev/null || true)"

if [[ -z "$sql_block" ]]; then
    echo "no raw SQL in fixture — skipping"
    exit 0
fi

tmpfile="$(mktemp)"
mv "$tmpfile" "$tmpfile.sql"
tmpfile="$tmpfile.sql"
trap 'rm -f "$tmpfile"' EXIT
echo "$sql_block" > "$tmpfile"

# Match security-squawk.sh EXACTLY: destructive rules on by default; timeouts,
# the PG11+ default false positive, and the @disable_ddl_transaction false
# positive excluded. The two exclude lists had silently drifted apart —
# security-squawk.sh also excluded ban-concurrent-index-creation-in-transaction
# while this wrapper did not — which is precisely the "two gates can never
# disagree" property #219 claimed and this file's header asserts. Keep them
# byte-identical.
squawk \
    --assume-in-transaction \
    --exclude=require-timeout-settings,adding-field-with-default,ban-concurrent-index-creation-in-transaction \
    "$tmpfile"
