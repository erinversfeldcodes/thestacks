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
  grep -E '^\| RL-[0-9]+' plans/residue-ledger.md | grep -Ev '\| *closed *\|' || echo "(none open)"
  echo
  if grep -E '^\| RL-[0-9]+' plans/residue-ledger.md | grep -q 'SATISFIED'; then
    echo "!! rows with a SATISFIED due_when (join the next campaign frame):"
    grep -E '^\| RL-[0-9]+' plans/residue-ledger.md | grep 'SATISFIED'
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
