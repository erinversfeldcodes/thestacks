#!/usr/bin/env bash
# A `buf breaking` suppression that suppresses nothing must fail the build.
#
# ⛔ WHAT THIS EXISTS FOR, recorded in `proto/buf.yaml` itself. A
# `FIELD_SAME_TYPE` suppression for `vision.proto` stood in that file and was
# removed on 2026-10-15 because it was SPENT: with it deleted, `buf breaking`
# still exited 0. It had been suppressing nothing for an unknown length of time
# while silently covering any future field-type change in that file — and a
# comment promising it was temporary sat directly above it.
#
# ⚠️ So the problem is not that people forget to write "temporary". They do
# write it. The problem is that nothing re-checks, and a suppression is only as
# temporary as whatever re-checks it.
#
# HOW IT CHECKS  Run `buf breaking` ONCE with `ignore_only` removed entirely,
# and collect every violation as a (rule, file) pair. An entry is load-bearing
# if some violation matches it, and SPENT if none does.
#
# ⛔ THE OBVIOUS IMPLEMENTATION IS VACUOUS, and this gate shipped that way for
# one probe. Removing one entry and asking whether `buf breaking` still fails
# tests the wrong thing: it fails for violations covered by the OTHER entries,
# so every entry is reported load-bearing regardless of what it covers.
# MEASURED — a deliberately spent entry (`FIELD_SAME_CARDINALITY` on
# `social.proto`, a file with no violations at all) was reported load-bearing
# along with all four real ones. The exit status is a property of the whole run;
# the question is per-entry, so the answer has to come from the violation LIST.
#
# ⚠️ `ignore_only` maps a rule to FILES, not fields, so every entry here is a
# file-wide allowance for one rule. That is what makes a spent one worth
# failing over rather than merely tidying: while it stands, the rule is off for
# the whole file.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

BUF_YAML="proto/buf.yaml"

if [[ ! -f "$BUF_YAML" ]]; then
    echo "FAIL: $BUF_YAML not found. Nothing was checked; this is a refusal, not a pass." >&2
    exit 1
fi

if ! command -v buf >/dev/null 2>&1; then
    echo "FAIL: buf is not on PATH, so no suppression could be tested." >&2
    echo "       Nothing was checked. This is a refusal, not a pass." >&2
    exit 1
fi

# ⚠️ The same guard `lint-proto.sh` carries, for the same measured reason: a
# `git ls-tree | grep -q` pipeline returns 141 under `pipefail` once the listing
# outgrows the pipe buffer and a match arrives before git finishes writing.
# Captured first so the status read is the grep's.
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "FAIL: origin/main is not available, so there is no baseline to compare against." >&2
    echo "       Every check below would compare a tree against itself and pass." >&2
    exit 1
fi

_main_tree="$(git ls-tree -r origin/main --name-only 2>/dev/null || true)"
if ! grep -q '\.proto$' <<< "${_main_tree}"; then
    echo "FAIL: origin/main carries no .proto files, so buf breaking has nothing to compare." >&2
    echo "       A suppression cannot be shown spent or load-bearing. This is a refusal." >&2
    exit 1
fi

python3 - "$BUF_YAML" "$REPO_ROOT" <<'PY'
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

buf_yaml = Path(sys.argv[1])

# ⚠️ ABSOLUTE. `lint-proto.sh` can use `../.git` because it runs from the real
# `proto/` directory; this gate runs buf from a COPY in a temp dir, where there
# is no `.git` two levels up. The relative form made buf exit 1 with no
# violations — which the anti-vacuity check below caught as "buf did not run"
# rather than reporting a clean result over a failed run.
AGAINST = f"{sys.argv[2]}/.git#branch=origin/main,subdir=proto"
src = buf_yaml.read_text(encoding="utf-8")

# ⛔ Parsed by structure rather than with a YAML library, because this gate must
# run with nothing installed beyond python3 and buf — the same constraint the
# sibling proto gates work under. The shape is fixed and small: under
# `ignore_only:`, a rule name at one indent and `- path` entries beneath it.
# ⛔ THIS GATE NEEDS ITS OWN FLOOR, or it becomes the thing it was built to
# catch: a parse that silently stops matching reports "no spent suppressions"
# over an unread file, which is indistinguishable from a clean result.
#
# The count is DECLARED rather than floored, for the reason a declared count
# beats a floor whenever the population changes only by someone deciding:
# adding or removing a suppression is exactly such a decision, and it should
# show up in this diff rather than inside slack.
#
# ⛔ DECLARED HERE, ABOVE THE PARSE, AND NOT BELOW IT. It used to sit after the
# block search, so the declared count caught a PARTIAL parse and was bypassed
# entirely by a TOTAL one: no match meant an early `SystemExit(0)` printing
# "nothing to police" while every suppression stood. MEASURED — re-indenting
# `ignore_only` by one space (still valid YAML, invisible to this regex) made
# this gate exit 0 with nine suppression lines live in the file.
#
# ⚠️ The general shape, and it is the second instance in one diff: an audit for
# fail-open enumerates what each BRANCH does, and both defects lived on a PATH
# rather than in a branch — there a missing `else`, here an early exit above
# the guard. There is nothing to read in either case.
EXPECTED_ENTRIES = 4

ignore_block = re.search(r"^  ignore_only:\n((?:.*\n)*?)(?=^\S|\Z)", src, re.M)
if not ignore_block:
    if EXPECTED_ENTRIES == 0:
        print("OK: no breaking.ignore_only block, and none is expected — nothing to police.")
        raise SystemExit(0)
    print(
        f"FAIL: no `breaking.ignore_only` block parsed out of {buf_yaml}, but "
        f"{EXPECTED_ENTRIES} entr(y/ies) are expected.",
        file=sys.stderr,
    )
    print(
        "       Either every suppression was deleted — good, set EXPECTED_ENTRIES to 0 in the\n"
        "       same change — or this gate's parse no longer matches the file, in which case it\n"
        "       was about to report 'nothing to police' over suppressions that are still live.\n"
        "       Re-indenting the block by one space is enough to cause this, and the file stays\n"
        "       valid YAML, so the second case is the likely one.\n"
        "       Nothing was checked. This is a refusal, not a pass.",
        file=sys.stderr,
    )
    raise SystemExit(1)

entries = []
current_rule = None
for raw in ignore_block.group(1).split("\n"):
    line = raw.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    rule = re.match(r"^    ([A-Z][A-Z0-9_]*):$", line)
    if rule:
        current_rule = rule.group(1)
        continue
    path = re.match(r"^      - (\S+)$", line)
    if path and current_rule:
        entries.append((current_rule, path.group(1)))

if len(entries) != EXPECTED_ENTRIES:
    print(
        f"FAIL: parsed {len(entries)} ignore_only entr(y/ies) from {buf_yaml}; "
        f"expected exactly {EXPECTED_ENTRIES}.",
        file=sys.stderr,
    )
    print(
        "       FEWER means either a suppression was removed — good, update the count in the\n"
        "       same change — or this gate's parse stopped matching, in which case it would\n"
        "       report no spent suppressions over a file it never read.\n"
        "       MORE means a suppression was added without that being recorded here.",
        file=sys.stderr,
    )
    for rule, path in entries:
        print(f"         {rule}: {path}", file=sys.stderr)
    raise SystemExit(1)


def breaking_violations_without_suppressions():
    """Every (rule, file) `buf breaking` reports when nothing is suppressed."""
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "proto"
        shutil.copytree(proto_dir, staged)

        # Strip the whole ignore_only block, so every violation shows up.
        text = staged.joinpath("buf.yaml").read_text(encoding="utf-8")
        stripped = re.sub(r"^  ignore_only:\n(?:.*\n)*?(?=^\S|\Z)", "", text, flags=re.M)
        assert "ignore_only" not in stripped, "failed to strip ignore_only from the copy"
        staged.joinpath("buf.yaml").write_text(stripped, encoding="utf-8")

        proc = subprocess.run(
            [
                "buf",
                "breaking",
                "--against",
                AGAINST,
                "--error-format=json",
            ],
            cwd=staged,
            capture_output=True,
            text=True,
        )

    found = Counter()
    for line in (proc.stdout + "\n" + proc.stderr).split("\n"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        rule, path = payload.get("type"), payload.get("path")
        if rule and path:
            found[(rule, path)] += 1
    return found, proc.returncode


proto_dir = buf_yaml.parent
violations, rc = breaking_violations_without_suppressions()

# ⛔ ANTI-VACUITY, and it is what makes every verdict below mean anything. An
# empty violation set is what a tree with no breaking changes produces AND what
# a failed buf run or a drifted JSON parse produces. With four load-bearing
# suppressions standing there must be violations to find.
if not violations:
    print(
        f"FAIL: `buf breaking` reported no violations with every suppression removed "
        f"(exit {rc}).",
        file=sys.stderr,
    )
    print(
        "       Either every suppression in this file is spent — in which case delete them all\n"
        "       and set EXPECTED_ENTRIES to 0 — or buf did not run and this gate just reported a\n"
        "       clean result over nothing. It cannot tell those apart, so it refuses.",
        file=sys.stderr,
    )
    raise SystemExit(1)

declared = set(entries)
violation_pairs = set(violations)
spent = sorted(declared - violation_pairs)
load_bearing = sorted(declared & violation_pairs)

# ⚠️ The other direction: a violation no entry covers. The baseline must be
# green, so every violation should map to a declared entry. One that does not
# means `buf breaking` is failing for a reason nobody recorded.
uncovered = sorted(violation_pairs - declared)
if uncovered:
    print(
        f"FAIL: {len(uncovered)} breaking violation(s) are covered by no ignore_only entry:",
        file=sys.stderr,
    )
    for rule, path in uncovered:
        print(f"  {rule}: {path}", file=sys.stderr)
    print(
        "\nThe baseline is supposed to be green, so every violation should map to a declared\n"
        "suppression. One that does not means either this gate's parse missed an entry, or a\n"
        "breaking change is being tolerated by something other than buf.yaml.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if spent:
    print(f"FAIL: {len(spent)} breaking suppression(s) are SPENT — they suppress nothing:", file=sys.stderr)
    for rule, path in spent:
        print(f"  {rule}: {path}", file=sys.stderr)
    print(
        "\nWith every suppression removed, `buf breaking` reports no violation of that rule in\n"
        "that file — so the entry is covering nothing. It is now only a standing allowance for\n"
        "ANY future violation of that rule in that file, because `ignore_only` maps a rule to\n"
        "FILES rather than fields.\n"
        "\n"
        "Delete them, and decrement EXPECTED_ENTRIES in this gate in the same change.\n"
        "\n"
        "\u26a0\ufe0f This is not hypothetical tidying: a FIELD_SAME_TYPE suppression for vision.proto sat\n"
        "in exactly this state for an unknown period, under a comment promising it was temporary.",
        file=sys.stderr,
    )
    raise SystemExit(1)

# ⛔ "DOES THIS ENTRY COVER SOMETHING" IS THE WRONG QUESTION — it must cover
# ONLY what it was created for. Every check above is satisfied by an entry
# matching SOME violation, so a second, unrelated field change on the same file
# during the suppression window is silently covered with this gate green. That
# is the real price of `ignore_only` being file-scoped, and until now this gate
# measured the window's existence rather than its contents.
#
# ⚠️ The multiplicity was being collected and THROWN AWAY: violations went into
# a set, so "4 pairs" was reported where there are 34 violations — and the
# message called them "violation(s)", which read as a far smaller blast radius
# than the suppressions actually have.
#
# Counts are DECLARED per entry, for the same reason the entry count is: each
# number changes only when someone decides to change the proto, so it belongs
# in the diff rather than inside slack.
EXPECTED_PER_ENTRY = {
    # Four Classify/Extract/Associate message deletions plus three more in the
    # same deletion event.
    ("MESSAGE_NO_DELETE", "stacks/internal/v1/vision.proto"): 7,
    # `AssociationStatus`.
    ("ENUM_NO_DELETE", "stacks/internal/v1/vision.proto"): 1,
    # Twelve datetimes moved from `string` to google.protobuf.Timestamp.
    ("FIELD_SAME_TYPE", "stacks/common/v1/writing_assistant.proto"): 12,
    # Those same twelve gaining explicit presence, plus `shelf` and `comment`
    # gaining `optional`.
    ("FIELD_SAME_CARDINALITY", "stacks/common/v1/writing_assistant.proto"): 14,
}

miscounted = []
for entry in sorted(declared):
    expected = EXPECTED_PER_ENTRY.get(entry)
    actual = violations.get(entry, 0)
    if expected is None:
        miscounted.append((entry, None, actual))
    elif expected != actual:
        miscounted.append((entry, expected, actual))

if miscounted:
    print(
        f"FAIL: {len(miscounted)} suppression(s) cover a different number of violations than "
        f"declared:",
        file=sys.stderr,
    )
    for (rule, path), expected, actual in miscounted:
        if expected is None:
            print(f"  {rule}: {path} — {actual} violation(s), none declared", file=sys.stderr)
        else:
            print(
                f"  {rule}: {path} — declared {expected}, found {actual}",
                file=sys.stderr,
            )
    print(
        "\nMORE than declared means the suppression is now covering a change nobody recorded —\n"
        "the file-scoped allowance doing exactly what makes it dangerous. FEWER means part of\n"
        "what it covered has landed or been reverted, so the entry is partly spent.\n"
        "\nEither way, decide deliberately and update EXPECTED_PER_ENTRY in the same change. A\n"
        "suppression that merely covers SOMETHING is not the same as one that covers only what\n"
        "it was created for, and every other check in this gate is satisfied by the former.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(load_bearing)} of {len(entries)} breaking suppression(s) are load-bearing, "
    f"matched against {sum(violations.values())} violation(s) across "
    f"{len(violation_pairs)} (rule, file) pair(s); none is spent, and each covers exactly the "
    f"number of violations declared for it."
)
for rule, path in load_bearing:
    print(f"    {rule}: {path}  ({violations[(rule, path)]} violation(s), as declared)")
PY
