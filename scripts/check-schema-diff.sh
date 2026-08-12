#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <before.sql> <after.sql>" >&2
    exit 2
fi

before="$1"
after="$2"

if [[ ! -f "$before" ]]; then
    echo "check-schema-diff: BEFORE file not found: $before" >&2
    exit 2
fi
if [[ ! -f "$after" ]]; then
    echo "check-schema-diff: AFTER file not found: $after" >&2
    exit 2
fi

set +e
python3 - "$before" "$after" <<'PY'
import re
import sys

before_path, after_path = sys.argv[1], sys.argv[2]

def parse_tables(txt):
    """
    Return {table_name: [column_name, ...]} for every CREATE TABLE statement.
    Only column names are tracked — the gate cares about shape loss, not
    type changes.
    """
    tables = {}
    for m in re.finditer(
        r'CREATE\s+TABLE\s+([A-Za-z0-9_."]+)\s*\(\s*(.*?)\s*\);',
        txt,
        re.DOTALL | re.IGNORECASE,
    ):
        name = m.group(1).strip()
        body = m.group(2)
        cols = []
        for line in body.splitlines():
            line = line.strip().rstrip(',')
            if not line:
                continue
            if re.match(
                r'^(CONSTRAINT|PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK|EXCLUDE)\b',
                line,
                re.IGNORECASE,
            ):
                continue
            tok = line.split()[0].strip('"')
            cols.append(tok)
        tables[name] = cols
    return tables

def parse_enums(txt):
    """
    Return {type_name: [enum_value, ...]} for every CREATE TYPE AS ENUM.
    Values are single-quoted; we strip the quotes so the set difference works
    cleanly.
    """
    enums = {}
    for m in re.finditer(
        r"CREATE\s+TYPE\s+([A-Za-z0-9_.\"]+)\s+AS\s+ENUM\s*\(\s*(.*?)\s*\);",
        txt,
        re.DOTALL | re.IGNORECASE,
    ):
        name = m.group(1).strip()
        body = m.group(2)
        vals = [v.group(1) for v in re.finditer(r"'([^']*)'", body)]
        enums[name] = vals
    return enums

with open(before_path) as f:
    before_txt = f.read()
with open(after_path) as f:
    after_txt = f.read()

before_tables = parse_tables(before_txt)
after_tables = parse_tables(after_txt)
before_enums = parse_enums(before_txt)
after_enums = parse_enums(after_txt)

destructive = []

for t in before_tables:
    if t not in after_tables:
        destructive.append(f"dropped table {t}")

for t, before_cols in before_tables.items():
    if t not in after_tables:
        continue
    before_set = set(before_cols)
    after_set = set(after_tables.get(t, []))
    dropped = before_set - after_set
    added = after_set - before_set
    for col in sorted(dropped):
        if added:
            destructive.append(
                f"column {t}.{col} gone (candidate rename -> {sorted(added)[0]})"
            )
        else:
            destructive.append(f"dropped column {t}.{col}")

for e in before_enums:
    if e not in after_enums:
        destructive.append(f"dropped type {e}")

for e, before_vals in before_enums.items():
    if e not in after_enums:
        continue
    lost = set(before_vals) - set(after_enums.get(e, []))
    for v in sorted(lost):
        destructive.append(f"enum {e} lost value '{v}'")

for m in re.finditer(
    r"ALTER\s+TYPE\s+([A-Za-z0-9_.\"]+)\s+DROP\s+VALUE\s+'([^']+)'",
    after_txt,
    re.IGNORECASE,
):
    destructive.append(f"ALTER TYPE {m.group(1)} DROP VALUE '{m.group(2)}'")

for m in re.finditer(
    r"^\s*DROP\s+TYPE\s+([A-Za-z0-9_.\"]+)",
    after_txt,
    re.IGNORECASE | re.MULTILINE,
):
    destructive.append(f"DROP TYPE {m.group(1)}")

seen = set()
unique = []
for d in destructive:
    if d not in seen:
        seen.add(d)
        unique.append(d)

if not unique:
    sys.exit(0)

for d in unique:
    print(f"check-schema-diff: destructive change: {d}")

sys.exit(1)
PY
diff_rc=$?
set -e

if [[ "${DB_BREAKING_LABEL:-}" == "true" ]]; then
    if [[ $diff_rc -ne 0 ]]; then
        echo "check-schema-diff: destructive diff allowed — db-breaking label is set."
    fi
    exit 0
fi

if [[ $diff_rc -eq 0 ]]; then
    echo "check-schema-diff: diff is additive-only."
    exit 0
fi

echo ""
echo "ERROR: destructive schema change detected without \`db-breaking\` label." >&2
echo "Add the \`db-breaking\` label to the PR if this is an intentional contract-phase migration." >&2
exit 1
