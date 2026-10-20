#!/usr/bin/env bash
# A hand-written adapter that is narrower than its payload loses fields in
# silence — there is no decoder to fail and no error to notice.
#
# ⛔ `Types.Book.fromProtoBook` builds the SPA's `Book` record field by field
# from the generated `Proto.Book`. The generated decoder reads every key on the
# wire correctly; the adapter then simply does not mention some of them. So a
# field can be serialised, decoded, and discarded, and no view can reference it
# because no record field exists to reference. Three fields were lost that way
# (`language`, `bisac_codes`, `community_read_count`) and nothing computed the
# difference, so the next proto field added to `Book` would have gone the same
# way on the day it landed.
#
# This is that set difference, in the direction that matters: a payload key with
# no adapter field. The reverse direction cannot happen — an adapter field with
# no payload key fails to compile.
#
# ⚠️ WHAT THIS GATE DOES NOT CHECK. An adapter field is not a rendered field.
# `community_read_count` below is the standing example: carrying it into the
# record would satisfy this gate and still render nowhere, which is the same
# defect one layer further in. Rendering is a design question and belongs to
# whoever owns the surface.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

SERIALISER = pathlib.Path("apps/core/lib/stacks_web/proto_json.ex")
ADAPTER = pathlib.Path("frontend/src/Types/Book.elm")

# Keys the detail payload carries that the adapter deliberately does not read.
# Each needs an owner, because "deliberately" is only true while somebody can
# say who decided it.
#
#   community_read_count — carrying this one into the record is a separate,
#   already-planned piece of work: reading it costs a per-request warehouse
#   query (`SELECT read_count FROM wh.mart_community_read_count WHERE
#   book_id = $1`), and the plan is to carry it through `Types.Book` AND render
#   it, which is a surface decision rather than an adapter fix. That is why it
#   was not absorbed here. ⚠️ When the adapter starts reading it, DELETE this
#   entry — the gate fails on a declared exception that no longer describes the
#   code, so the list cannot rot into a place things go to be forgotten.
DECLARED = {"community_read_count"}


def read(path):
    if not path.exists():
        print(f"FAIL: {path} not found", file=sys.stderr)
        raise SystemExit(1)
    return path.read_text(encoding="utf-8")


def strip_elixir_comments(src):
    # ⛔ Comments are not code, and this gate's sibling
    # (check-protojson-completeness.sh) was defeated by exactly this: a comment
    # written to explain a field's REMOVAL spelled the field, and the harvest
    # counted it as present. `#{` is interpolation and must survive.
    out = []
    for line in src.split("\n"):
        cleaned = []
        in_string = False
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"':
                in_string = not in_string
            elif ch == "#" and not in_string:
                if i + 1 < len(line) and line[i + 1] == "{":
                    cleaned.append(line[i:])
                    i = len(line)
                    continue
                break
            cleaned.append(ch)
            i += 1
        out.append("".join(cleaned))
    return "\n".join(out)


def strip_elm_comments(src):
    src = re.sub(r"\{-.*?-\}", "", src, flags=re.S)
    return "\n".join(line.split("--")[0] for line in src.split("\n"))


serialiser = strip_elixir_comments(read(SERIALISER))
adapter_src = strip_elm_comments(read(ADAPTER))

# ── The payload: what `ProtoJSON.book/2` puts on the wire ───────────────────
body = re.search(r"\n  def book\(book, opts.*?\n  end\n", serialiser, re.S)
if not body:
    print(f"FAIL: could not locate `def book(book, opts…)` in {SERIALISER}.", file=sys.stderr)
    print(
        "Every comparison below is a set difference, empty when the code is correct AND\n"
        "when nothing was parsed. A missing function body means the parse has drifted.",
        file=sys.stderr,
    )
    raise SystemExit(1)
body = body.group(0)

take = re.search(r"Map\.take\(\[(.*?)\]\)", body, re.S)
payload = set(re.findall(r":([a-z_0-9]+)", take.group(1))) if take else set()

merge = re.search(r"Map\.merge\(%\{(.*?)\}\)", body, re.S)
if merge:
    payload |= set(re.findall(r"^\s*([a-z_0-9]+):", merge.group(1), re.M))

# Keys helpers add after the pipe. Parsed from the whole module rather than the
# body, because the helper is a separate function.
payload |= set(re.findall(r"Map\.put\(payload, :([a-z_0-9]+)", serialiser))

# ── The adapter: what `fromProtoBook` reads off the proto record ────────────
adapter_body = re.search(r"\nfromProtoBook pb =\n(.*?)\n\n\n", adapter_src, re.S)
if not adapter_body:
    print(f"FAIL: could not locate `fromProtoBook pb =` in {ADAPTER}.", file=sys.stderr)
    raise SystemExit(1)

# Elm field names are camelCase; the wire is snake_case. Compare in snake_case.
reads = set(re.findall(r"\bpb\.([a-zA-Z0-9_]+)", adapter_body.group(1)))
adapter = {re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower() for name in reads}

# ── Anti-vacuity on both populations ────────────────────────────────────────
if len(payload) < 8:
    print(
        f"FAIL: parsed only {len(payload)} payload key(s) from {SERIALISER}.",
        file=sys.stderr,
    )
    print("The detail payload carries more than that; the parse has drifted.", file=sys.stderr)
    raise SystemExit(1)

if len(adapter) < 8:
    print(
        f"FAIL: parsed only {len(adapter)} adapter field(s) from {ADAPTER}.",
        file=sys.stderr,
    )
    print("`fromProtoBook` reads more than that; the parse has drifted.", file=sys.stderr)
    raise SystemExit(1)

dropped = sorted(payload - adapter - DECLARED)
stale = sorted(DECLARED - (payload - adapter))

failed = False

if dropped:
    failed = True
    print(
        f"FAIL: {len(dropped)} book payload key(s) the SPA adapter silently drops:",
        file=sys.stderr,
    )
    for key in dropped:
        print(f"  {key}", file=sys.stderr)
    print(
        "\n`Types.Book.fromProtoBook` builds the app record field by field, so a key it does\n"
        "not mention is decoded and thrown away — no decoder fails and no view can reference\n"
        "it, because no record field exists. Either carry the field into `Types.Book.Book`\n"
        "and `fromProtoBook`, or stop serialising it in `ProtoJSON.book/2`, or add it to\n"
        "DECLARED in this script WITH AN OWNER. The diff is the record that somebody decided.\n\n"
        "⚠️ Carrying a field is not rendering it. A record field nothing reads is the same\n"
        "defect one layer in, and this gate will not catch that one.",
        file=sys.stderr,
    )

if stale:
    failed = True
    print(
        f"FAIL: {len(stale)} DECLARED exception(s) no longer describe the code:",
        file=sys.stderr,
    )
    for key in stale:
        print(f"  {key}", file=sys.stderr)
    print(
        "\nThe adapter reads it now, or the payload stopped carrying it. Remove the entry —\n"
        "an exception list that keeps entries for nothing is how it stops being reviewable.",
        file=sys.stderr,
    )

if not failed:
    print(
        f"OK: {len(payload)} book payload key(s), {len(adapter)} read by the adapter, "
        f"{len(DECLARED)} declared exception(s)."
    )

raise SystemExit(1 if failed else 0)
PY
