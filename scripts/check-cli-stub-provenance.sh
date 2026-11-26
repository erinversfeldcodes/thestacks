#!/usr/bin/env bash
# A stubbed CLI must say which real tool output it was copied from, and when.
#
# ⛔ WHY THIS EXISTS — a stubbed suite can only test the contract its stub
# encodes, and that cost three undetected faults in one script. The preview
# orphan sweep was driven against a stub `modal` that emitted the 1.2.6 key
# spelling and a successful `app stop`. Every assertion passed, for years of CLI
# drift, over a leg that collected nothing. The real 1.6.2 uses different keys
# and PROMPTS on `app stop`, so the live code path could not have worked.
#
# ⚠️ The general shape: a stub written from the upstream tool's CURRENT output
# becomes a frozen copy of it, and the suite then verifies the code against its
# author's memory of an API rather than against the API. Worth contrasting with
# what DID work in the same suite — its refusals (missing CLI, empty listing)
# were genuinely load-bearing, because they assert the SCRIPT's own behaviour
# rather than the upstream's shape.
#
# ⚖️ So the fix is not "stop using stubs". It is to make staleness VISIBLE: pin
# each stub to a recorded real response and put a date on it. A contract fixture
# with a date is re-recordable; one without is indistinguishable from a guess.
#
# WHAT IT CHECKS  Every (file, tool) pair that defines a stub CLI must carry a
# line of the form
#
#     # stub-provenance: <tool> <version> captured <YYYY-MM-DD>
#
# ⛔ ENUMERATED FROM THE STUBS, joined to the markers — never the reverse. A list
# built by asking which markers exist can only contain tools somebody already
# documented, which is the defect rather than the check.
#
# ⚠️ AGE IS REPORTED, NOT FAILED. A gate that turns red at N days is a time bomb
# that fires in CI on a day nobody changed anything, and the first fix for that
# is to delete the gate. Absence of a marker fails; age is printed so a stale
# capture is visible on every run.
set -uo pipefail
# ⚠️ Resolved from GIT, not from `dirname "$0"/..`, and the sibling suppression
# gate paid for this lesson first. This gate's own suite drives COPIES of it
# from a temp directory — the only way to plant a stub without editing the
# committed gate — and a path derived from the script's own location then points
# two levels above a temp dir, where the classifier and the corpus both appear
# to be missing. The copy is still the thing under test; where it sits is not.
#
# ⚠️ The fallback is PARENTHESISED. Written as `git … || cd … && pwd` it parses
# as `(git || cd) && pwd`, so on the normal path git succeeds AND `pwd` also
# runs — giving a two-line REPO_ROOT and a `cd` that fails on it. Measured.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import datetime
import glob
import os
import re
import subprocess
import sys

# The CLIs this repository stubs. Named explicitly rather than "any word after a
# slash", because `cat > "$WORK/config.toml"` is not a stub CLI and a pattern
# loose enough to catch it would need an exemption list.
TOOLS = ("modal", "flyctl", "fly", "gh", "neon", "psql", "dbt", "buf")

STUB_DEF = re.compile(
    r'cat\s*>\s*"?\$[A-Za-z_][A-Za-z0-9_]*/(' + "|".join(TOOLS) + r')"?'
)
# ⚖️ THREE STATES, and only a FALSE claim fails — the same shape the review and
# drive staleness checks use. `captured <date>` is a verified re-recording
# against the real CLI; `captured unknown` is a DECLARED gap, which passes and is
# counted; a missing marker is unaccounted and fails.
#
# ⛔ The `unknown` state is not a loophole, it is the honest answer for six of
# the seven stubs here and writing anything else would have been the dishonesty
# this gate exists to catch. Reading `fly --version` says what is INSTALLED
# today; it does not say the stub's response SHAPE was re-recorded against it,
# and stamping today's date would have claimed exactly that. Only the modal stub
# in the sweep suite has a real provenance, because someone actually drove the
# CLI and wrote down what it emitted.
MARKER = re.compile(
    r"^\s*#\s*stub-provenance:\s*(\S+)\s+(\S+)\s+captured\s+(\d{4}-\d{2}-\d{2}|unknown)\s*$"
)

# ⛔ A DECLARED COUNT, not a floor, because the population changes only by
# someone deciding to stub another CLI — and that decision should show up in
# this diff rather than inside slack. FEWER means a stub was removed (good,
# update this) or the pattern stopped matching, in which case the gate would
# report every remaining stub documented over a corpus it never read.
EXPECTED_PAIRS = 7

found = {}   # (file, tool) -> first line number
markers = {} # (file, tool) -> (version, date)

# ⛔ CLASSIFIED, not read raw — and this gate reproduced the defect it polices
# before it was. Its OWN test suite plants `cat > "$STUBS/psql"` and a fake
# marker inside heredocs, as test data; read raw, those counted as a real stub
# and a real marker, and the gate reported `found 0 … expected 8` over a corpus
# it had miscounted in both directions. A suite that spells the pattern it tests
# is not an edge case here, it is the normal shape of a test.
#
# ⚠️ BOTH flags, because this gate needs the opposite of what the hazard scanner
# needs on both axes. Its marker IS a comment, so comments must survive; and a
# stub is defined as `cat > "$STUBS/fly"`, so the path it matches on is inside a
# double-quoted string — blanking string literals made this gate find ZERO stubs
# in a tree with seven. What remains blanked is heredoc BODIES, which is the
# irreducible part and the only part this gate actually needed.
BLANK_DATA = "scripts/lib/blank-shell-data.py"
if not os.path.exists(BLANK_DATA):
    print(
        f"FAIL: {BLANK_DATA} is missing, so test data would be counted as real stubs.\n"
        "       Nothing was checked. This is a refusal, not a pass.",
        file=sys.stderr,
    )
    raise SystemExit(1)


def classified(path):
    """The file with heredoc BODIES blanked; comments and string literals kept."""
    proc = subprocess.run(
        [sys.executable, BLANK_DATA, "--keep-comments", "--keep-strings"],
        stdin=open(path, "rb"),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.split("\n")


for path in sorted(glob.glob("test/**/*.sh", recursive=True)):
    lines = classified(path)
    if lines is None:
        print(f"FAIL: could not classify {path}; refusing rather than miscounting.", file=sys.stderr)
        raise SystemExit(1)
    for n, line in enumerate(lines, 1):
        m = STUB_DEF.search(line)
        if m:
            found.setdefault((path, m.group(1)), n)
        k = MARKER.match(line)
        if k:
            markers[(path, k.group(1))] = (k.group(2), k.group(3))

if len(found) != EXPECTED_PAIRS:
    print(
        f"FAIL: found {len(found)} (file, tool) stub pair(s); expected exactly "
        f"{EXPECTED_PAIRS}.",
        file=sys.stderr,
    )
    print(
        "       FEWER means a stub was removed — good, update the count in the same change —\n"
        "       or this gate's pattern stopped matching, in which case it would report every\n"
        "       remaining stub as documented over a corpus it never read.\n"
        "       MORE means a CLI was stubbed without that being recorded here.",
        file=sys.stderr,
    )
    for (path, tool), n in sorted(found.items()):
        print(f"         {path}:{n}  {tool}", file=sys.stderr)
    raise SystemExit(1)

undocumented = sorted(k for k in found if k not in markers)
if undocumented:
    print(
        f"FAIL: {len(undocumented)} stubbed CLI(s) do not say what real output they encode:",
        file=sys.stderr,
    )
    for path, tool in undocumented:
        print(f"  {path}:{found[(path, tool)]}  stubs `{tool}` with no provenance", file=sys.stderr)
    print(
        "\nAdd a line to each file, beside the stub:\n"
        "    # stub-provenance: <tool> <version> captured <YYYY-MM-DD>\n"
        "\nA stub written from the tool's CURRENT output becomes a frozen copy of it, and the\n"
        "suite then verifies the code against its author's memory of an API. One such stub\n"
        "encoded a CLI version two majors behind and three faults went undetected behind a\n"
        "fully green suite. The date is what makes that re-checkable.",
        file=sys.stderr,
    )
    raise SystemExit(1)

# The other direction: a marker for a tool this file no longer stubs. A stale
# marker is worse than a missing one, because the next reader trusts it.
orphaned = sorted(k for k in markers if k not in found)
if orphaned:
    print(f"FAIL: {len(orphaned)} stub-provenance marker(s) describe a stub that is gone:", file=sys.stderr)
    for path, tool in orphaned:
        print(f"  {path}  documents `{tool}`, which it no longer stubs", file=sys.stderr)
    print(
        "\nRemove the marker with the stub. A provenance note for a stub that does not exist\n"
        "is a claim about nothing, and it makes the count above wrong.",
        file=sys.stderr,
    )
    raise SystemExit(1)

today = datetime.date.today()
verified, unverified = [], []
for (path, tool), (version, date_str) in sorted(markers.items()):
    if date_str == "unknown" or version == "unknown":
        unverified.append((path, tool, version, date_str))
        continue
    try:
        captured = datetime.date.fromisoformat(date_str)
    except ValueError:
        print(f"FAIL: {path} records an unparseable capture date for `{tool}`: {date_str}", file=sys.stderr)
        raise SystemExit(1)
    verified.append(((today - captured).days, path, tool, version, date_str))

verified.sort(reverse=True)
print(
    f"OK: {len(found)} of {EXPECTED_PAIRS} stubbed CLI(s) account for the real output they encode, "
    f"enumerated from the stub definitions in test/**/*.sh and joined to their markers."
)
print(f"    {len(verified)} re-recorded against the real CLI; {len(unverified)} declared UNVERIFIED.")

if verified:
    print("\n  re-recorded:")
    for days, path, tool, version, date_str in verified:
        print(f"    {tool:8} {version:12} captured {date_str}  ({days}d ago)  {path}")
    print(
        f"\n  ⚠️ Oldest re-recording is {verified[0][0]} days old ({verified[0][2]} in "
        f"{verified[0][1]}).\n"
        "     A COUNT, not a verdict — age alone is not a defect, and this gate deliberately does\n"
        "     not fail on it, because a check that turns red on a day nobody changed anything gets\n"
        "     deleted. Re-record a stub when you touch the code it covers."
    )

if unverified:
    print(f"\n  ⚠️ UNVERIFIED — these encode a CLI contract nobody has checked against the real tool:")
    for path, tool, version, date_str in unverified:
        print(f"    {tool:8} {'(version ' + version + ')':22}  {path}")
    print(
        "     This is the honest state, not a pass: each of these was written from its author's\n"
        "     memory of an API and has never been compared to one. A stub in exactly this state\n"
        "     encoded a CLI two majors behind and hid three faults behind a fully green suite.\n"
        "     Re-record one by driving the real CLI and replacing `unknown` with its version and\n"
        "     today's date."
    )
