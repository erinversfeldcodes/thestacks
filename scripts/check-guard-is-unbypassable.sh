#!/usr/bin/env bash
# A declared-count guard must not sit below a path that exits successfully.
#
# ⛔ WHY THIS EXISTS, and it was a live fail-open rather than a tidiness rule.
# `check-breaking-suppressions-are-spent.sh` declared `EXPECTED_ENTRIES = 4` at
# line 116 and early-returned `SystemExit(0)` with "nothing to police" at line
# 92. So the declared count caught a PARTIAL parse — fewer entries than
# expected — and was bypassed entirely by a TOTAL one. MEASURED: re-indenting
# the block it parses by ONE SPACE, which leaves the file valid YAML and changes
# nothing about what the underlying tool does, made that gate exit 0 with nine
# live suppressions in the file.
#
# ⚠️ THE SHAPE, in the reviewer's words: **an audit for fail-open enumerates
# what each BRANCH does, and the defect lives on a PATH.** There is nothing to
# read at the point where it goes wrong — the bug is the absence of a statement,
# not the content of one.
#
# ⚖️ WHAT THIS DELIBERATELY DOES NOT COVER, because it was measured and does not
# work. The sibling instance of that shape was an `if`/`elif` chain with no
# terminal `else`, which fell through in silence and meant `buf breaking` never
# ran in CI. That looks equally gateable and is not: "an `if`/`elif` chain with
# no `else`" is a NORMAL, CORRECT shape in this repository — 17 instances, every
# one legitimate. Two successive narrowings (every branch reports; and no branch
# exits) took it to 5 and then 4 hits, all still legitimate, and zero true
# positives. The property that distinguished the real defect is semantic — does
# the fall-through leave the verdict unestablished? — and every syntactic proxy
# tried catches correct code instead. A gate with four known false positives
# needs an exemption list, and this repository has just finished deleting one.
#
# So this covers the half that IS precise: a success exit above the guard, which
# is where every declared count in this repository lives.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import glob
import re
import sys

PATHS = sorted(
    set(
        glob.glob("scripts/**/*.sh", recursive=True)
        + glob.glob("scripts/**/*.py", recursive=True)
        + glob.glob("test/**/*.sh", recursive=True)
    )
)

# A declared count or floor: the thing that makes a gate's population checkable,
# and therefore the thing worth protecting from a path that skips it.
DECLARED = re.compile(
    r"^\s*(EXPECTED_[A-Z0-9_]+|MIN_[A-Z0-9_]+|ABSOLUTE_MIN)\s*=\s*[0-9]", re.M
)

# A SUCCESSFUL exit. Non-zero exits are irrelevant: a path that refuses cannot
# bypass a guard, it just refuses earlier.
SUCCESS_EXIT = re.compile(
    r"^\s*(raise\s+SystemExit\(\s*0\s*\)|sys\.exit\(\s*0\s*\)|exit\s+0)\s*$", re.M
)

# ⛔ THIS GATE NEEDS ITS OWN DECLARED COUNT, for exactly the reason it polices.
# A parse that stopped matching would report "no bypassable guards" over a
# corpus it never read, which is indistinguishable from a clean result.
#
# ⚠️ THE COUNT INCLUDES THIS GATE, which carries the constant below and is
# therefore in its own corpus. That is deliberate rather than an accident of the
# glob: a gate policing bypassable guards whose own guard were bypassable would
# be the exact defect it exists to catch. The first run reported one more than
# the hand count for precisely this reason.
#
# ⚠️ Written without the number, deliberately. It said "12 INCLUDES THIS GATE"
# and went stale the first time the population grew — a figure in prose beside a
# constant that changes is the rot this repository keeps recording, and here it
# would have sat two lines above the value that contradicted it.
#
# ⚠️ THIS COUNT SITS OVER A GROWING POPULATION, so every new gate that declares a
# floor touches this line. That is CORRECT FRICTION by the same reasoning that
# makes it a declared count rather than a floor: adding a guarded script is a
# decision, and it should appear in the diff rather than inside slack. Do not
# "fix" the friction by converting this to `>=` — a floor here would let a gate
# join the population without anyone noticing it had, which is the whole thing
# this file exists to prevent one level down.
# ⚖️ 22 → 23 on 2026-11-05: `check-e2e-mock-routes.sh` gained
# `MIN_MOCKED_PATHS`. It shipped with a floor on the ROUTE table and none on the
# mocked corpus, and a probe showed it printing "0 mocked path(s) checked ... all
# resolve" and exiting 0 — the asymmetry mattered because the mocked corpus is
# the input that can silently stop matching when the specs change how they spell
# `page.route`.
#
# ⚖️ 23 → 22 on 2026-11-07: `check-credential-origin.sh` was DELETED, taking its
# `MIN_REQUEST_SURFACE` with it. Its subject is empty — every request in the
# client is a `RequestSpec` whose `url` is an `Api.Url.SameOriginUrl`, so the
# property it parsed for is checked by the compiler on every build. ⛔ This is
# the direction the comment above calls "good, update the count in the same
# change", and it is the only honest reason to lower this number: a guard that
# went away because its question stopped being askable, not one that was
# removed because it was inconvenient.
EXPECTED_GUARDED_SCRIPTS = 23

guarded = {}
violations = []

for path in PATHS:
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        continue

    decls = [(m.start(), m.group(1)) for m in DECLARED.finditer(src)]
    if not decls:
        continue

    first_decl_pos, first_decl_name = decls[0]
    first_decl_line = src[:first_decl_pos].count("\n") + 1
    guarded[path] = sorted({name for _, name in decls})

    for m in SUCCESS_EXIT.finditer(src):
        if m.start() >= first_decl_pos:
            continue
        exit_line = src[: m.start()].count("\n") + 1
        violations.append(
            (path, exit_line, m.group(1).strip(), first_decl_line, first_decl_name)
        )

if len(guarded) != EXPECTED_GUARDED_SCRIPTS:
    print(
        f"FAIL: found {len(guarded)} script(s) carrying a declared-count guard; expected "
        f"exactly {EXPECTED_GUARDED_SCRIPTS}.",
        file=sys.stderr,
    )
    print(
        "       FEWER means a guard was removed — good, update the count in the same change —\n"
        "       or this gate's pattern stopped matching, in which case it would report no\n"
        "       bypassable guards over a corpus it never read.\n"
        "       MORE means a guard was added without that being recorded here.",
        file=sys.stderr,
    )
    for path, names in sorted(guarded.items()):
        print(f"         {path}: {', '.join(names)}", file=sys.stderr)
    raise SystemExit(1)

if violations:
    print(
        f"FAIL: {len(violations)} declared-count guard(s) sit below a path that exits 0:",
        file=sys.stderr,
    )
    for path, exit_line, how, decl_line, decl_name in violations:
        print(
            f"  {path}:{exit_line}  `{how}` precedes {decl_name} at line {decl_line}",
            file=sys.stderr,
        )
    print(
        "\nA guard below a success exit catches a PARTIAL failure of whatever it measures and is\n"
        "bypassed entirely by a TOTAL one — which is the case that matters, because a parse that\n"
        "matches nothing looks exactly like a corpus with nothing in it.\n"
        "\n"
        "Move the declaration ABOVE every success exit, and make the early-exit path assert\n"
        "against it (`if EXPECTED_X == 0: … else: refuse`) rather than returning 0 unconditionally.\n"
        "\n"
        "⚠️ MEASURED, not hypothetical: one gate in this repository exited 0 printing\n"
        "\"nothing to police\" while nine live suppressions stood in the file it had just failed to\n"
        "parse. Re-indenting that file by one space was enough.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(guarded)} of {EXPECTED_GUARDED_SCRIPTS} script(s) carrying a declared-count guard "
    f"have no success exit above it, enumerated from scripts/**/*.{{sh,py}} and test/**/*.sh."
)
for path, names in sorted(guarded.items()):
    print(f"    {', '.join(names)}  in {path}")
PY
