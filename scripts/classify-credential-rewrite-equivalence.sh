#!/usr/bin/env bash
# Every credential rewrite in the one-builder migration, classified against a
# table of equivalences.
#
# ⛔ WHY THIS EXISTS AND WHY IT IS HISTORICAL. The migration took 71 inline
# `Authorization` derivations onto `Api.requestHeaders` across three commits,
# and the claim that needs evidence is that **each site sends the same request
# it sent before**. The ratchet proves the count went to zero; it says nothing
# about whether any individual rewrite changed behaviour.
#
# ⚖️ So this works per SITE rather than per commit: for every request function
# it reads the `headers =` expression before and after, and classifies each
# change against a table of rewrites that are equivalence-preserving by
# construction. Anything outside the table is a failure, not a shrug.
#
# ⚠️ ITS CORPUS IS THREE FIXED COMMITS, so it is evidence rather than a gate and
# nothing invokes it in CI. This answers a question that can only be asked once.
#
# ⚖️ UPDATED 2026-11-07: the standing protection USED to be
# `check-credential-origin.sh` plus `frontend/tests/ApiRequestHeadersTest.elm`.
# The first is deleted — every request in the client is now a `RequestSpec` whose
# `url` is an `Api.Url.SameOriginUrl`, so the origin property is the compiler's
# rather than a parser's. The header half is still covered by that test, which
# does run.
#
# ⚠️ IT HAS BEEN SEEN RED. On its first real run it refused the `ListingDetail`
# site, whose rewrite writes out `httpHeaders`' body at a call site outside
# `Api.elm` — a form the table did not yet carry. That rewrite is equivalent and
# is now listed; the point is that the classifier rejected a shape it had not
# been told about rather than passing it.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/.." && pwd))"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import re
import subprocess
import sys

COMMITS = [
    ("59feef17", "batch 1 - ListingDetail.elm"),
    ("db7b9e4b", "batches 2-7 - Api.elm, 70 sites"),
    ("bd66a07c", "batch 8 - the four declared absences"),
]

# (old expression, new expression, why they yield the same header list).
# Matched against the whitespace-normalised expression, with `\1` in the new
# pattern bound to the token name captured from the old one.
PERMITTED = [
    (
        r'^\[ Http\.header "Authorization" \("Bearer " \+\+ (\w+)\) \]$',
        r"^httpHeaders SameOrigin \(Session \1\)$",
        "Session yields exactly this list (ApiRequestHeadersTest.elm)",
    ),
    (
        r"^case (\w+) of Just \w+ -> "
        r'\[ Http\.header "Authorization" \("Bearer " \+\+ \w+\) \] Nothing -> \[\]$',
        r"^httpHeaders SameOrigin \(Optional \1\)$",
        "Optional is this case expression (both branches asserted)",
    ),
    (
        # Outside `Api.elm` the builder is reached qualified, and `httpHeaders`'
        # body is written out: it IS `requestHeaders >> List.map Http.header`.
        r"^case (\w+) of Just \w+ -> "
        r'\[ Http\.header "Authorization" \("Bearer " \+\+ \w+\) \] Nothing -> \[\]$',
        r"^Api\.requestHeaders Api\.SameOrigin \(Api\.Optional \1\) "
        r"\|> List\.map \(\\\( name, value \) -> Http\.header name value\)$",
        "Optional, with httpHeaders' body written out at a call site outside Api.elm",
    ),
    (
        r"^\[\]$",
        r"^httpHeaders SameOrigin NoCredential$",
        "NoCredential yields [] - the empty list restated as a declaration",
    ),
    (
        r"^\[\]$",
        r"^httpHeaders CrossOrigin NoCredential$",
        "CrossOrigin returns [] before the credential is read",
    ),
    (
        r"^(authedHeaders|authHeaders) (\w+)$",
        r"^\1 \2$",
        "unchanged at the call site; the helper itself now delegates",
    ),
]

FILES = ["frontend/src/Api.elm", "frontend/src/Page/Marketplace/ListingDetail.elm"]


def show(sha, path):
    r = subprocess.run(["git", "show", f"{sha}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def strip_comments(text):
    """Blank Elm comments, keeping line structure."""
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


def sites(text):
    """function name -> normalised `headers =` expression, for each request."""
    lines = strip_comments(text).split("\n")
    found, current = {}, "?"
    for idx, line in enumerate(lines):
        m = re.match(r"^([a-z][A-Za-z0-9_']*)\s*:", line)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"^(\s*),?\s*headers\s*=\s*(.*)$", line)
        if not m:
            continue
        indent, rest = len(m.group(1)), m.group(2)
        buf = [rest]
        for nxt in lines[idx + 1 :]:
            if not nxt.strip():
                continue
            lead = len(nxt) - len(nxt.lstrip())
            if lead <= indent:
                break
            buf.append(nxt.strip())
        expr = re.sub(r"\s+", " ", " ".join(buf)).strip()
        # A function may hold more than one request; key by occurrence.
        key = current
        bump = 2
        while key in found:
            key = f"{current}#{bump}"
            bump += 1
        found[key] = expr
    return found


def classify(old, new):
    for old_pat, new_pat, why in PERMITTED:
        m = re.match(old_pat, old)
        if not m:
            continue
        pat = new_pat
        for g, value in enumerate(m.groups(), start=1):
            pat = pat.replace(f"\\{g}", re.escape(value))
        if re.match(pat, new):
            return why
    return None


# ⛔ A FLOOR ON SITES CLASSIFIED, not on findings. `sites()` is a text parser
# over three historical revisions of `Api.elm`; if it drifted it would report
# zero changed sites and print "every changed site is permitted", which is the
# same output as a clean run. The number is EXACT rather than a minimum because
# the corpus is three fixed commits — it cannot legitimately change.
EXPECTED_CHANGED_SITES = 74

total, unclassified = 0, []

for sha, label in COMMITS:
    print(f"\n{label}  ({sha})")
    counts = {}
    for path in FILES:
        before, after = sites(show(f"{sha}^", path)), sites(show(sha, path))
        for name, old in before.items():
            new = after.get(name)
            if new is None or new == old:
                continue
            total += 1
            why = classify(old, new)
            if why is None:
                unclassified.append((sha, path, name, old, new))
            else:
                counts[why] = counts.get(why, 0) + 1
    for why, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:3d}  {why}")
    if not counts:
        print("    (no headers expression changed)")

print(f"\n{total} changed site(s) classified across {len(COMMITS)} commit(s).")

if total != EXPECTED_CHANGED_SITES:
    print(
        f"\nFAIL: classified {total} changed site(s); expected exactly "
        f"{EXPECTED_CHANGED_SITES}.",
        file=sys.stderr,
    )
    print(
        "      The corpus is three fixed commits, so this number cannot change for a\n"
        "      legitimate reason. FEWER means the parser stopped seeing sites, and a\n"
        "      verdict over a corpus it never read is indistinguishable from a clean one.",
        file=sys.stderr,
    )
    sys.exit(1)

if unclassified:
    print(f"\nFAIL: {len(unclassified)} rewrite(s) are not a known equivalence:")
    for sha, path, name, old, new in unclassified:
        print(f"  {sha}  {path}  {name}")
        print(f"       old: {old[:110]}")
        print(f"       new: {new[:110]}")
    sys.exit(1)

print("Every changed site is one of the permitted equivalences.")
PY
