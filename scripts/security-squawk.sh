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
#   scripts/security-squawk.sh                      # diff against origin/main
#   scripts/security-squawk.sh origin/HEAD          # diff against specific base
#   E2E_SQUAWK_ALL=1 scripts/security-squawk.sh     # lint every migration
#   SQUAWK_TARGET_DIR=/path scripts/security-squawk.sh   # lint every .exs in
#                                                   # a custom dir (test use)
#
# Exit codes:
#   0 — no violations found (or no changed migrations to lint)
#   1 — squawk reported a violation, or squawk is not installed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MIGRATIONS_DIR="$REPO_ROOT/apps/core/priv/repo/migrations"
# SQUAWK_TARGET_DIR: when set, overrides the default migrations directory AND
# skips the git-diff filter — every .exs file in the target dir is linted.
# Used by test harnesses to point the script at fixture directories.
TARGET_DIR="${SQUAWK_TARGET_DIR:-$DEFAULT_MIGRATIONS_DIR}"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed (npm install -g squawk-cli)"
    exit 0
fi

# ── Determine which migration files to lint ───────────────────────────────────
# Use `while read` instead of `mapfile` for bash 3.2 compatibility (macOS default).
MIGRATION_FILES=()
if [[ -n "${SQUAWK_TARGET_DIR:-}" ]]; then
    # Test-mode override: lint every .exs file in the target dir, no diff.
    while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(find "$TARGET_DIR" -name "*.exs" | sort)
elif [[ "${E2E_SQUAWK_ALL:-}" == "1" ]]; then
    # Explicit opt-in to lint every migration
    while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(find "$TARGET_DIR" -name "*.exs" | sort)
else
    BASE="${1:-origin/main}"

    # Find migrations added or modified relative to the base ref.
    # Falls back to all migrations if the base ref doesn't exist (new repo).
    # `|| true` attaches to each command whose failure is non-fatal here:
    #   - `git diff` empty output is valid (no changed files);
    #   - `grep` returns exit 1 when no line matches, which is also valid.
    # Without per-command `|| true`, `set -euo pipefail` would kill the
    # script on the no-match case. The earlier version had `|| true` only
    # at the end of the pipeline; under pipefail that did not shield an
    # early grep failure.
    if git rev-parse --verify "$BASE" &>/dev/null; then
        while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(
            { git diff --name-only --diff-filter=AM "$BASE"...HEAD 2>/dev/null || true; } \
                | { grep "apps/core/priv/repo/migrations/.*\.exs$" || true; } \
                | while IFS= read -r f; do echo "$REPO_ROOT/$f"; done
        )
    else
        echo "WARNING: base ref '$BASE' not found — linting all migrations." >&2
        while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(find "$TARGET_DIR" -name "*.exs" | sort)
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
    # Extract squawk-analysable SQL from the migration. `extract-migration-sql.py`
    # is the shared source of truth (also used by the test wrapper) so both gates
    # stay in lockstep. It pulls raw SQL from execute(...) blocks AND synthesises
    # CREATE INDEX SQL from `create index/unique_index` DSL calls, closing the
    # DSL/raw-execute blind spot (#219). Interpolated (#{...}) and anonymous
    # PL/pgSQL (DO $$ ... $$) execute blocks are skipped by the helper.
    sql_block="$(python3 "$REPO_ROOT/scripts/extract-migration-sql.py" "$migration" 2>/dev/null || true)"

    # No raw SQL to lint — skip (Ecto schema DSL migrations are not squawkable).
    if [[ -z "$sql_block" ]]; then
        echo "  (no raw SQL in $migration — skipping)"
        continue
    fi

    # GNU mktemp supports --suffix, BSD (macOS) does not. Create then rename.
    tmpfile="$(mktemp)"
    mv "$tmpfile" "$tmpfile.sql"
    tmpfile="$tmpfile.sql"
    echo "$sql_block" > "$tmpfile"
    # Destructive rules enabled by default in squawk 2.x — we rely on the
    # defaults for:
    #   * ban-drop-column          (DROP COLUMN)
    #   * renaming-column          (RENAME COLUMN)
    #   * renaming-table           (RENAME TO)
    #   * adding-required-field    (ADD COLUMN ... NOT NULL, no default)
    #
    # --exclude rules that don't apply to our fragment-based extraction:
    # * require-timeout-settings — we extract individual statements; the real
    #   migration already runs inside Ecto's migration transaction.
    # * adding-field-with-default — false positive on PG 11+ (Neon is PG 15
    #   where non-volatile DEFAULTs are metadata-only, no table rewrite).
    if ! squawk \
            --assume-in-transaction \
            --exclude=require-timeout-settings,adding-field-with-default \
            "$tmpfile"; then
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
