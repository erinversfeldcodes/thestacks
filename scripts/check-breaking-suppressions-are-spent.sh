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
ignore_block = re.search(r"^  ignore_only:\n((?:.*\n)*?)(?=^\S|\Z)", src, re.M)
if not ignore_block:
    print("OK: no breaking.ignore_only block — nothing to police.")
    raise SystemExit(0)

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

# ⛔ THIS GATE NEEDS ITS OWN FLOOR, or it becomes the thing it was built to
# catch: a parse that silently stops matching reports "no spent suppressions"
# over an unread file, which is indistinguishable from a clean result.
#
# The count is DECLARED rather than floored, for the reason a declared count
# beats a floor whenever the population changes only by someone deciding:
# adding or removing a suppression is exactly such a decision, and it should
# show up in this diff rather than inside slack.
EXPECTED_ENTRIES = 4

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

    found = set()
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
            found.add((rule, path))
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
spent = sorted(declared - violations)
load_bearing = sorted(declared & violations)

# ⚠️ The other direction: a violation no entry covers. The baseline must be
# green, so every violation should map to a declared entry. One that does not
# means `buf breaking` is failing for a reason nobody recorded.
uncovered = sorted(violations - declared)
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

print(
    f"OK: {len(load_bearing)} of {len(entries)} breaking suppression(s) are load-bearing, "
    f"matched against {len(violations)} violation(s); none is spent."
)
for rule, path in load_bearing:
    print(f"    {rule}: {path}")
PY
