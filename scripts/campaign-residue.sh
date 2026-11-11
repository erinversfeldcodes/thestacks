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

# ⛔ THE HEADER IS VALIDATED, because reading by COLUMN is only as good as
# knowing which column is which.
#
# Everything below indexes `status` at position 3. If someone reorders or
# renames the columns, every row parses cleanly and the verdicts are read off
# the wrong cells. That failure IS loud — a reorder prints all 300 rows as open
# — but loud is not the same as interpretable, and "300 open rows" invites the
# reading that the ledger exploded rather than that the header moved. Same
# distinction as a floor refusal versus a hazard verdict: both are red, only one
# tells you what to do.
EXPECTED_HEADER = ["id", "finding", "source", "status", "due_when", "disposition"]

header = None
for line in open("plans/residue-ledger.md"):
    if line.startswith("|") and "---" not in line:
        cells = [c.strip() for c in SPLIT.split(line.rstrip("\n"))]
        if len(cells) >= 3 and not re.match(r"^RL-\d+$", cells[1]):
            header = cells[1:-1]
            break

if header != EXPECTED_HEADER:
    print("!! REFUSING: the ledger's column header is not the one this reader indexes.", file=sys.stderr)
    print(f"   expected: {EXPECTED_HEADER}", file=sys.stderr)
    print(f"   found:    {header}", file=sys.stderr)
    print("   Every verdict below is read off a column POSITION, so a reordered or renamed", file=sys.stderr)
    print("   header makes each row parse cleanly and mean something else. Fix the header,", file=sys.stderr)
    print("   or update EXPECTED_HEADER and the indices together.", file=sys.stderr)
    raise SystemExit(1)

# ⚠️ The status vocabulary is closed, so a typo cannot quietly become residue.
# `r[STATUS].lower() != "closed"` treats ANY unrecognised value as open, which
# is the safe direction for a misspelling but silent either way: `clsoed` would
# show up as an open row with no hint that the word is wrong, and `Closed` with
# a capital would be swallowed by the lower(). Measured vocabulary in use:
# closed (275), open (17), scheduled (10), deferred (9).
KNOWN_STATUSES = {"closed", "open", "scheduled", "deferred"}

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

unknown = sorted({r[STATUS] for r in rows if r[STATUS].lower() not in KNOWN_STATUSES})
if unknown:
    print(f"!! REFUSING: {len(unknown)} unrecognised status value(s) in the ledger:", file=sys.stderr)
    for value in unknown:
        ids = [r[0] for r in rows if r[STATUS] == value]
        print(f"     {value!r}  ({', '.join(ids[:6])}{' …' if len(ids) > 6 else ''})", file=sys.stderr)
    print(f"   Known: {', '.join(sorted(KNOWN_STATUSES))}.", file=sys.stderr)
    print("   An unrecognised value reads as OPEN here, which is the safe direction for a", file=sys.stderr)
    print("   typo but says nothing — so a misspelled `closed` becomes permanent residue", file=sys.stderr)
    print("   nobody can discharge, and a capitalised one is swallowed silently. Fix the", file=sys.stderr)
    print("   value, or add it to KNOWN_STATUSES with the reason it is a distinct state.", file=sys.stderr)
    raise SystemExit(1)

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
  # ⛔ The SATISFIED marker is read from the `due_when` CELL of a NON-CLOSED
  # row, not grepped across the whole line — and this is the repo's
  # most-recorded gate failure, caught here by a row describing a different
  # instance of it.
  #
  # MEASURED 2026-10-22: a new row whose finding text contains the words "ALL
  # SATISFIED BY ITS FIXTURE" was reported as a satisfied trigger. It is
  # `closed`, and the word was in its prose rather than its trigger — so the
  # sweep's one job, naming rows that should join the next campaign frame,
  # produced a row that is finished and a wall of unrelated text.
  #
  # The whole-line grep could not distinguish a marker from a mention. A ledger
  # whose rows discuss gate markers will contain those markers as words, so
  # position is the only thing that separates configuration from commentary.
  python3 - <<'MARKER'
import re

SPLIT = re.compile(r"(?<!\\)\|")
STATUS, DUE = 3, 4

hits = []
for line in open("plans/residue-ledger.md"):
    if not line.startswith("| RL-"):
        continue
    cells = [c.strip() for c in SPLIT.split(line.rstrip("\n"))[1:-1]]
    if len(cells) != 6 or cells[STATUS].lower() == "closed":
        continue
    if "SATISFIED" in cells[DUE]:
        hits.append((cells[0], cells[DUE]))

if hits:
    print("!! rows with a SATISFIED due_when (join the next campaign frame):")
    for rid, due in hits:
        print(f"   {rid}: {due}")
MARKER

  # ⛔ AND THE COMPUTABLE HALF, because the check above only finds the word
  # SATISFIED — which someone has to have typed. A trigger is discharged
  # exactly as often as the person who wrote it comes back to say so, which is
  # the property the ledger exists to remove, not to reproduce.
  #
  # MEASURED 2026-10-22: RL-076's trigger read "W3d / #485, in progress" after
  # #485 had completed. A fresh pass reads that as scheduled against work still
  # in flight, so the row is neither discharged nor re-derived — and the row's
  # own finding is that scheduled work reported as unscheduled makes every
  # count of unowned residue wrong. A stale owner is the same error with the
  # blame misfiled.
  #
  # ⚠️ ALL cited issues must be complete before a row is reported, not any. A
  # row legitimately names a completed predecessor as context alongside its live
  # owner — RL-076 now cites #485 that way, and reporting on "any" would make
  # the fix to that row trip this check.
  #
  # ⚠️ And three states, not two: an issue appearing in no campaign state file
  # is UNKNOWN, reported separately, because silently reading unknown as
  # "not complete" is how a trigger whose owner was never tracked stays
  # invisible.
  python3 - <<'TRIGGERS'
import glob, json, re, sys

SPLIT = re.compile(r"(?<!\\)\|")
STATUS, DUE = 3, 4

status = {}
items_seen = 0


def walk(items):
    global items_seen
    values = items.values() if isinstance(items, dict) else items
    if not isinstance(values, (list, type({}.values()))):
        return
    for item in values:
        if not isinstance(item, dict):
            continue
        items_seen += 1
        number = str(item.get("issue") or "").lstrip("#")
        if number.isdigit():
            status.setdefault(number, set()).add(item.get("status"))


state_files = glob.glob("plans/*state.json")
for path in state_files:
    try:
        doc = json.load(open(path))
    except Exception:
        continue
    waves = doc.get("waves") or {}
    for wave in (waves.values() if isinstance(waves, dict) else waves):
        if isinstance(wave, dict):
            walk(wave.get("items") or {})
    walk(doc.get("items") or {})

# ⚠️ Anti-vacuity, and the floor is on THE WALKER WORKING rather than on the
# campaign being big. MEASURED: the first version refused below 20 known
# statuses, which refused every sandbox in this gate's own suite and would
# refuse a young campaign — a floor that fails on a legitimately small input is
# not measuring what it claims to.
#
# The size-independent signal is items walked versus numbers extracted. If
# items exist and NONE yielded an issue number, the field this reads has moved
# and every trigger below would report UNKNOWN — which is indistinguishable
# from a ledger whose triggers are all live.
if items_seen and not status:
    print(
        f"!! REFUSING: walked {items_seen} campaign item(s) and extracted ZERO issue numbers.",
        file=sys.stderr,
    )
    print(
        "   Every trigger would then read as UNKNOWN and a satisfied one would be",
        file=sys.stderr,
    )
    print(
        "   invisible, which is indistinguishable from a ledger with none. The `issue`",
        file=sys.stderr,
    )
    print("   field this walks has probably moved.", file=sys.stderr)
    raise SystemExit(1)

# ⚠️ And no campaign at all is INAPPLICABLE, not clean. Saying so is what keeps
# "nothing to reconcile" from reading as "everything reconciles".
if not state_files:
    print("(no campaign state files — trigger reconciliation did not run)")
    raise SystemExit(0)

satisfied, unknown = [], []
for line in open("plans/residue-ledger.md"):
    if not line.startswith("| RL-"):
        continue
    cells = [c.strip() for c in SPLIT.split(line.rstrip("\n"))[1:-1]]
    if len(cells) != 6 or cells[STATUS].lower() == "closed":
        continue
    cited = re.findall(r"#(\d+)", cells[DUE])
    if not cited:
        continue
    seen = {n: status.get(n) for n in cited}
    if all(s == {"complete"} for s in seen.values()):
        satisfied.append((cells[0], cells[DUE][:90], cited))
    elif any(s is None for s in seen.values()):
        unknown.append((cells[0], [n for n, s in seen.items() if s is None]))

if satisfied:
    print("!! rows whose due_when names ONLY completed issues — the trigger has fired:")
    for rid, due, cited in satisfied:
        print(f"   {rid}: every issue it names is complete ({', '.join('#' + n for n in cited)})")
        print(f"      due_when: {due}")
    print("   Discharge the row, or re-point it at the issue that owns the class now.")
if unknown:
    print("?? rows citing an issue tracked in no campaign state file:")
    for rid, missing in unknown:
        print(f"   {rid}: {', '.join('#' + n for n in missing)} — status UNKNOWN, not 'incomplete'")
if not satisfied and not unknown:
    print(f"(every non-closed row's cited issues are live; {len(status)} issue statuses read)")
TRIGGERS
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
