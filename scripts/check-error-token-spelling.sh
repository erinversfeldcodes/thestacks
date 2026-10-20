#!/usr/bin/env bash
# Two spellings of one error token is a client that matches on one of them.
#
# ⛔ The wire's `error:` value is read by CODE. `Api.elm` matches
# `Ok "not_found"` and branches; nothing renders the value to a reader, because
# every surface maps a token to its own copy. So the token is an identifier, and
# an identifier with two spellings is one the next client will get wrong.
#
# Measured before this gate existed: **16 sites spelled it `"not found"` and 25
# spelled it `"not_found"`**, in the same codebase and twice in the same file.
# There was no live mismatch — the one client that switches on the token happened
# to call routes that used the underscore form — so the defect was latent, held
# by nothing but which routes that client called.
#
# ⚖️ THE RULE, from the owner (2026-10-20): **`not found` in user-facing
# messages, `not_found` in code and internal systems.** So:
#
#   * a wire token in `%{error: …}` is code-facing → `snake_case`;
#   * the sentence a reader sees is copy, and lives in the SPA — `Page/Profile`
#     renders "Reader not found" in an `h1`, which is correct and is why
#     converting the server token was safe;
#   * a human-readable SENTENCE in an `error:` field (the partner API's "The
#     provided email address is not valid.") is a message, not a token, and this
#     gate does not touch it. Deciding which of those 63 should become
#     token-plus-message is a contract change and is tracked separately.
#
# WHAT IS ENFORCED, therefore, is the narrow decidable thing: **no two literal
# spellings of the same token.** Normalise case and separators; fail when one
# normalised token has more than one spelling on the wire. That catches the 17th
# `"not found"`, and any future `already member` / `already_member` pair, without
# asking this script to judge prose.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path("apps/core/lib")

# A token's canonical form: lowercased, runs of whitespace or underscore
# collapsed to one underscore. `"Bookshelf not found"`, `"bookshelf not found"`
# and `"bookshelf_not_found"` are one token spelled three ways.
def canonical(token):
    return re.sub(r"[\s_]+", "_", token.strip().lower())


# ⚠️ Interpolated values are skipped, not normalised. `"Forbidden — #{role}
# role required"` has no fixed spelling to compare, and treating the literal
# fragments as a token would invent a vocabulary entry that never reaches a
# client. They are counted so the skip is visible rather than silent.
INTERPOLATED = re.compile(r"#\{")

spellings = collections.defaultdict(set)
sites = collections.defaultdict(list)
interpolated = 0

if not ROOT.exists():
    print(f"FAIL: {ROOT} not found", file=sys.stderr)
    raise SystemExit(1)

for path in sorted(ROOT.rglob("*.ex")):
    if "/gen/" in str(path):
        continue
    for lineno, line in enumerate(path.read_text(encoding="utf-8").split("\n"), 1):
        for match in re.finditer(r'error:\s*"([^"]*)"', line):
            token = match.group(1)
            if INTERPOLATED.search(token):
                interpolated += 1
                continue
            key = canonical(token)
            spellings[key].add(token)
            sites[key].append((str(path).replace("apps/core/lib/", ""), lineno, token))

# ⛔ ANTI-VACUITY. The verdict is "no key has two spellings", which is true both
# when the code is consistent AND when nothing was harvested. This codebase has
# well over a hundred distinct error tokens; a handful means the regex no longer
# matches how responses are written.
MIN_TOKENS = 60
if len(spellings) < MIN_TOKENS:
    print(
        f"FAIL: harvested only {len(spellings)} error token(s) from {ROOT} "
        f"(floor {MIN_TOKENS}).",
        file=sys.stderr,
    )
    print(
        "The check below passes when no token has two spellings, which is also what an\n"
        "empty harvest looks like. A count this low means `error: \"…\"` is no longer how\n"
        "these responses are written, not that the drift was fixed.",
        file=sys.stderr,
    )
    raise SystemExit(1)

drifted = {key: value for key, value in spellings.items() if len(value) > 1}

if drifted:
    print(
        f"FAIL: {len(drifted)} error token(s) are spelled more than one way on the wire:",
        file=sys.stderr,
    )
    for key in sorted(drifted):
        print(f"\n  {key}", file=sys.stderr)
        for path, lineno, token in sorted(sites[key]):
            print(f"      {token!r:<34} {path}:{lineno}", file=sys.stderr)
    print(
        "\nThe `error:` value is an identifier — `Api.elm` matches on it and branches, and\n"
        "no surface renders it, because each maps the token to its own copy. Two spellings\n"
        "is a client that matches one of them, and which one is luck.\n\n"
        "⚖️ The rule: `not found` in user-facing messages, `not_found` in code and internal\n"
        "systems. A wire token is code-facing, so pick the snake_case spelling and convert\n"
        "the others. If what you have is a reader-facing SENTENCE rather than a token, it\n"
        "does not belong in a field a client switches on.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: {len(spellings)} error token(s) on the wire, each spelled one way "
    f"({interpolated} interpolated value(s) skipped)."
)
PY
