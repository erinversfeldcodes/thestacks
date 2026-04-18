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

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <migration.exs> [migration.exs ...]" >&2
    exit 0
fi

FAILED=0

for file in "$@"; do
    if [[ ! -f "$file" ]]; then
        echo "lint-migrations: $file does not exist" >&2
        FAILED=1
        continue
    fi

    # Use a single python pass so multi-line constructs (split `rename(...)`,
    # triple-quoted `modify` blocks) are handled deterministically.
    python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Extract the @breaking_ok reason if present. Accepts:
#   @breaking_ok "reason string"
#   @breaking_ok """
#   multi-line reason
#   """
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

# Detect destructive operations. Each tuple is (human label, pattern).
# Patterns use DOTALL so a split `rename(table, :old, to: :new)` across lines
# still matches. All patterns are intentionally conservative (word-boundary
# anchored) so they don't fire on prose in comments elsewhere.
ops = []

# `remove :col` or `remove(:col, ...)` inside an alter block
if re.search(r'(^|\s)remove[\s(]\s*:[a-z_][a-z0-9_]*', src):
    ops.append("remove (drop_column)")

# raw `drop_column` function
if re.search(r'\bdrop_column\b', src):
    ops.append("drop_column")

# `drop table(...)` / `drop_table(...)` / `drop_if_exists`
if re.search(r'\bdrop(_if_exists)?\b\s*[(\s]*table\b', src) or re.search(r'\bdrop_table\b', src):
    ops.append("drop_table")

# `rename(...)` or `rename table(...)`. Multi-line-friendly.
if re.search(r'(^|\s)rename\s*[(\s]', src, re.MULTILINE):
    ops.append("rename")

# `modify :col, type, null: false` — tighten column to NOT NULL.
# Multi-line friendly via [\s\S] to span the argument list.
if re.search(r'\bmodify\b[\s\S]{0,200}?null:\s*false', src):
    ops.append("modify ..., null: false")

# Strip comments before re-checking `remove` to avoid false positives where
# `# remove :col` appears in docs. We approximate by removing full-line
# comments; inline trailing comments are rare in Ecto migrations.
stripped = "\n".join(
    line for line in src.splitlines() if not line.lstrip().startswith("#")
)
# Re-verify with stripped src: if a rule originally matched but no longer
# matches without comments, drop it.
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
    # No destructive ops → file is clean regardless of annotation.
    sys.exit(0)

if reason is not None:
    # Annotated: echo the reason for reviewer visibility; pass.
    print(f"{path}: destructive ops ({', '.join(ops)}) permitted — @breaking_ok: {reason}")
    sys.exit(0)

# Destructive + no annotation → fail loudly.
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
