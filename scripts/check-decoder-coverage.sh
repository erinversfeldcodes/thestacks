#!/usr/bin/env bash
# A decoder no test ever feeds JSON to is an unverified claim about the server.
#
# `Decode.field "x" Decode.string` is not a parsing detail — it is a REQUIREMENT:
# the server must always send `x`, and must never send null there. Nothing in the
# build ties that requirement to the server, and `Decode.list` fails whole, so one
# row with a null in a required field replaces an entire surface with a transport
# error.
#
# ⛔ That is the defect this gate exists for, and it happened twice before anyone
# wrote a test. `blockedUserDecoder` required a non-null `display_name` while the
# query selected it raw, so ONE blocked reader with no name permanently broke the
# only surface whose purpose is unblocking people. `groupMemberDecoder` had the
# same shape and had been fixed server-side earlier with no test, which is exactly
# why the fix never travelled to its sibling. Both lived in a set of 24 decoders
# no test had ever fed.
#
# The set is empty now. This keeps it empty.
#
# ⚠️ WHAT THIS GATE DOES NOT CLAIM. Feeding a decoder JSON proves it accepts a
# shape somebody wrote down; it does not prove the server sends that shape. The
# fixtures in frontend/tests/ApiDecoderContractTest.elm each name the serialiser
# they were read from, and that provenance is the part a reviewer has to check —
# a fixture written from the decoder instead of the server passes this gate and
# proves nothing. One such fixture was caught during that file's own first run.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

API = pathlib.Path("frontend/src/Api.elm")
TESTS = pathlib.Path("frontend/tests")

# The floor below is a parse-drift alarm, not a target. Api.elm defines 66
# decoders today; if this derivation suddenly sees a handful, the regex has
# drifted and every set difference under it would read as clean.
MIN_DECODERS = 40

if not API.exists():
    print(f"FAIL: {API} not found", file=sys.stderr)
    raise SystemExit(1)

src = API.read_text(encoding="utf-8")
lines = src.split("\n")

# A DECODER is a top-level value whose signature is `name : Decoder X`.
#
# ⚠️ Signatures containing `->` are EXCLUDED: those take a decoder rather than
# being one — a response resolver, a combinator. Without that exclusion the
# population was overstated by two (`resolveJson`, `andMap`), and one of them
# sat in the untested list inflating it.
sig = re.compile(r"^([a-z][A-Za-z0-9_]*)\s*:\s*Decoder\b([^\n]*)$")
decoders = []
for line in lines:
    m = sig.match(line)
    if m and "->" not in m.group(2):
        decoders.append(m.group(1))
decoders = sorted(set(decoders))

if len(decoders) < MIN_DECODERS:
    print(
        f"FAIL: parsed only {len(decoders)} decoder(s) from {API} (floor {MIN_DECODERS}).",
        file=sys.stderr,
    )
    print(
        "Every check below is a set difference, which is empty when the code is correct\n"
        "AND when nothing was parsed. A count this low means the signature regex no\n"
        "longer matches this file, not that the decoders went away.",
        file=sys.stderr,
    )
    raise SystemExit(1)

# Each decoder's body runs from its signature to the next TOP-LEVEL binding of
# any kind. Slicing decoder-to-decoder instead sweeps the request helpers
# between them into the body and attributes their field names to the decoder.
top = re.compile(r"^([a-z][A-Za-z0-9_]*)\s*(?::|=|[a-zA-Z(])")
anchors = [(m.group(1), i) for i, line in enumerate(lines) if (m := top.match(line))]

bodies = {}
for idx, (name, start) in enumerate(anchors):
    if name not in decoders or name in bodies:
        continue
    end = len(lines)
    for other, j in anchors[idx + 1:]:
        if other != name:
            end = j
            break
    bodies[name] = "\n".join(lines[start:end])

if not TESTS.exists():
    print(f"FAIL: {TESTS} not found", file=sys.stderr)
    raise SystemExit(1)

test_src = "\n".join(p.read_text(encoding="utf-8") for p in sorted(TESTS.rglob("*.elm")))
if not test_src.strip():
    print(f"FAIL: no Elm test sources read from {TESTS}", file=sys.stderr)
    raise SystemExit(1)


def mentions(haystack, name):
    return re.search(r"\b" + re.escape(name) + r"\b", haystack) is not None


direct = {n for n in decoders if mentions(test_src, n)}

# A decoder fed through its parent IS fed: `Decode.list childDecoder` inside a
# tested parent receives the same JSON. So the covered set is the transitive
# closure over decoder references in tested bodies, not just the named ones.
reachable = set(direct)
frontier = list(direct)
while frontier:
    cur = frontier.pop()
    body = bodies.get(cur, "")
    for other in decoders:
        if other in reachable or other == cur:
            continue
        if mentions(body, other):
            reachable.add(other)
            frontier.append(other)

never = sorted(set(decoders) - reachable)

if never:
    print(
        f"FAIL: {len(never)} decoder(s) in {API} are fed JSON by no test:",
        file=sys.stderr,
    )
    for name in never:
        print(f"  {name}", file=sys.stderr)
    print(
        "\nEach one is a requirement on the server that nothing checks: a required field\n"
        "the server can omit, or a non-nullable field it can send null in, fails the decode\n"
        "of the WHOLE response — and `Decode.list` fails whole, so one bad row empties a\n"
        "surface. Two such defects shipped that way before this set was emptied.\n\n"
        "Add a case to frontend/tests/ApiDecoderContractTest.elm. ⚠️ Derive the fixture from\n"
        "the SERVER — the controller or ProtoJSON function that answers the endpoint — and\n"
        "name it in a comment. A fixture written from the decoder passes this gate and\n"
        "proves only that the decoder agrees with itself.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK: all {len(decoders)} Api.elm decoder(s) are fed JSON by a test "
    f"({len(direct)} named directly, {len(reachable) - len(direct)} through a parent)."
)
PY
