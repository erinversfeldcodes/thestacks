#!/usr/bin/env bash
# Residual-findings sweep — the reading aid behind `just campaign-residue`.
# Prints (1) open/deferred residue-ledger rows, (2) not_started items in any
# campaign state file, (3) DoD-residue phrases in issue files that cite no
# follow-up number. Sections 2–3 are heuristics for a human/agent to judge,
# not a gate; the ledger (section 1) is the authoritative list.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1. Residue ledger: open / deferred / due rows =="
if [ -f plans/residue-ledger.md ]; then
  # ⛔ READ BY COLUMN, AND REFUSE A ROW THAT HAS NO COLUMNS.
  #
  # This section calls itself authoritative, and it used to establish that with
  # `grep -Ev '\| *closed *\|'` — a substring test over the whole line, which is
  # not the same question as "is this row's STATUS closed". Any cell holding the
  # bare word `closed` satisfies it, wherever that cell sits.
  #
  # Found by sweeping 300 rows: 14 were malformed. Eleven carried an unescaped
  # `|` inside a code snippet (`str | None`, `scope: :user | :system`), which
  # shifts every cell after it; one had a correction block pasted into the
  # source column; one was missing its source entirely; one had an extra column
  # AND no closing pipe. The two filters then disagreed on exactly one row — and
  # the honest account of that row matters more than the headline:
  #
  #   RL-247 had no source cell and a later edit INSERTED `closed` ahead of a
  #   stale `open` instead of replacing it. The substring filter dropped it; the
  #   positional read reported it open. Checked, the WORK WAS DONE — so the
  #   substring filter's verdict was accidentally right and the positional
  #   read's was wrong-but-faithful to what the row said. What the positional
  #   read actually bought was VISIBILITY: it made the shift show up, which is
  #   how the row got repaired. That is the refusal below doing the real work,
  #   not the filter.
  #
  # ⚠️ So the claim to keep is the narrow one. An instrument that trusts a
  # structure it never checks cannot tell a discharged row from a damaged one,
  # and a ledger row that renders as garbage is retained in name only —
  # retention being the loss channel this whole file exists to plug.
  python3 - <<'LEDGER' || exit 1
import re, sys

SPLIT = re.compile(r"(?<!\\)\|")
malformed, rows = [], []
for n, line in enumerate(open("plans/residue-ledger.md"), 1):
    if not re.match(r"^\| RL-\d+ ", line):
        continue
    cells = [c.strip() for c in SPLIT.split(line.rstrip("\n"))]
    # A well-formed row is '| a | b | c | d | e | f |' — six cells between a
    # leading and a trailing empty string.
    rid = cells[1] if len(cells) > 1 else "?"
    if len(cells) != 8:
        malformed.append((n, rid, f"has {len(cells) - 2} cell(s), want 6"))
        continue
    # ⚠️ Reported separately from the cell count, because here the count is
    # RIGHT and saying "has 6 cell(s), want 6" is worse than no message. This
    # branch catches a row that is wrong TWICE in cancelling directions — an
    # extra column and no closing `|` — which leaves exactly seven unescaped
    # pipes, the same as a well-formed row. A pipe count cannot see it, which
    # is how RL-261 survived the sweep that repaired thirteen other rows.
    if cells[0] or cells[-1]:
        edge = "leading" if cells[0] else "trailing"
        malformed.append((n, rid, f"has text outside the table: missing its {edge} `|`"))
        continue
    rows.append(cells[1:-1])

if malformed:
    print(f"!! REFUSING: {len(malformed)} malformed ledger row(s) — these have no", file=sys.stderr)
    print("   readable status, so this section cannot say whether they are open:", file=sys.stderr)
    for n, rid, why in malformed:
        print(f"     line {n}: {rid} {why}", file=sys.stderr)
    print("   Escape every `|` inside a cell as `\\|`, or restore the missing column.", file=sys.stderr)
    raise SystemExit(1)

if not rows:
    print("!! REFUSING: parsed 0 ledger rows. The file exists, so the row shape", file=sys.stderr)
    print("   stopped matching rather than the residue being discharged.", file=sys.stderr)
    raise SystemExit(1)

_id, _finding, _source, STATUS, _due, _disp = range(6)
open_rows = [r for r in rows if r[STATUS].lower() != "closed"]
if open_rows:
    for r in open_rows:
        print("| " + " | ".join(r) + " |")
else:
    print("(none open)")
print(f"\n-- {len(rows)} ledger row(s) parsed, {len(open_rows)} not closed", file=sys.stderr)
LEDGER
  echo
  # Captured, not piped into `grep -q`: under `pipefail` the producing grep
  # takes SIGPIPE when the consumer exits on an early match, the pipeline
  # returns 141, and this test goes FALSE — silently skipping the SATISFIED
  # rows that are the whole point of the predecessor sweep.
  _ledger_rows="$(grep -E '^\| RL-[0-9]+' plans/residue-ledger.md || true)"
  if grep -q 'SATISFIED' <<< "${_ledger_rows}"; then
    echo "!! rows with a SATISFIED due_when (join the next campaign frame):"
    grep 'SATISFIED' <<< "${_ledger_rows}"
  fi
else
  echo "(no plans/residue-ledger.md)"
fi

echo
echo "== 2. not_started items across campaign state files =="
found=0
for f in plans/staff-campaign-*-state.json; do
  [ -f "$f" ] || continue
  hits=$(python3 -c "
import json,sys
d=json.load(open('$f'))
for wn,w in (d.get('waves') or {}).items():
    for k,it in (w.get('items') or {}).items():
        if it.get('status')=='not_started':
            print(f'$f wave {wn} {k}: {it.get(\"title\",\"\")}')" 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "$hits"; found=1; fi
done
[ "$found" = 0 ] && echo "(none)"

echo
echo "== 3. Residue phrases in issue files with no follow-up number on the line =="
grep -rnE 'follow-?up[- ]?(class|candidate)|remain(s|ing)? (hand-built|unconverted|open)|not filed|residue' issues/ 2>/dev/null \
  | grep -vE '#[0-9]+|RL-[0-9]+' \
  | head -30 || echo "(none)"
