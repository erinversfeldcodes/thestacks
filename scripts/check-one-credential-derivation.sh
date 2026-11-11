#!/usr/bin/env bash
# The credential is spelled in exactly one place, and nothing may spell it again.
#
# ⛔ WHY THIS EXISTS, and it is the gap a shadow review found AFTER the
# migration was finished and its boxes were ticked.
#
# `Api.elm` derived `Authorization: Bearer …` in 70 independent places and a
# page module held a 71st. All 71 were collapsed onto `Api.requestHeaders`, and
# the evidence for that is a COUNT: 71 → 0, recorded per batch, monotonic.
#
# ⚠️ **A count is a fact about the past.** Nothing prevented a 72nd. Three
# instruments were written to stop the measurement going stale and NONE to stop
# the population growing again — and the one gate that would have seen a new
# inline site, `check-session-expiry-coverage.sh`, was deliberately configured
# to ACCEPT that form for the duration of the migration. So a re-introduced
# inline derivation would have classified as a correctly-authenticated endpoint
# and every gate would have stayed green.
#
# ⛔ WHY IT COMPOUNDS, which is what makes it worth a gate rather than a note.
# The next issue adds a CSRF token INSIDE `requestHeaders`, on the strength of
# that being the only derivation. A request that builds its own header does not
# get the token — and the server will not reject it either, because it carries no
# session for a check to miss. One copy-paste produces a state-changing request
# that is silently exempt from CSRF, with nothing anywhere reporting it.
#
# ⚖️ So the invariant is not "the count is 0". It is "there is one place", which
# is a property a gate can hold and a count cannot.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SRC="${1:-frontend/src}"

if [[ ! -d "$SRC" ]]; then
    echo "FAIL: $SRC not found, so this gate cannot look." >&2
    exit 1
fi

# ⛔ A FLOOR ON FILES SCANNED, not on findings. A glob that stopped matching
# would report "one derivation" over a corpus it never read, which is the same
# output as a clean run — the distinction this campaign failed on five times.
MIN_ELM_FILES=80

python3 - "$SRC" "$MIN_ELM_FILES" <<'PY'
import os
import re
import sys

src_root, floor = sys.argv[1], int(sys.argv[2])

# The one function allowed to spell the scheme, and the file it lives in.
HOME_FILE = os.path.join(src_root, "Api.elm")

# ⛔ `bearerHeader`, not `requestHeaders`, and the move is why this gate has an
# anti-vacuity half. The scheme literal used to live in `requestHeaders`; adding
# the CSRF proof meant the bearer and the proof needed separate arms, and Elm has
# no or-patterns — so keeping the literal in ONE place required extracting it.
#
# ⚠️ This gate REFUSED when that happened, saying "`requestHeaders` does not
# spell the credential at all" rather than passing over a file it could no longer
# find the derivation in. That is the guard working: a findings-based gate would
# have reported zero violations and been right about nothing.
HOME_FUNCTION = "bearerHeader"

# What counts as spelling the credential. Both forms, because collapsing them
# would let the other one through:
#   * the scheme literal   — `"Bearer " ++ token`, the value itself
#   * the header-name call — `Http.header "Authorization"`, the old idiom
SPELLINGS = [
    (re.compile(r'"Bearer\s'), 'the "Bearer " scheme literal'),
    (re.compile(r'Http\.header\s+"Authorization"'), 'Http.header "Authorization"'),
]


def strip_elm_comments(text):
    """Blank Elm comments, keeping line structure so line numbers stay true.

    ⛔ REQUIRED, NOT A REFINEMENT. This gate's subject matter IS its keywords,
    so every comment explaining it contains them — including the ones in
    `Api.elm` that explain why the builder exists, and the header of this very
    file. A sibling gate shipped without this and reported the one
    correctly-declared request in the file as its violation, quoting the comment
    that said why it was not one.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("{-", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("{-", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("-}", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def function_span(text, name):
    """(start, end) character offsets of one top-level function's definition.

    Returns None when the function cannot be found, which is a REFUSAL rather
    than an empty permitted region: a gate that cannot locate the one place the
    credential may be spelled would report every legitimate spelling as a
    violation, and the right response is to say so.
    """
    match = re.search(rf"^{name}\s*:", text, re.M)
    if not match:
        return None
    rest = text[match.start() :]
    # The definition ends at the next top-level binding or type declaration.
    following = re.search(r"\n(?=[a-z][A-Za-z0-9_']*\s*:)|\n(?=type\s)", rest[1:])
    stop = following.start() + 1 if following else len(rest)
    return match.start(), match.start() + stop


elm_files = []
for dirpath, _dirnames, filenames in os.walk(src_root):
    for filename in sorted(filenames):
        if filename.endswith(".elm"):
            elm_files.append(os.path.join(dirpath, filename))
elm_files.sort()

if len(elm_files) < floor:
    print(
        f"FAIL: scanned only {len(elm_files)} Elm file(s) under {src_root}; "
        f"expected at least {floor}.",
        file=sys.stderr,
    )
    print(
        "      A clean result over a corpus this small is the walk having drifted, not the\n"
        "      source having become safe — and those are the same output if the floor is on\n"
        "      findings instead of on files.",
        file=sys.stderr,
    )
    raise SystemExit(1)

home_text = ""
try:
    with open(HOME_FILE, encoding="utf-8") as handle:
        home_text = strip_elm_comments(handle.read())
except OSError:
    pass

span = function_span(home_text, HOME_FUNCTION)
if span is None:
    print(
        f"FAIL: could not find `{HOME_FUNCTION}` in {HOME_FILE}.",
        file=sys.stderr,
    )
    print(
        "      That function is the ONE place the credential may be spelled, so without it\n"
        "      this gate cannot tell the permitted spelling from a violation — and it would\n"
        "      report the builder itself. Renamed? Update HOME_FUNCTION in the same change.",
        file=sys.stderr,
    )
    raise SystemExit(1)

home_start, home_end = span
permitted = 0
violations = []

for path in elm_files:
    with open(path, encoding="utf-8") as handle:
        text = strip_elm_comments(handle.read())
    for pattern, label in SPELLINGS:
        for match in pattern.finditer(text):
            inside_home = path == HOME_FILE and home_start <= match.start() < home_end
            if inside_home:
                permitted += 1
                continue
            line_no = text[: match.start()].count("\n") + 1
            violations.append((path, line_no, label, text.split("\n")[line_no - 1].strip()[:70]))

# ⚠️ Anti-vacuity on the PERMITTED side too. If the builder stopped spelling the
# credential at all, this gate would pass over a frontend that cannot
# authenticate — a green run meaning "nobody sends a credential anywhere".
if permitted < 1:
    print(
        f"FAIL: `{HOME_FUNCTION}` does not spell the credential at all.",
        file=sys.stderr,
    )
    print(
        "      Either the scheme moved somewhere this gate does not know about — in which\n"
        "      case the move is the thing to review — or the frontend no longer attaches a\n"
        "      credential. Both deserve a human; neither is a pass.",
        file=sys.stderr,
    )
    raise SystemExit(1)

if violations:
    print(
        f"FAIL: {len(violations)} place(s) outside `Api.{HOME_FUNCTION}` spell the credential:",
        file=sys.stderr,
    )
    for path, line_no, label, text_line in violations:
        print(f"  {path}:{line_no}  {label}", file=sys.stderr)
        print(f"      {text_line}", file=sys.stderr)
    print(
        "\nThere must be exactly one derivation. Call `Api.httpHeaders <destination>\n"
        "<credential>` (or `Api.requestHeaders` for header DATA) instead of building the\n"
        "header here.\n"
        "\n"
        "⛔ This is not style. A CSRF token lives inside that builder, so a request that\n"
        "spells its own credential does not carry one — and the server cannot reject it for\n"
        "a missing token it never required. The request is silently exempt.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: the credential is spelled in {permitted} place(s), all inside "
    f"`Api.{HOME_FUNCTION}`; {len(elm_files)} Elm file(s) scanned under {src_root}."
)
PY
