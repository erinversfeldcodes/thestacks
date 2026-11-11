#!/usr/bin/env bash

set -euo pipefail

EXIT_NOTHING_INSPECTED=2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/squawk-rules.sh
source "$REPO_ROOT/scripts/lib/squawk-rules.sh"
DEFAULT_MIGRATIONS_DIR="$REPO_ROOT/apps/core/priv/repo/migrations"
TARGET_DIR="${SQUAWK_TARGET_DIR:-$DEFAULT_MIGRATIONS_DIR}"
if [[ -d "$TARGET_DIR" ]]; then
    TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
fi
cd "$REPO_ROOT"

if ! command -v squawk &>/dev/null; then
    echo "SKIP: squawk not installed (npm install -g squawk-cli) — 0 migrations inspected."
    exit "$EXIT_NOTHING_INSPECTED"
fi

MIGRATION_FILES=()
if [[ -n "${SQUAWK_TARGET_DIR:-}" ]]; then
    while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(find "$TARGET_DIR" -name "*.exs" | sort)
elif [[ "${E2E_SQUAWK_ALL:-}" == "1" ]]; then
    while IFS= read -r f; do MIGRATION_FILES+=("$f"); done < <(find "$TARGET_DIR" -name "*.exs" | sort)
else
    BASE="${1:-${SQUAWK_BASE:-origin/main}}"

    # Find migrations added or modified relative to the base ref, UNIONED with
    # everything the working tree has that the committed history does not yet:
    #
    #   1. `"$BASE"...HEAD`  — committed on this branch. Three-dot, so it is the
    #                          merge-base diff and does not re-lint main's work.
    #   2. `HEAD` (two-dot)  — staged AND unstaged changes to tracked files.
    #   3. `ls-files --others` — untracked files git has never seen. A freshly
    #                          generated migration lives here until `git add`,
    #                          and this is the case was filed for.
    #
    # (2) and (3) are what make the gate useful in the order people actually
    # work: write the migration, run the gate, then commit. Note the deliberate
    # asymmetry — the working-tree legs are NOT diffed against the base, so a
    # historical migration only enters the set if you actually touched it. That
    # keeps the historical-noise suppression the diff was added for.
    #
    # If the base ref is missing (shallow clone, no remote) we drop leg 1 and
    # keep legs 2 and 3, saying so. The previous fallback linted ALL migrations,
    # which surfaced 35 pre-existing violations — a wall of red about
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

VIOLATIONS=0
ANALYSED=0
PARTIAL=0

# A file can enter the changed set through a comment/doc-only edit. Its SQL is
# what squawk asserts about, so when the base ref holds the same file and the
# EXTRACTED SQL is byte-identical, the migration hazard surface did not change
# and re-linting it would only resurface historical noise the base-diff
# selection exists to suppress. Real SQL edits still lint in full.
_base_sql_unchanged() {
    local abs_path="$1" sql_now="$2"
    [[ "${BASE_AVAILABLE:-0}" == "1" ]] || return 1
    local rel="${abs_path#"$REPO_ROOT/"}"
    local base_src
    base_src="$(git -C "$REPO_ROOT" show "$BASE:$rel" 2>/dev/null)" || return 1
    local base_tmp base_sql
    base_tmp="$(mktemp).exs"
    printf '%s' "$base_src" > "$base_tmp"
    base_sql="$(python3 "$REPO_ROOT/scripts/extract-migration-sql.py" "$base_tmp" 2>/dev/null || true)"
    rm -f "$base_tmp"
    [[ -n "$base_sql" && "$base_sql" == "$sql_now" ]]
}

for migration in "${MIGRATION_FILES[@]}"; do
    sql_block="$(python3 "$REPO_ROOT/scripts/extract-migration-sql.py" "$migration" 2>/dev/null || true)"

    if [[ -z "$sql_block" ]]; then
        echo "  (no raw SQL in $migration — skipping)"
        continue
    fi

    # ⛔ PARTIAL EXTRACTION IS REPORTED, because it used to be indistinguishable
    # from full extraction and that is the more dangerous of the two.
    #
    # A migration yielding nothing prints the skip line above, and a reader can
    # see it was not analysed. A migration yielding SOME statements was analysed,
    # found clean, and counted toward ANALYSED — so the summary said a file had
    # been inspected when only part of its SQL had. Measured on this repository:
    # two migrations on this branch extracted nothing but their `SET LOCAL`
    # timeout declarations, which are the one thing that cannot itself be unsafe,
    # and squawk reported "Found 0 issues" for both.
    #
    # The extractor now declares what it dropped as a SQL comment. squawk ignores
    # comments, so nothing it analyses changes; this is purely about the claim
    # the summary gets to make.
    unanalysable="$(printf '%s\n' "$sql_block" | grep -- '-- UNANALYSABLE' || true)"
    if [[ -n "$unanalysable" ]]; then
        echo "  PARTIAL  $migration"
        echo "           ${unanalysable#-- UNANALYSABLE: }"
        PARTIAL=$((PARTIAL + 1))
    fi

    if _base_sql_unchanged "$migration" "$sql_block"; then
        echo "  (SQL identical to $BASE in $migration — comment/doc-only change, skipping)"
        continue
    fi

    tmpfile="$(mktemp)"
    mv "$tmpfile" "$tmpfile.sql"
    tmpfile="$tmpfile.sql"
    echo "$sql_block" > "$tmpfile"
    # Suppressions and their reasoning live in scripts/lib/squawk-rules.sh,
    # sourced above. Note what the timeout rule asks of a migration author:
    # `SET LOCAL lock_timeout`/`statement_timeout` in a transactional migration,
    # plain `SET` under `@disable_ddl_transaction` (there is no transaction for a
    # LOCAL setting to scope to). The values are per migration on purpose —
    # `CREATE INDEX CONCURRENTLY` and `VALIDATE CONSTRAINT` need
    # `statement_timeout = 0`, since a timeout firing mid-build leaves an INVALID
    # index, while a plain `ADD CONSTRAINT ... NOT VALID` wants a few seconds.
    # Both want a short lock_timeout.
    if ! squawk \
            --assume-in-transaction \
            --exclude="$SQUAWK_EXCLUDED_RULES" \
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

# ⚠️ The claim above is about FILES, and that is exactly how it overstated
# itself. "Every statement passed" is true of the statements squawk saw; it says
# nothing about statements the extractor could not hand it. Where some were
# dropped, say so here rather than letting the clean line stand alone — a reader
# deciding whether a migration was reviewed needs the difference.
if [[ $PARTIAL -gt 0 ]]; then
    echo ""
    echo "        ⚠️ $PARTIAL of those were only PARTIALLY extracted (listed above)."
    echo "        For those files the clean result covers the statements squawk"
    echo "        received, not the migration. Interpolated SQL, DO \$\$ blocks and"
    echo "        execute() with a non-literal argument are not analysable today."
fi
