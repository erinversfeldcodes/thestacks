#!/usr/bin/env bash
# The session is never written to, or read from, browser storage.
#
# ⛔ WHY THIS EXISTS, and why a grep in a DoD was not enough. The SPA used to
# keep a `stacks-auth` blob in `localStorage`: the Guardian token plus a copy of
# the reader's identity, written by a `saveAuth` port on every login and token
# rotation, read back into the app's state at boot. Two defects came out of that
# and neither was reachable while the copy existed:
#
#   * the identity went STALE. A role changed server-side stayed wrong in the
#     copy until the reader signed out and in again, because a cache with no
#     invalidation channel is a guess with a timestamp;
#   * the credential was READABLE BY ANY SCRIPT on the page, which is the
#     exposure the httpOnly cookie transport exists to close. A cookie the
#     document cannot read is worth nothing if the same token also sits in
#     `localStorage` beside it.
#
# All of it was deleted. ⚠️ The deletion was evidenced by a COUNT — twenty-one
# symbols at zero — and this project has recorded what a count is worth: a fact
# about the past, with nothing preventing a twenty-second. Re-adding a session to
# storage is a two-line change that no other gate sees, every test stays green,
# and the symptom (a stale role, or an XSS that is suddenly worth mounting) does
# not appear until long after the commit.
#
# ⚖️ So the invariant is not "the old symbols are gone". It is "no session
# reaches browser storage", which is a property a gate can hold.
#
# ⚠️ WHAT IS DELIBERATELY ALLOWED. `localStorage` itself is fine and still used:
# the onboarding-completed flag and the marketplace listing draft both live
# there. This gate is about CREDENTIALS and IDENTITY, not about storage.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

ELM_SRC="${1:-frontend/src}"
APP_JS="${2:-apps/core/assets/js/app.js}"

for target in "$ELM_SRC" "$APP_JS"; do
    if [[ ! -e "$target" ]]; then
        echo "FAIL: $target not found, so this gate cannot look." >&2
        exit 1
    fi
done

python3 - "$ELM_SRC" "$APP_JS" <<'PY'
import os
import re
import sys

elm_root, app_js = sys.argv[1], sys.argv[2]

# ⛔ A FLOOR ON WHAT WAS READ, not on what was found. A glob that stopped
# matching reports "no stored session" over a corpus it never opened, which is
# byte-identical to a clean run.
MIN_ELM_FILES = 80
MIN_APP_JS_LINES = 100

# The storage key the session used to live under, and the port names that moved
# it. Any of them reappearing means the blob is back under its own name.
BANNED_NAMES = [
    (re.compile(r'"stacks-auth"'), 'the "stacks-auth" storage key'),
    (re.compile(r"\bport\s+saveAuth\b"), "the saveAuth port"),
    (re.compile(r"\bport\s+clearAuth\b"), "the clearAuth port"),
    (re.compile(r"\bport\s+authChanged\b"), "the authChanged port"),
    (re.compile(r"\bport\s+requestStoredAuth\b"), "the requestStoredAuth port"),
    (re.compile(r"\bport\s+gotStoredAuth\b"), "the gotStoredAuth port"),
]

# ⛔ AND THE SHAPE, not just the name. A blob under `stacks-session` would clear
# every check above and be the same defect, so `app.js` is also read for a
# storage write whose value mentions a token or a session.
SUSPECT_WRITE = re.compile(
    r"""(localStorage|sessionStorage)\s*\.\s*setItem\s*\(\s*["'][^"']*"""
    r"""(auth|session|token|credential|jwt)[^"']*["']""",
    re.I,
)
SUSPECT_READ = re.compile(
    r"""(localStorage|sessionStorage)\s*\.\s*getItem\s*\(\s*["'][^"']*"""
    r"""(auth|session|token|credential|jwt)[^"']*["']""",
    re.I,
)


def strip_elm_comments(text):
    """Blank Elm comments, keeping line structure so line numbers stay true.

    ⛔ REQUIRED. This gate's subject matter IS its keywords, so every comment
    explaining the deletion names the thing it deleted — including the ones
    this change deliberately left in place as history ("a `stacks-auth` write
    used to fire a `storage` event..."). A sibling gate shipped without this
    and reported the comment explaining why a pattern was banned as an instance
    of the pattern.
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


def strip_js_comments(text):
    """Blank JS line and block comments, keeping line structure.

    Same reason as the Elm stripper: `app.js` carries a paragraph explaining
    that the boot flags no longer contain a session, and it names the key.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


violations = []

elm_files = []
for dirpath, _dirnames, filenames in os.walk(elm_root):
    for name in sorted(filenames):
        if name.endswith(".elm"):
            elm_files.append(os.path.join(dirpath, name))

if len(elm_files) < MIN_ELM_FILES:
    print(
        "FAIL: read %d Elm file(s) under %s, expected at least %d. The gate "
        "looked at almost nothing, which reports clean for the wrong reason."
        % (len(elm_files), elm_root, MIN_ELM_FILES)
    )
    raise SystemExit(1)

for path in elm_files:
    with open(path, encoding="utf-8") as handle:
        stripped = strip_elm_comments(handle.read())
    for lineno, line in enumerate(stripped.splitlines(), 1):
        for pattern, label in BANNED_NAMES:
            if pattern.search(line):
                violations.append((path, lineno, label, line.strip()))

with open(app_js, encoding="utf-8") as handle:
    app_js_text = handle.read()

app_js_lines = app_js_text.count("\n")
if app_js_lines < MIN_APP_JS_LINES:
    print(
        "FAIL: %s is %d line(s), expected at least %d. Either the file moved or "
        "this gate is reading a stub."
        % (app_js, app_js_lines, MIN_APP_JS_LINES)
    )
    raise SystemExit(1)

stripped_js = strip_js_comments(app_js_text)
for lineno, line in enumerate(stripped_js.splitlines(), 1):
    for pattern, label in BANNED_NAMES:
        if pattern.search(line):
            violations.append((app_js, lineno, label, line.strip()))
    if SUSPECT_WRITE.search(line):
        violations.append(
            (app_js, lineno, "a browser-storage WRITE under a session-shaped key", line.strip())
        )
    if SUSPECT_READ.search(line):
        violations.append(
            (app_js, lineno, "a browser-storage READ under a session-shaped key", line.strip())
        )

if violations:
    print("The session has been put back into browser storage:")
    print()
    for path, lineno, label, line in violations:
        print("  %s:%d" % (path, lineno))
        print("    %s" % label)
        print("    %s" % line[:140])
        print()
    print(
        "The session is an HttpOnly cookie. A copy in localStorage is readable by\n"
        "any script on the page, which is the exposure the cookie exists to close,\n"
        "and a copy of the IDENTITY goes stale the moment anything changes\n"
        "server-side. Identity comes from GET /api/auth/me; the credential comes\n"
        "from the cookie and the SPA never sees it."
    )
    raise SystemExit(1)

print(
    "OK: no session in browser storage (%d Elm file(s) + %s, %d lines)."
    % (len(elm_files), app_js, app_js_lines)
)
PY
