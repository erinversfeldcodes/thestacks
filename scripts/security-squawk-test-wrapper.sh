#!/usr/bin/env bash

set -uo pipefail

# Runs the gate's squawk invocation against ONE migration file.
#
#   $0 <migration.exs>              enforce exactly what the gate enforces
#   $0 --minimal-fixture <file.exs> additionally allow a missing timeout preamble
#
# `--minimal-fixture` exists for the destructive fixtures under
# test/fixtures/migrations: each is a single `ALTER TABLE` stripped of everything
# but the hazard it asserts, so requiring a timeout preamble would turn all of
# them red for a reason unrelated to what they test.
#
# It is a flag rather than the default because a caller that wants the gate's
# real policy — "would this migration pass?" — must not get a laxer answer
# without asking for it. Defaulting to lenient is how a test comes to assert the
# opposite of the gate it is named after.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/squawk-rules.sh
source "$HERE/lib/squawk-rules.sh"

EXCLUDED_RULES="$SQUAWK_EXCLUDED_RULES"
if [[ "${1:-}" == "--minimal-fixture" ]]; then
    EXCLUDED_RULES="require-timeout-settings,$SQUAWK_EXCLUDED_RULES"
    shift
fi

migration="${1:?usage: $0 [--minimal-fixture] <migration.exs>}"

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
    --exclude="$EXCLUDED_RULES" \
    "$tmpfile"
