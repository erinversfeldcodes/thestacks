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
EXCLUDED_NAMES = ("CLAUDE.md", "AGENTS.md", "README.md")

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
    # "#279" — three or more digits, NOT preceded by a hex-colour context and
    # not inside a longer alphanumeric run. Two digits are too noisy to claim.
    (re.compile(r"(?<![\w#])#\d{3,}\b"), "an issue number"),
    # Campaign and wave labels.
    (re.compile(r"\bstaff-campaign-\d{4}-\d{2}-\d{2}"), "a campaign slug"),
    (re.compile(r"\bW\d+[a-z]\b"), "a wave label"),
]

# Lines that legitimately contain a pattern. Each entry is a substring; a line
# containing it is skipped. Keep this list SHORT and justified — an allowlist
# that grows without reasons is how a gate stops meaning anything.
#
# ⚠️ Nothing here yet, deliberately. If an entry becomes necessary, write the
# reason beside it, and prefer rephrasing the code over adding a line.
LINE_ALLOWLIST: list[tuple[str, str]] = []

# A hex colour is the classic false positive for the #NNN pattern.
#
# ⚠️ The obvious guard is wrong, and silently so — it was written that way first
# and swallowed almost every real violation. `^#[0-9a-fA-F]{3,8}$` matches
# `#412` too, because 4, 1 and 2 are all valid hex digits. Since 0-9 are a
# subset of hex, ANY all-digit issue number of length 3, 6 or 8 reads as a
# colour, and those are the common lengths. The gate passed a planted `#412`
# and would have shipped looking like it worked.
#
# The discriminator that actually holds: a hex colour in this codebase contains
# at least one LETTER (`#1a2b3c`, `#abc`), or sits in a CSS value position after
# a colon. Checked empirically before relying on it — a sweep for all-digit hex
# colours across every tracked non-doc file returned zero; every single hit was
# an issue citation. So an all-digit `#NNN` outside a CSS value position is a
# citation here, and treating it as one costs nothing.
HEX_WITH_LETTER = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
HAS_HEX_LETTER = re.compile(r"[a-fA-F]")
CSS_VALUE_POSITION = re.compile(r":\s*#[0-9a-fA-F]{3,8}\b")


# ⚠️ Second correction, and the lesson is that SYNTAX cannot separate these.
# `#356` (an issue) and `#183020` (a gradient stop) are both "# plus hex-valid
# digits"; a 3-digit issue number is indistinguishable from a 3-char colour.
# An earlier version of this function claimed, on the strength of a repo sweep,
# that no all-digit hex colours existed here — the sweep had been truncated by a
# `head`, and `frontend/css/main.css` is full of them.
#
# What DOES separate them is CONTEXT: a colour appears in a declaration value, a
# citation appears in a comment. So a hex-shaped match is a colour unless it sits
# on a comment line, and the comment forms below cover every language in this
# repo (CSS/JS block and line comments and their ` * ` continuations, shell and
# Elixir `#`, Elm/SQL `--`, HTML).
COMMENT_LEAD = ("*", "/*", "//", "#", "--", "<!--", "{-")


def on_comment_line(line: str, path: str) -> bool:
    stripped = line.lstrip()
    leads = COMMENT_LEAD
    if path.endswith(".css"):
        # ⚠️ `--` opens a comment in Elm and SQL but declares a CUSTOM PROPERTY
        # in CSS: `--wallpaper-color: #253040;` is a colour, not prose. Treating
        # `--` as a comment lead here marked every themed colour a citation.
        leads = tuple(lead for lead in leads if lead != "--")
    if stripped.startswith(leads):
        return True
    # A trailing comment: `foo();  // see #412` or `foo()  # see #412`.
    trailing = "/*" in line or "//" in line or " # " in line
    if not path.endswith(".css"):
        trailing = trailing or " -- " in line
    return trailing


def is_hex_colour(matched: str, line: str, path: str) -> bool:
    if not HEX_WITH_LETTER.match(matched):
        return False
    if HAS_HEX_LETTER.search(matched[1:]):
        return True
    # All-digit and hex-shaped: a colour in a value position, a citation in prose.
    return not on_comment_line(line, path)

violations = []

for path in tracked:
    if not path:
        continue
    if path.endswith(".md") or path.startswith(EXCLUDED_DIRS) or path in EXCLUDED_NAMES:
        continue
    if path.startswith(TOOLING_PATHS):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeDecodeError):
        continue  # binary or unreadable: nothing to cite a tracker in

    for lineno, line in enumerate(lines, start=1):
        if any(frag in line for frag, _reason in LINE_ALLOWLIST):
            continue
        for pattern, label in PATTERNS:
            match = pattern.search(line)
            if not match:
                continue
            if is_hex_colour(match.group(0), line, path):
                continue
            violations.append((path, lineno, label, match.group(0), line.strip()[:120]))
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
