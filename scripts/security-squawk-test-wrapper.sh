#!/usr/bin/env bash

set -uo pipefail

migration="${1:?usage: $0 <migration.exs>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed" >&2
    exit 0
fi

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

squawk \
    --assume-in-transaction \
    --exclude=require-timeout-settings,adding-field-with-default,ban-concurrent-index-creation-in-transaction \
    "$tmpfile"
