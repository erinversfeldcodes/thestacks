#!/usr/bin/env python3
"""
Fail the build when an Elixir consumer stops handling a proto enum value.

## Why this exists

Proto enums reach Elm as a closed custom type, so adding a value breaks every Elm
`case` until it is handled. They reach Elixir as a bare string, so consumers match
on string literals behind a mandatory catch-all — and a missed clause is invisible
to the compiler, to `mix proto.sync --check`, and to the test suite.

Commit f28c032e added `SCRAPE_OUTCOME_RATE_LIMITED` to proto, to the Rust scraper,
and to two of the three Elixir files that interpret the outcome. The third,
`trigger_price_scrape_job.ex`, silently routed it into its catch-all and treated a
shop politely pacing us as an unrecognised failure. `price_snapshots` sat at zero
rows for three campaigns while every gate stayed green.

This check closes that hole from the outside: it finds every hand-written Elixir
file that matches on an enum's wire values and asserts the matched set covers the
whole enum.

## What counts as a consumer

Any file under `apps/core/lib` (excluding generated code) containing at least one
double-quoted literal equal to one of that enum's wire values. Consumers are
discovered, not registered, so a new one is covered the day it is written.

## Declaring a deliberate omission

Not every consumer must handle every value — but the omission has to be a
statement someone can review, not an absence. Declare it in the consuming file:

    # proto-enum-coverage: ScrapeOutcome ignore SCRAPE_OUTCOME_NOT_STOCKED,
    #   SCRAPE_OUTCOME_ROBOTS_BLOCKED — determinations, not service faults; they
    #   melt nothing and this module only decides what melts the fuse.

The directive lives beside the code it excuses, so it turns up in the diff that
creates the gap and in the diff that would have to widen it. A reason is
mandatory. Undeclared omissions, and declarations naming a value that is not
actually missing (or no longer exists), both fail.

## The one global exemption

A proto3 enum's zero value (`*_UNSPECIFIED`) is exempt everywhere. proto3 requires
it to exist as the unset sentinel; it is never a determination a service makes, so
handling it is the catch-all's job. This exemption is announced on every run rather
than applied silently.

Usage:
    python3 scripts/check-enum-coverage.py           # fail on any undeclared gap
    python3 scripts/check-enum-coverage.py --report  # print the inventory, never fail
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SEARCH_ROOTS = [REPO_ROOT / "apps/core/lib"]
# Generated code is derived from the same proto and cannot drift from it.
EXCLUDED_PATH_PARTS = ("/gen/",)

# `# proto-enum-coverage: <Enum> ignore <VALUE>[, <VALUE>...] — <reason>`
#
# A directive may wrap across consecutive comment lines (proto value names are long
# and credo caps line length), so the lines are joined before matching. Only
# `[A-Z0-9_, ]` is accepted between `ignore` and the em-dash: prose there makes the
# whole directive fail to parse, which leaves the gap undeclared and fails the
# build. Ambiguity fails closed.
DIRECTIVE_START_RE = re.compile(r"^\s*#.*proto-enum-coverage:")
COMMENT_LINE_RE = re.compile(r"^\s*#")
DIRECTIVE_RE = re.compile(
    r"proto-enum-coverage:\s*(?P<enum>\w+)\s+ignore\s+(?P<values>[A-Z0-9_,\s]+?)"
    r"\s*(?:—|--)\s*(?P<reason>\S.*)$"
)
# A wire value used as an Elixir string literal.
LITERAL_RE = re.compile(r'"([A-Z][A-Z0-9_]*)"')


def _load_generator_module():
    """Import scripts/gen_python_proto.py — it owns descriptor loading and enum walking."""
    path = REPO_ROOT / "scripts" / "gen_python_proto.py"
    spec = importlib.util.spec_from_file_location("stacks_gen_proto", path)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        print(f"ERROR: cannot import {path}", file=sys.stderr)
        sys.exit(1)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_enums() -> dict[str, dict]:
    """{EnumName: {"values": [...], "zero": "..."} } — the same list `values/0` exposes."""
    gen = _load_generator_module()
    descriptor = gen.load_descriptor()
    enums: dict[str, dict] = {}
    for entry in gen._collect_all_enums(descriptor):
        enum = entry["enum"]
        values = enum.get("value", [])
        zero = next((v["name"] for v in values if v.get("number", 0) == 0), None)
        enums[enum["name"]] = {
            "values": [v["name"] for v in values],
            "zero": zero,
            "proto_file": entry["proto_file"],
        }
    return enums


def source_files() -> list[Path]:
    files: list[Path] = []
    for root in SEARCH_ROOTS:
        for path in sorted(root.rglob("*.ex")):
            posix = path.as_posix()
            if any(part in posix for part in EXCLUDED_PATH_PARTS):
                continue
            files.append(path)
    return files


def _directive_blocks(text: str) -> list[str]:
    """Each directive as one logical line, joining the comment lines it wraps onto."""
    lines = text.splitlines()
    blocks: list[str] = []
    i = 0
    while i < len(lines):
        if not DIRECTIVE_START_RE.match(lines[i]):
            i += 1
            continue
        parts = [lines[i].lstrip().lstrip("#").strip()]
        j = i + 1
        # Absorb the continuation, but never a second directive — two adjacent
        # declarations must stay two declarations.
        while (
            j < len(lines)
            and COMMENT_LINE_RE.match(lines[j])
            and not DIRECTIVE_START_RE.match(lines[j])
        ):
            parts.append(lines[j].lstrip().lstrip("#").strip())
            j += 1
        blocks.append(" ".join(p for p in parts if p))
        i = j
    return blocks


def parse_directives(text: str) -> dict[str, dict[str, str]]:
    """{EnumName: {VALUE: reason}} declared in this file."""
    declared: dict[str, dict[str, str]] = {}
    for block in _directive_blocks(text):
        match = DIRECTIVE_RE.search(block)
        if not match:
            continue
        enum_name = match.group("enum")
        reason = match.group("reason").strip()
        values = [v.strip() for v in match.group("values").split(",") if v.strip()]
        for value in values:
            declared.setdefault(enum_name, {})[value] = reason
    return declared


def analyse(enums: dict[str, dict]) -> tuple[list[dict], list[str]]:
    """Returns (per-consumer findings, hard errors)."""
    value_owner: dict[str, str] = {}
    for enum_name, meta in enums.items():
        for value in meta["values"]:
            value_owner.setdefault(value, enum_name)

    findings: list[dict] = []
    errors: list[str] = []

    for path in source_files():
        text = path.read_text()
        rel = path.relative_to(REPO_ROOT).as_posix()
        declared = parse_directives(text)

        matched: dict[str, set[str]] = {}
        for literal in LITERAL_RE.findall(text):
            enum_name = value_owner.get(literal)
            if enum_name:
                matched.setdefault(enum_name, set()).add(literal)

        # A directive for an enum this file does not consume is dead weight that
        # would outlive the code it excused.
        for enum_name, ignores in declared.items():
            if enum_name not in enums:
                errors.append(f"{rel}: ignore declared for unknown enum '{enum_name}'")
                continue
            if enum_name not in matched:
                errors.append(
                    f"{rel}: ignore declared for '{enum_name}', but this file matches "
                    "none of its values — remove the stale directive"
                )
                continue
            unknown = sorted(set(ignores) - set(enums[enum_name]["values"]))
            for value in unknown:
                errors.append(f"{rel}: ignore names '{value}', which is not a value of {enum_name}")

        for enum_name, seen in sorted(matched.items()):
            meta = enums[enum_name]
            ignores = declared.get(enum_name, {})
            required = set(meta["values"]) - seen
            if meta["zero"]:
                required.discard(meta["zero"])

            # An ignore for a value the file already handles is a lie about the code.
            redundant = sorted(set(ignores) & seen)
            for value in redundant:
                errors.append(
                    f"{rel}: ignore names '{value}' for {enum_name}, but the file "
                    "handles it — remove the directive"
                )

            missing = sorted(required - set(ignores))
            findings.append(
                {
                    "file": rel,
                    "enum": enum_name,
                    "handled": sorted(seen),
                    "ignored": {k: v for k, v in sorted(ignores.items())},
                    "missing": missing,
                    "total": len(meta["values"]),
                }
            )

    return findings, errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        action="store_true",
        help="Print the full consumer inventory and exit 0 regardless of gaps.",
    )
    args = parser.parse_args()

    enums = load_enums()
    findings, errors = analyse(enums)

    print(
        f"==> Proto enum consumer coverage: {len(enums)} enums, "
        f"{len(findings)} consumer/enum pairs under apps/core/lib"
    )
    print("    Zero values (*_UNSPECIFIED) are exempt everywhere — proto3 unset sentinels.")

    gaps = [f for f in findings if f["missing"]]

    if args.report:
        for finding in findings:
            print(
                f"\n  {finding['file']}\n    {finding['enum']}: "
                f"{len(finding['handled'])}/{finding['total']} handled"
            )
            for value, reason in finding["ignored"].items():
                print(f"      ignored: {value} — {reason}")
            for value in finding["missing"]:
                print(f"      MISSING: {value}")
        return

    # One line per declaration, not per value: the reason is shared, and repeating a
    # paragraph five times is how an ignore-list stops being read.
    for finding in findings:
        if finding["ignored"]:
            values = ", ".join(finding["ignored"])
            print(f"    declared-ignore: {finding['file']} {finding['enum']}: {values}")

    for message in errors:
        print(f"ERROR: {message}", file=sys.stderr)

    for finding in gaps:
        print(
            f"\nFAIL: {finding['file']} matches on {finding['enum']} but does not "
            f"handle:\n      " + "\n      ".join(finding["missing"]),
            file=sys.stderr,
        )
        print(
            "      Handle each value, or declare the omission in that file:\n"
            f"        # proto-enum-coverage: {finding['enum']} ignore "
            f"{finding['missing'][0]} — <why>",
            file=sys.stderr,
        )

    if gaps or errors:
        print(
            f"\n{len(gaps)} unhandled-value gap(s), {len(errors)} directive error(s).",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"OK: every consumer covers its enum ({len(findings)} pair(s) checked).")


if __name__ == "__main__":
    main()
