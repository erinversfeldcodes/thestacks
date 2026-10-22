"""Blank out the parts of a shell script that are DATA, keeping line numbers.

Emitted line-for-line, so `grep -n` over the result reports the ORIGINAL line
numbers. Three things are data and get blanked:

  * comments          — a `#` outside quotes, to end of line
  * heredoc bodies    — between `<<MARKER` / `<<-'MARKER'` and MARKER
  * literal string text — the inside of '...' and the literal runs of "..."

⛔ Blanking literal string text while keeping everything outside it is the whole
trick, and it is what separates a pipeline written as code from one written as
data. `cmd | grep -q "x"` keeps its `|` and both command words, because those
sit outside the quotes, and still matches. A plant like
`assert_contains "$SRC" 'inert | grep -q x'` has the entire pipeline inside one
single-quoted string, so blanking leaves `assert_contains "" ''` and it matches
nothing. No exemption list can make that distinction; it is a property of the
line, which is why this file replaces one.

⛔ A DOUBLE-QUOTED STRING IS NOT DATA, and getting this wrong is how the first
version of this file broke seven passing assertions in one run. `"..."`
undergoes expansion, so a command substitution inside it is executable code:

    X="prefix$(cat /etc/hosts | head -1)"

is a real hazard — under `set -e` that pipeline's 141 becomes the script's exit
status — and blanking the whole double-quoted run hid it. MEASURED: the gate's
own suite reported six assignment SHAPES accepted that it had previously
refused. So `$(…)` and backticks inside `"…"` are scanned as code, recursively,
and only the literal runs around them are blanked. Single quotes have no such
case: nothing expands inside `'…'`, which is why they can be blanked whole.

⚠️ `<<<` is a here-STRING and must NOT open a heredoc. The gate this serves is
written almost entirely in here-strings, so treating `<<<` as an opener would
swallow the rest of the file and report it clean.

⚠️ And the heredoc DELIMITER is consumed during the scan rather than matched
afterwards. `<<'STUB'` carries quotes that belong to the redirection token, not
to a string literal — blanking them first (the obvious order) loses the
delimiter, the body is never recognised as a body, and every hazard inside it
is read as code. Also measured, on the same first version.
"""

import re
import sys

# `<<` or `<<-`, then an optional quote, then the delimiter word. The negative
# lookahead is what keeps here-strings out.
HEREDOC_AT = re.compile(r"<<-?[ \t]*(?!<)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def blank_line(line):
    """Return (blanked_text, heredoc_delimiters_opened_by_this_line).

    Walks the line with an explicit mode stack. "code" is the default; "subst"
    is code inside `$(…)` or backticks and differs only in what ends it; "dq"
    and "sq" are the two string literals, and only "sq" is blanked wholesale.
    """
    out = []
    openers = []
    # Each frame: (mode, paren_depth). paren_depth only matters for "subst".
    stack = [["code", 0]]
    i = 0
    n = len(line)

    while i < n:
        mode = stack[-1][0]
        ch = line[i]

        if mode in ("code", "subst"):
            # A command substitution opens a nested code context in every mode
            # that can contain one.
            if line.startswith("$(", i):
                out.append("$(")
                stack.append(["subst", 0])
                i += 2
                continue
            if ch == "`":
                out.append("`")
                stack.append(["btick", 0])
                i += 1
                continue
            if mode == "subst":
                if ch == "(":
                    stack[-1][1] += 1
                    out.append(ch)
                    i += 1
                    continue
                if ch == ")":
                    if stack[-1][1] == 0:
                        stack.pop()
                    else:
                        stack[-1][1] -= 1
                    out.append(ch)
                    i += 1
                    continue
            # Heredoc redirection, consumed whole so its quotes are never
            # mistaken for a string literal.
            m = HEREDOC_AT.match(line, i)
            if m:
                openers.append(m.group(2))
                out.append(m.group(0))
                i = m.end()
                continue
            # A comment only ends the line at the OUTERMOST code level; inside
            # `$( … )` a `#` is still a comment, so treat it the same way and
            # stop — the rest of the line cannot be code either way.
            if ch == "#":
                break
            if ch == "'":
                out.append(ch)
                stack.append(["sq", 0])
                i += 1
                continue
            if ch == '"':
                out.append(ch)
                stack.append(["dq", 0])
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if mode == "btick":
            if ch == "`":
                stack.pop()
                out.append(ch)
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if mode == "sq":
            # Nothing expands inside single quotes, so the whole run is data.
            if ch == "'":
                stack.pop()
                out.append(ch)
            else:
                out.append(" ")
            i += 1
            continue

        # mode == "dq": literal runs are data, but substitutions are code.
        if ch == "\\" and i + 1 < n:
            out.append("  ")
            i += 2
            continue
        if line.startswith("$(", i):
            out.append("$(")
            stack.append(["subst", 0])
            i += 2
            continue
        if ch == "`":
            out.append("`")
            stack.append(["btick", 0])
            i += 1
            continue
        if ch == '"':
            stack.pop()
            out.append(ch)
            i += 1
            continue
        out.append(" ")
        i += 1

    return "".join(out), openers


def main():
    pending = []
    for raw in sys.stdin.read().split("\n"):
        line = raw.rstrip("\n")
        if pending:
            # Inside a heredoc body: all data. Accepting the delimiter either
            # bare or indented ends the body sooner than bash would for a
            # non-`<<-` heredoc, which can only un-hide code, never hide it.
            if line.strip() == pending[0]:
                pending.pop(0)
            print("")
            continue
        text, openers = blank_line(line)
        pending.extend(openers)
        print(text)


main()
