#!/usr/bin/env python3
"""Digit-beam false-accept rate: the load-bearing unknown for a barcode rescue.

The proposed rescue beams k digit-variants over OCR confusions and keeps the
checksum-valid ones. The checksum is strong against SINGLE errors — a lone
substitution can never keep an ISBN-13 valid (delta*weight is never ≡ 0 mod 10
for delta 1-9, weight ∈ {1,3}) — so the real exposure is:

  - PAIRS of confusions whose weighted deltas cancel mod 10, and
  - adjacent transpositions where |a-b| = 5 (the classic ISBN-13 blind spot).

A variant that is checksum-valid AND resolves in the catalogue is a FALSE
ACCEPT: a reader photographing one book would be handed another, through every
existing guard. This script measures that rate offline against Open Library,
using the eval corpus's 27 known-good ISBNs as the population.

⚠️ UNAVAILABLE IS NOT NOT-FOUND (the resolver's own lesson): an HTTP failure is
counted separately, and the run REFUSES to print a rate when failures exceed
10% — a rate computed over an outage would read as safety and mean nothing.

stdlib-only; rate-limited to 1 request / 0.4s. Run:
    python3 scripts/characterise/digit-beam-false-accept.py [--limit-per-isbn N]
"""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "apps/core/priv/eval/vision_corpus.exs"

# Digit pairs an OCR engine plausibly confuses on a printed barcode caption.
CONFUSIONS = {
    "0": "8",
    "8": "0",
    "1": "7",
    "7": "1",
    "3": "8",
    "5": "6",
    "6": "5",
    "2": "7",
    "9": "4",
    "4": "9",
}

WEIGHTS = [1, 3] * 6 + [1]  # ISBN-13 positional weights


def checksum_ok(isbn: str) -> bool:
    if len(isbn) != 13 or not isbn.isdigit():
        return False
    return sum(int(d) * w for d, w in zip(isbn, WEIGHTS, strict=True)) % 10 == 0


def corpus_isbns() -> list[str]:
    src = CORPUS.read_text()
    return sorted({m.group(1) for m in re.finditer(r'expect_isbn: "(\d{13})"', src)})


def confusion_pair_variants(isbn: str) -> set[str]:
    """Checksum-valid variants reachable by TWO simultaneous OCR confusions."""
    out: set[str] = set()
    digits = list(isbn)
    positions = [i for i, d in enumerate(digits) if d in CONFUSIONS]
    for a in range(len(positions)):
        for b in range(a + 1, len(positions)):
            i, j = positions[a], positions[b]
            cand = digits.copy()
            cand[i] = CONFUSIONS[cand[i]]
            cand[j] = CONFUSIONS[cand[j]]
            s = "".join(cand)
            if s != isbn and checksum_ok(s):
                out.add(s)
    return out


def transposition_variants(isbn: str) -> set[str]:
    """Adjacent transpositions the ISBN-13 checksum is blind to (|a-b| = 5)."""
    out: set[str] = set()
    for i in range(12):
        if isbn[i] != isbn[i + 1]:
            cand = list(isbn)
            cand[i], cand[i + 1] = cand[i + 1], cand[i]
            s = "".join(cand)
            if checksum_ok(s):
                out.add(s)
    return out


def ol_resolves(isbn: str) -> bool | None:
    """True/False = catalogue answer; None = transport failure (NOT an answer)."""
    url = f"https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=data"
    req = urllib.request.Request(url, headers={"User-Agent": "stacks-eval-harness"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.load(resp)
        return bool(body)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit-per-isbn", type=int, default=12)
    args = ap.parse_args()

    isbns = corpus_isbns()
    if not isbns:
        sys.exit("FAIL: no labelled ISBNs parsed from the corpus")

    rng = random.Random(26)  # deterministic sample across runs
    plan: list[tuple[str, str, str]] = []
    for isbn in isbns:
        pairs = sorted(confusion_pair_variants(isbn))
        trans = sorted(transposition_variants(isbn))
        variants = [("confusion_pair", v) for v in pairs] + [("transposition", v) for v in trans]
        if len(variants) > args.limit_per_isbn:
            variants = rng.sample(variants, args.limit_per_isbn)
        plan.extend((isbn, kind, v) for kind, v in variants)

    print(
        f"population: {len(isbns)} known-good ISBNs | "
        f"checksum-valid variants under test: {len(plan)}"
    )
    if not plan:
        sys.exit(
            "FAIL: zero checksum-valid variants generated — nothing measured. "
            "(That would itself be a finding; verify the generators.)"
        )

    accepted: list[tuple[str, str, str]] = []
    failures = 0
    for n, (orig, kind, variant) in enumerate(plan, 1):
        result = ol_resolves(variant)
        if result is None:
            failures += 1
        elif result:
            accepted.append((orig, kind, variant))
        if n % 25 == 0:
            print(f"  …{n}/{len(plan)} queried ({failures} transport failures)")
        time.sleep(0.4)

    answered = len(plan) - failures
    if failures > len(plan) * 0.10:
        sys.exit(
            f"REFUSED: {failures}/{len(plan)} lookups failed in transport — a "
            "false-accept rate over an outage is not a measurement. Re-run."
        )

    print(f"\nanswered: {answered}/{len(plan)} (transport failures: {failures})")
    print(f"FALSE ACCEPTS: {len(accepted)}/{answered}")
    for orig, kind, variant in accepted:
        print(f"  {orig} --{kind}--> {variant}  (resolves as a DIFFERENT real book)")
    if answered:
        print(f"rate: {len(accepted) / answered:.3f}")
    print(
        "\nInterpretation: each accept is a wrong-but-real identification the "
        "checksum AND the ISBN gate would both pass — the title cross-check is "
        "then the only remaining guard. The rescue's bar is judged on this rate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
