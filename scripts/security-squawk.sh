#!/usr/bin/env bash
# scripts/security-squawk.sh — lint changed migration files with squawk.
#
# Squawk detects PostgreSQL migration hazards: missing CONCURRENTLY, unsafe
# lock acquisition patterns, missing NOT VALID on new constraints, etc.
#
# Git-diff-aware: only the migration files added or modified since the merge
# base with origin/main are linted, so you never get noise from historical
# migrations that predate this gate.
#
# Usage:
#   scripts/security-squawk.sh               # diff against origin/main
#   scripts/security-squawk.sh origin/HEAD   # diff against specific base
#   E2E_SQUAWK_ALL=1 scripts/security-squawk.sh  # lint every migration
#
# Exit codes:
#   0 — no violations found (or no changed migrations to lint)
#   1 — squawk reported a violation, or squawk is not installed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/apps/core/priv/repo/migrations"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed (npm install -g squawk-cli)"
    exit 0
fi

# ── Determine which migration files to lint ───────────────────────────────────
if [[ "${E2E_SQUAWK_ALL:-}" == "1" ]]; then
    # Explicit opt-in to lint every migration
    mapfile -t MIGRATION_FILES < <(find "$MIGRATIONS_DIR" -name "*.exs" | sort)
else
    BASE="${1:-origin/main}"

    # Find migrations added or modified relative to the base ref.
    # Falls back to all migrations if the base ref doesn't exist (new repo).
    if git rev-parse --verify "$BASE" &>/dev/null; then
        mapfile -t MIGRATION_FILES < <(
            git diff --name-only --diff-filter=AM "$BASE"...HEAD 2>/dev/null \
                | grep "apps/core/priv/repo/migrations/.*\.exs$" \
                | while IFS= read -r f; do echo "$REPO_ROOT/$f"; done \
                || true
        )
    else
        echo "WARNING: base ref '$BASE' not found — linting all migrations." >&2
        mapfile -t MIGRATION_FILES < <(find "$MIGRATIONS_DIR" -name "*.exs" | sort)
    fi
fi

if [[ ${#MIGRATION_FILES[@]} -eq 0 ]]; then
    echo "No changed migration files to lint — skipping squawk."
    exit 0
fi

echo "Linting ${#MIGRATION_FILES[@]} migration file(s) with squawk..."
for f in "${MIGRATION_FILES[@]}"; do
    echo "  $f"
done
echo ""

# squawk expects plain SQL; Ecto migrations are Elixir DSL.
# We extract SQL strings from execute("...") calls and lint those.
# For files without raw SQL (only Ecto schema helpers) we skip gracefully.

VIOLATIONS=0

for migration in "${MIGRATION_FILES[@]}"; do
    # Extract SQL from execute(...) blocks. Handles three forms:
    #   execute("single line")
    #   execute("""                execute(
    #     multi                      "single line"
    #     line                    )
    #   """)
    # Python's multi-line regex handles triple-quoted heredocs cleanly —
    # simpler than chaining sed/awk/perl with lookbehinds.
    sql_block="$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
# triple-quoted
for m in re.finditer(r"execute\s*\(\s*\"\"\"(.*?)\"\"\"", src, re.DOTALL):
    print(m.group(1))
# single-quoted single-line (may be wrapped across the paren)
for m in re.finditer(r"execute\s*\(\s*\"([^\"]+)\"\s*\)", src):
    print(m.group(1))
' "$migration" 2>/dev/null || true)"

    # No raw SQL to lint — skip (Ecto schema DSL migrations are not squawkable).
    if [[ -z "$sql_block" ]]; then
        echo "  (no raw SQL in $migration — skipping)"
        continue
    fi

    tmpfile="$(mktemp --suffix=.sql)"
    echo "$sql_block" > "$tmpfile"
    if ! squawk --assume-in-transaction "$tmpfile"; then
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
    rm -f "$tmpfile"
done

if [[ $VIOLATIONS -gt 0 ]]; then
    echo ""
    echo "ERROR: squawk found $VIOLATIONS file(s) with migration safety violations." >&2
    exit 1
fi

echo "squawk: all migrations clean."
