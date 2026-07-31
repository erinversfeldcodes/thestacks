#!/usr/bin/env bash
# scripts/security-squawk.sh — lint changed migration files with squawk.
#
# Squawk detects PostgreSQL migration hazards: missing CONCURRENTLY, unsafe
# lock acquisition patterns, missing NOT VALID on new constraints, etc.
#
# Git-diff-aware: only the migration files added or modified since the merge
# base with origin/main are linted, so you never get noise from historical
# migrations that predate this gate. The selection spans BOTH the committed
# diff and the working tree (staged, unstaged and untracked) — an uncommitted
# migration is precisely the one most worth checking, and before #337 it was
# the one file this gate could not see.
#
# Usage:
#   scripts/security-squawk.sh                      # diff against origin/main
#   scripts/security-squawk.sh origin/HEAD          # diff against specific base
#   SQUAWK_BASE=origin/HEAD scripts/security-squawk.sh   # same, for callers that
#                                                   # don't forward argv (ci.sh)
#   E2E_SQUAWK_ALL=1 scripts/security-squawk.sh     # lint every migration
#   SQUAWK_TARGET_DIR=/path scripts/security-squawk.sh   # lint every .exs in
#                                                   # a custom dir (test use)
#
# Exit codes:
#   0 — migrations WERE inspected and squawk found no violations
#   1 — squawk reported a violation
#   2 — nothing was inspected (no changed migrations / no analysable SQL /
#       squawk not installed). This is a SKIP, deliberately distinct from 0.
#       Reporting a gate that read zero files as PASS is the #337 defect;
#       callers (scripts/ci.sh, .github/workflows/ci.yml) render 2 as SKIP.

set -euo pipefail

# Exit status for "this gate had nothing to say". Named so the intent survives
# the next person who wonders why a green run exits non-zero.
EXIT_NOTHING_INSPECTED=2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MIGRATIONS_DIR="$REPO_ROOT/apps/core/priv/repo/migrations"
# SQUAWK_TARGET_DIR: when set, overrides the default migrations directory AND
# skips the git-diff filter — every .exs file in the target dir is linted.
# Used by test harnesses to point the script at fixture directories. Resolved
# against the CALLER's cwd, before the cd below moves us.
TARGET_DIR="${SQUAWK_TARGET_DIR:-$DEFAULT_MIGRATIONS_DIR}"
if [[ -d "$TARGET_DIR" ]]; then
    TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
fi
# The selection below runs `git diff`/`git ls-files`; anchor them to the repo so
# the answer does not depend on the caller's working directory.
cd "$REPO_ROOT"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed (npm install -g squawk-cli) — 0 migrations inspected."
    exit "$EXIT_NOTHING_INSPECTED"
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
    # argv wins; SQUAWK_BASE is the env-var door for callers that invoke this
    # script with no arguments (scripts/ci.sh, the `just squawk` recipe).
    BASE="${1:-${SQUAWK_BASE:-origin/main}}"

    # Find migrations added or modified relative to the base ref, UNIONED with
    # everything the working tree has that the committed history does not yet:
    #
    #   1. `"$BASE"...HEAD`  — committed on this branch. Three-dot, so it is the
    #                          merge-base diff and does not re-lint main's work.
    #   2. `HEAD` (two-dot)  — staged AND unstaged changes to tracked files.
    #   3. `ls-files --others` — untracked files git has never seen. A freshly
    #                          generated migration lives here until `git add`,
    #                          and this is the case #337 was filed for.
    #
    # (2) and (3) are what make the gate useful in the order people actually
    # work: write the migration, run the gate, then commit. Note the deliberate
    # asymmetry — the working-tree legs are NOT diffed against the base, so a
    # historical migration only enters the set if you actually touched it. That
    # keeps the historical-noise suppression the diff was added for.
    #
    # If the base ref is missing (shallow clone, no remote) we drop leg 1 and
    # keep legs 2 and 3, saying so. The previous fallback linted ALL migrations,
    # which surfaced 35 pre-existing violations (#339) — a wall of red about
    # code that shipped months ago, and the fastest way to teach everyone that
    # this gate is noise. `E2E_SQUAWK_ALL=1` remains the deliberate door to
    # lint history; it should not be walked through by accident.
    if git rev-parse --verify "$BASE" &>/dev/null; then
        BASE_AVAILABLE=1
    else
        BASE_AVAILABLE=0
        echo "WARNING: base ref '$BASE' not found — the committed-diff leg is unavailable." >&2
        echo "         Only working-tree (staged/unstaged/untracked) migrations are linted." >&2
    fi

    # `|| true` attaches to each command whose failure is non-fatal here:
    #   - `git diff` empty output is valid (no changed files);
    #   - `git ls-files` likewise;
    #   - `grep` returns exit 1 when no line matches, which is also valid.
    # Without per-command `|| true`, `set -euo pipefail` would kill the
    # script on the no-match case. The earlier version had `|| true` only
    # at the end of the pipeline; under pipefail that did not shield an
    # early grep failure. Keep every `|| true` where it is.
    _squawk_candidate_paths() {
        if [[ "$BASE_AVAILABLE" == "1" ]]; then
            { git diff --name-only --diff-filter=AM "$BASE"...HEAD 2>/dev/null || true; }
        fi
        { git diff --name-only --diff-filter=AM HEAD 2>/dev/null || true; }
        { git ls-files --others --exclude-standard 2>/dev/null || true; }
    }

    while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(
        _squawk_candidate_paths \
            | { grep "apps/core/priv/repo/migrations/.*\.exs$" || true; } \
            | sort -u \
            | while IFS= read -r f; do
                  # A path can be listed by the committed diff and then deleted
                  # in the working tree. Only lint what is actually on disk.
                  if [[ -f "$REPO_ROOT/$f" ]]; then echo "$REPO_ROOT/$f"; fi
              done
    )
fi

if [[ ${#MIGRATION_FILES[@]} -eq 0 ]]; then
    echo "SKIP: no added or modified migration files (committed diff or working tree)."
    echo "      squawk inspected 0 files. This is a SKIP, not a pass — nothing was checked."
    exit "$EXIT_NOTHING_INSPECTED"
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
# Files actually handed to squawk. Distinct from ${#MIGRATION_FILES[@]}: a
# migration written entirely in the non-index Ecto DSL yields no analysable SQL,
# and counting those as "checked" is the same lie #337 is about, one level down.
ANALYSED=0

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
    # * ban-concurrent-index-creation-in-transaction — false positive: our
    #   CONCURRENTLY migrations set `@disable_ddl_transaction true` (an
    #   Ecto-level attribute invisible to squawk's raw-SQL fragment extraction),
    #   so the index is genuinely built outside a transaction. Proto-generated
    #   `references_table` migrations always emit CONCURRENTLY + this attribute.
    if ! squawk \
            --assume-in-transaction \
            --exclude=require-timeout-settings,adding-field-with-default,ban-concurrent-index-creation-in-transaction \
            "$tmpfile"; then
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
    ANALYSED=$((ANALYSED + 1))
    rm -f "$tmpfile"
done

if [[ $VIOLATIONS -gt 0 ]]; then
    echo ""
    echo "ERROR: squawk found $VIOLATIONS file(s) with migration safety violations." >&2
    exit 1
fi

echo ""
if [[ $ANALYSED -eq 0 ]]; then
    echo "SKIP: ${#MIGRATION_FILES[@]} changed migration file(s) selected, but none contained"
    echo "      squawk-analysable SQL (no execute(...) blocks, no index DSL)."
    echo "      squawk asserted nothing about them. This is a SKIP, not a pass."
    exit "$EXIT_NOTHING_INSPECTED"
fi

echo "squawk: clean — $ANALYSED of ${#MIGRATION_FILES[@]} changed migration file(s) carried"
echo "        analysable SQL and every statement passed."
