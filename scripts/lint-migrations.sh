#!/usr/bin/env bash
# scripts/lint-migrations.sh — enforce @breaking_ok annotation on destructive
# Ecto migrations.
#
# Scans each Elixir migration file passed on argv for destructive operations:
#   * `remove :col`        (alter table block)
#   * `drop_column`         (raw DSL)
#   * `drop_table`          / `drop table(`
#   * `rename ...`          (column/table rename — may be split across lines)
#   * `modify ..., null: false`  (tighten a nullable column to NOT NULL)
#
# If any destructive op is present, the file MUST declare a module attribute
#
#     @breaking_ok "<reason explaining why N-1 code no longer references the
#                    affected column / table>"
#
# …attesting that the expand phase has already shipped and removed all reads
# and writes to the doomed shape. Without that annotation, the script exits
# non-zero and prints the offending file + op. With the annotation, the
# reason is echoed to stdout for reviewer visibility, and the file passes.
#
# Trust model:
#   The `@breaking_ok` reason string is free text. Nothing in this script,
#   or anywhere else in the Phase 2 enforcement, mechanically verifies that
#   the claim ("N-1 code no longer references column X") is actually true.
#   A reviewer or operator must inspect the referenced commit(s) to confirm
#   the expand phase has really shipped. Think of `@breaking_ok` as a
#   conscious acknowledgement — a speed-bump forcing the author to name a
#   reason and the reviewer to cross-check it — not a safeguard. Plan step 4
#   (mechanical two-step reference check: destructive migration points to a
#   prior merged commit that removed the code reference) is deferred to a
#   follow-up issue.
#
# Usage:
#   scripts/lint-migrations.sh file1.exs file2.exs ...
#
# Exit codes:
#   0 — all files clean or annotated
#   1 — at least one destructive + unannotated file

set -euo pipefail

# Optional: --base <ref> skips files whose EXTRACTED SQL is identical to the
# base ref's — a comment/doc-only edit does not change the destructive surface,
# and re-flagging a long-shipped migration over a docstring tweak only teaches
# people to annotate history. Files with genuinely changed SQL still lint.
BASE=""
if [[ "${1:-}" == "--base" ]]; then
    BASE="$2"
    shift 2
fi

if [[ $# -eq 0 ]]; then
    echo "usage: $0 [--base <ref>] <migration.exs> [migration.exs ...]" >&2
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

_sql_unchanged_from_base() {
    local file="$1"
    [[ -n "$BASE" ]] || return 1
    git -C "$REPO_ROOT" rev-parse --verify "$BASE" &>/dev/null || return 1
    local rel base_src base_tmp sql_now base_sql
    rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")" "$REPO_ROOT")"
    base_src="$(git -C "$REPO_ROOT" show "$BASE:$rel" 2>/dev/null)" || return 1
    sql_now="$(python3 "$REPO_ROOT/scripts/extract-migration-sql.py" "$file" 2>/dev/null || true)"
    base_tmp="$(mktemp).exs"
    printf '%s' "$base_src" > "$base_tmp"
    base_sql="$(python3 "$REPO_ROOT/scripts/extract-migration-sql.py" "$base_tmp" 2>/dev/null || true)"
    rm -f "$base_tmp"
    [[ -n "$sql_now" && "$sql_now" == "$base_sql" ]]
}

FAILED=0

for file in "$@"; do
    if [[ ! -f "$file" ]]; then
        echo "lint-migrations: $file does not exist" >&2
        FAILED=1
        continue
    fi

    if _sql_unchanged_from_base "$file"; then
        echo "$file: SQL identical to $BASE — comment/doc-only change, skipping"
        continue
    fi

    python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

def _strip_def_down(text):
    m = re.search(r'^([ \t]*)def down(?:\([^)]*\))?\s+do\s*$', text, re.MULTILINE)
    if not m:
        return text
    indent = m.group(1)
    close_re = re.compile(r'^' + re.escape(indent) + r'end[ \t]*$', re.MULTILINE)
    close = close_re.search(text, m.end())
    if not close:
        return text
    return text[:m.start()] + text[close.end():]

src = _strip_def_down(src)

reason = None
m = re.search(
    r'@breaking_ok\s+"""\s*(.*?)\s*"""',
    src,
    re.DOTALL,
)
if m:
    reason = m.group(1).strip()
else:
    m = re.search(r'@breaking_ok\s+"([^"]+)"', src)
    if m:
        reason = m.group(1).strip()

ops = []

if re.search(r'(^|\s)remove[\s(]\s*:[a-z_][a-z0-9_]*', src):
    ops.append("remove (drop_column)")

if re.search(r'\bdrop_column\b', src):
    ops.append("drop_column")

if re.search(r'\bdrop(_if_exists)?\b\s*[(\s]*table\b', src) or re.search(r'\bdrop_table\b', src):
    ops.append("drop_table")

if re.search(r'(^|\s)rename\s*[(\s]', src, re.MULTILINE):
    ops.append("rename")

if re.search(r'\bmodify\b[\s\S]{0,200}?null:\s*false', src):
    ops.append("modify ..., null: false")

def _extract_execute_sql(text):
    blocks = []
    blocks += [m.group(1) for m in re.finditer(r'execute\s*\(\s*"""(.*?)"""', text, re.DOTALL)]
    blocks += [m.group(1) for m in re.finditer(r'execute\s*\(\s*"([^"]+)"', text)]
    return [b for b in blocks if "#{" not in b]

execute_sql = "\n".join(_extract_execute_sql(src))

if re.search(r'\bSET\s+NOT\s+NULL\b', execute_sql, re.IGNORECASE):
    ops.append("execute SET NOT NULL")

if re.search(r'\bDROP\s+COLUMN\b', execute_sql, re.IGNORECASE):
    ops.append("execute DROP COLUMN")

if re.search(r'\bRENAME\s+(?:COLUMN\b|[^\n;]*?\bTO\b)', execute_sql, re.IGNORECASE):
    ops.append("execute RENAME")

stripped = "\n".join(
    line for line in src.splitlines() if not line.lstrip().startswith("#")
)
def still_matches(label):
    if label == "remove (drop_column)":
        return bool(re.search(r'(^|\s)remove[\s(]\s*:[a-z_][a-z0-9_]*', stripped))
    if label == "drop_column":
        return bool(re.search(r'\bdrop_column\b', stripped))
    if label == "drop_table":
        return bool(re.search(r'\bdrop(_if_exists)?\b\s*[(\s]*table\b', stripped) or re.search(r'\bdrop_table\b', stripped))
    if label == "rename":
        return bool(re.search(r'(^|\s)rename\s*[(\s]', stripped, re.MULTILINE))
    if label == "modify ..., null: false":
        return bool(re.search(r'\bmodify\b[\s\S]{0,200}?null:\s*false', stripped))
    return True

ops = [o for o in ops if still_matches(o)]

if not ops:
    sys.exit(0)

if reason is not None:
    print(f"{path}: destructive ops ({', '.join(ops)}) permitted — @breaking_ok: {reason}")
    sys.exit(0)

print(
    f"{path}: destructive operation(s) detected: {', '.join(ops)}. "
    f"Add `@breaking_ok \"<reason>\"` module attribute to confirm the expand "
    f"phase has shipped and N-1 code no longer references the affected shape."
)
sys.exit(2)
PY
    rc=$?
    if [[ $rc -ne 0 ]]; then
        FAILED=1
    fi
done

if [[ $FAILED -ne 0 ]]; then
    exit 1
fi
exit 0
