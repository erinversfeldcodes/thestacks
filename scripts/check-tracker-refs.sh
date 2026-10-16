#!/usr/bin/env bash
# Code must not cite tracker artefacts — state the substance instead.
#
# The project rule is absolute: never cite an issue number, user-story id, ADR
# id, campaign name or wave label in code. The reason is that a tracker id sends
# a future reader to a system that may not outlive the code, while a sentence
# explaining WHY survives in the file. "See #412" ages into a dead end; "the
# cap belonged to the review-summary caller and was corrupting the other one"
# does not.
#
# This gate exists because that rule had no mechanism and was carried entirely
# by whoever happened to be reading. It was broken twice on one day: a
# `(issues/279)` citation that survived three months and every review, and four
# `ADR-015` citations added by someone who had, hours earlier, corrected a
# different artefact for breaking the same rule. Knowing a rule cold is not
# sufficient to follow it.
#
# SCOPE  Code only. `docs/`, `issues/`, `plans/`, `notes/` and every `*.md`
#        are OUT, because documentation cites decision records legitimately and
#        constantly — a repo-wide grep would be noise, and a gate people learn
#        to suppress is worse than no gate.
#
# ⚠️ FALSE POSITIVES ARE THE DESIGN PROBLEM HERE, not coverage. A gate that
# fires on a hex colour or a git SHA gets disabled within a week. The patterns
# below are deliberately narrow: they catch the two real violations this was
# written for and refuse to guess beyond that. Widen only with a case in hand.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import subprocess
import sys

# Tracked files only, so generated and ignored artefacts never reach the check.
tracked = subprocess.run(
    ["git", "ls-files", "-z"], capture_output=True, text=True, check=True
).stdout.split("\0")

EXCLUDED_DIRS = ("docs/", "issues/", "plans/", "notes/", "e2e/node_modules/")
# ⚠️ No EXCLUDED_NAMES list. There was one — CLAUDE.md, AGENTS.md, README.md —
# and it was unreachable: all three end in `.md`, which the `endswith(".md")`
# test below short-circuits first. Dead config that reads like coverage is
# worse than no config, because the next reader trusts it.

# ⚠️ The issue- and plan-MANAGEMENT tooling is exempt, and the distinction is
# the whole point of this gate rather than a hole in it.
#
# `campaign-residue.sh` opening `plans/residue-ledger.md` is a FILE OPERATION:
# the path is the thing it operates on, the same way a database tool names a
# table. A comment saying "see issues/279" is a CITATION: it points a reader
# somewhere else instead of telling them the reason. Only the second is what
# the rule forbids, and a gate that cannot tell them apart would force the
# project's own tooling to stop naming the files it exists to read.
#
# Keep this list to tools that genuinely manage those trees. If a file appears
# here for any other reason, the reason is wrong.
TOOLING_PATHS = (
    "scripts/campaign-residue.sh",
    "scripts/wave-status.sh",
    "scripts/hooks/",
    "scripts/mcp/",
    # ⚠️ This gate exempts ITSELF, and the reason is not convenience. Its
    # patterns and its comments must show what a violation LOOKS like to be
    # readable at all — the examples below are the documentation. A checker
    # that cannot contain its own examples either loses them or starts
    # obfuscating them to pass, and both are worse than one honest exemption.
    #
    # Note how this surfaced: the gate ran clean while it was still untracked,
    # because `git ls-files` could not see it. It began failing the moment it
    # was committed. A tool whose input is "tracked files" does not check
    # itself until it is tracked, so a clean first run proves less than it
    # appears to.
    "scripts/check-tracker-refs.sh",
)

# ⚠️ A SECOND exemption, kept separate from the one above because the reason is
# different and conflating them would let the tooling list grow by analogy.
#
# This gate's own test suite is nothing BUT planted violations: every case feeds
# it a citation and asserts it fails. Those strings are fixture data, the way a
# SQL-injection test contains injection strings. The alternatives are both
# worse — splitting the literals (`"ADR-" + "015"`) to slip past the check makes
# the suite unreadable and stops testing the real input, and dropping the cases
# leaves the gate with no proof it can fire, which is the exact defect the suite
# exists to prevent.
#
# Scope this to the suite that tests THIS gate. Any other test wanting in here
# is a test citing a tracker for real, which is what the rule forbids.
FIXTURE_PATHS = ("test/platform/tracker_refs_gate_test.sh",)

# Deliberately conservative. Each pattern names a tracker artefact and nothing
# else, and each has a worked false positive it must NOT match.
PATTERNS = [
    # "ADR-015", "ADR 015", "Decision 015" — but not "ADR" alone, and not a
    # bare 3-digit number.
    (re.compile(r"\b(?:ADR[ -]|Decision\s+)\d{2,3}\b"), "an ADR / decision-record id"),
    # "US-1.1.1" — the project's user-story form. Not "US" alone, and the dotted
    # tail is what distinguishes it from an ordinary hyphenated word.
    (re.compile(r"\bUS-\d+\.\d+"), "a user-story id"),
    # "issues/279", "plans/staff-campaign-..." — a path into the tracker trees.
    (re.compile(r"\b(?:issues|plans)/[\w.-]+"), "a path into issues/ or plans/"),
    # ⚠️ A decision record cited as a PATH is still a decision-record citation.
    # The `ADR[ -]\d` pattern above only sees the id spelling, so
    # `See docs/decisions/017.` sailed past the first version of this gate while
    # sitting in a protobuf contract comment — the same file type, and the same
    # class, that this gate was filed over.
    #
    # `docs/user_stories/` likewise: most such paths embed `US-1.1.1` and are
    # caught above, but the directory on its own is the same citation.
    (
        re.compile(r"\bdocs/(?:decisions|user_stories)/[\w.-]*"),
        "a path to a decision record or user story",
    ),
    # "#279" — three or more digits, NOT preceded by a hex-colour context and
    # not inside a longer alphanumeric run. Two digits are too noisy to claim.
    (re.compile(r"(?<![\w#])#\d{3,}\b"), "an issue number"),
    # Campaign and wave labels.
    #
    # ⚠️ The DATE is required, and that is the claim boundary. A dated slug
    # (`staff-campaign-2026-10-13`) names one particular campaign and ages into
    # a dead end. The bare phrase does not: `just wave-status`'s help text says
    # "Is a staff-campaign wave actually done?", which is the recipe naming its
    # own subject matter — the same "a tool naming its domain" case the tooling
    # exemption above protects, and rewording it would make the help worse, not
    # the code better.
    (re.compile(r"\bstaff-campaign-\d{4}-\d{2}-\d{2}"), "a campaign slug"),
    (re.compile(r"\bW\d+[a-z]\b"), "a wave label"),
    # ⚠️ The SPELLED-OUT wave label, which is the form this project actually
    # writes. `W2h` is how the campaign STATE FILE keys its items; prose in code
    # says "Wave 8 moved the five shelf links" or "that happened in Wave 4".
    # Seven live violations stood behind the gate because only the keyed form was
    # claimed — the pattern set had been derived from the two violations in hand
    # rather than from how the label is written in the tree.
    #
    # Not `Phase \d`, deliberately, and the contrast is the point: `view_as_plug`
    # documents its own two-step design as "Phase 1 (plug)" / "Phase 2
    # (authorize)". Fifty-odd such lines are a module describing itself, not a
    # citation. "Wave" has no such second meaning here; "Phase" does.
    (re.compile(r"\b[Ww]aves?\s+\d+\b"), "a wave label"),
]

# Lines that legitimately contain a pattern. Each entry is a substring; a line
# containing it is skipped. Keep this list SHORT and justified — an allowlist
# that grows without reasons is how a gate stops meaning anything.
#
# Prefer rephrasing the code over adding a line. An entry earns its place only
# when the pattern is structurally unavoidable, and it is preferred over
# TOOLING_PATHS whenever the unavoidable thing is a SPELLING rather than a file:
# a whole-file exemption stops checking everything else in that file, and this
# one demonstrably leaks — a prose citation rode into `scripts/wave-status.sh`
# on its path-operation exemption and no gate has seen it since.
LINE_ALLOWLIST: list[tuple[str, str]] = [
    # The campaign-status tool hardcodes the directory it reads state from, so
    # its test has to write a state file there — a file operation, same as the
    # tool's own, and the one thing the test cannot express another way. Scoped
    # to the sandbox slug: `probe-campaign` names no campaign that exists, so
    # this cannot admit a citation of a real one, and every other pattern stays
    # live in that file.
    (
        "plans/probe-campaign",
        "a throwaway sandbox state file, not a campaign that exists",
    ),
]

# A hex colour is the classic false positive for the #NNN pattern, and getting
# this discriminator right took three attempts. Both earlier versions were
# silently WRONG — they passed on the repo and on a planted violation alike —
# so the history is kept here rather than in a commit message nobody will read.
#
# ATTEMPT 1, the obvious guard: `^#[0-9a-fA-F]{3,8}$`. It matches `#412`, because
# 4, 1 and 2 are all valid hex digits. Since 0-9 are a subset of hex, EVERY
# all-digit issue number of length 3, 6 or 8 reads as a colour — and those are
# the common lengths. The gate passed a planted `#412` and looked like it worked.
#
# ATTEMPT 2, context by comment: an all-digit hex-shaped match is a colour unless
# it sits on a comment line, since "a colour appears in a declaration value, a
# citation appears in a comment". The second half of that sentence is false. A
# citation also appears in a STRING LITERAL — a test name, an assertion message
# — and the rule covers those explicitly. The miss was not hypothetical: a sweep
# over every tracked file found FIVE live citations the gate was blind to, four
# `#138`s inside shell assertion messages and one `#344` inside an Elm fuzz-test
# description. All five were fixed in the same change as this comment.
#
# ATTEMPT 3, what is actually true of this repo: an all-digit hex-shaped token is
# a colour only where colours are written — in a stylesheet or markup file, in a
# VALUE position, which is to say after a `:` on the same line. Every real case
# satisfies that (`--wallpaper-color: #253040;`,
# `background: linear-gradient(180deg, ..., #183020 100%)`), and the whole
# tracked tree contains exactly two such lines. Anywhere else, in any language,
# an all-digit `#NNN` is a citation.
#
# If a colour ever needs writing outside a stylesheet value, give it a letter
# (`#1a2b3c`) or a named token. That is cheaper than widening this.
#
# ⚠️ ATTEMPT 3 ALSO SHIPPED DEAD CODE, which is worth keeping visible because it
# is the same error one level down. The guard carried `HEX_WITH_LETTER` over a
# `[0-9a-fA-F]` class plus a `HAS_HEX_LETTER` early return — and neither could
# ever fire. The ONLY pattern above that produces a `#`-leading match is the
# issue-number one, `(?<![\w#])#\d{3,}\b`, which is DIGITS ONLY. So a
# letter-bearing colour like `#1a2b3c` never reaches this function at all, and
# the letter branch was unreachable. The test case that claimed to pin it was
# therefore passing for the wrong reason: deleting the guard left it green.
#
# What is actually being asked here is narrower than the old name suggested:
# given a run of digits the citation pattern already matched, is that run ALSO
# a legal hex-colour length?
HEX_COLOUR_LENGTH = re.compile(r"^#(?:\d{3}|\d{6}|\d{8})$")

# Where colours legitimately appear as literals. Deliberately NOT .elm/.ex/.ts:
# an inline style there should use a token or a letter-bearing hex.
STYLE_PATH_SUFFIXES = (".css", ".svg", ".html", ".heex")


def in_comment(line: str, start: int) -> bool:
    """True when the match at `start` is inside a comment opened on this line.

    ⚠️ Without this, "after a colon" is far too weak. A stylesheet line is
    FULL of colons, so a trailing comment inherits the value position of the
    declaration before it:

        --wallpaper-color: #253040; /* see #412 */

    The colour is excused correctly, and then the citation beside it was
    excused too — by a colon that belongs to the declaration, not to it.
    """
    before = line[:start]
    if "/*" in before and before.rfind("/*") > before.rfind("*/"):
        return True
    if "<!--" in before and before.rfind("<!--") > before.rfind("-->"):
        return True
    return "//" in before


def in_value_position(line: str, start: int) -> bool:
    """True when the match at `start` sits after a `:` and outside a comment.

    ⚠️ Takes the match's OFFSET, not its text. The earlier version did
    `line.find(matched)`, which finds the FIRST occurrence — so on a line
    holding the same token twice it answered about the wrong one.
    """
    return start > 0 and ":" in line[:start] and not in_comment(line, start)


def is_hex_colour(matched: str, line: str, path: str, start: int) -> bool:
    if not HEX_COLOUR_LENGTH.match(matched):
        return False
    # A run of digits that is also a legal colour length. Only a stylesheet
    # value position makes it a colour; a comment, a string literal and a test
    # name are all citations.
    return path.endswith(STYLE_PATH_SUFFIXES) and in_value_position(line, start)

violations = []

for path in tracked:
    if not path:
        continue
    if path.endswith(".md") or path.startswith(EXCLUDED_DIRS):
        continue
    if path.startswith(TOOLING_PATHS) or path in FIXTURE_PATHS:
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeDecodeError):
        continue  # binary or unreadable: nothing to cite a tracker in

    for lineno, line in enumerate(lines, start=1):
        if any(frag in line for frag, _reason in LINE_ALLOWLIST):
            continue
        reported = False
        for pattern, label in PATTERNS:
            # ⚠️ `finditer`, not `search`, and the reason is a fail-open rather
            # than thoroughness. With `search` the loop saw only the FIRST match
            # on a line; if that one was excused as a colour it moved to the next
            # PATTERN, so every later citation on the same line went unreported.
            # Concretely, this passed:
            #     --wallpaper-color: #253040; /* see #412 */
            # The colour is excused correctly and the citation beside it is never
            # looked at. Narrow — only in the four stylesheet/markup extensions,
            # only within one line — but it is a hole that widens with every
            # excusal added here.
            for match in pattern.finditer(line):
                if is_hex_colour(match.group(0), line, path, match.start()):
                    continue
                violations.append((path, lineno, label, match.group(0), line.strip()[:120]))
                reported = True
                break
            if reported:
                break

if violations:
    print(
        "FAIL: code cites tracker artefacts. State the substance instead.",
        file=sys.stderr,
    )
    print(file=sys.stderr)
    for path, lineno, label, matched, text in violations:
        print(f"  {path}:{lineno} — {label} ({matched!r})", file=sys.stderr)
        print(f"      {text}", file=sys.stderr)
    print(
        "\nA tracker id points into a system that may not outlive this code, and a reader\n"
        "who follows it learns nothing the file could not have told them. Replace it with\n"
        "the reason: what was decided, and why it matters here. A date is fine; a commit\n"
        "sha is fine; the substance is better than either.\n"
        "\n"
        "Documentation is exempt by design — docs/, issues/, plans/, notes/ and *.md may\n"
        "cite freely. This check covers code only.",
        file=sys.stderr,
    )
    sys.exit(1)

print("OK: no tracker references in code.")
PY
