#!/usr/bin/env python3
"""What the CPU cover-text pass read, measured against what the VLM answered.

⛔ THE FIGURE THIS EXISTS TO PRODUCE is not "did OCR read something" but
`P(OCR yields a title the existing cached search would resolve)`. The platform
already has that search — `ISBNResolver.search_by_title/4`, two-level cached,
called at the vision-output seam — so a title OCR reads is one hop from an
identification. Reading text is not the achievement; reading the *right* text is.

⚠️ THE SILENT ZERO THIS GUARDS. A container where tesseract failed to install
produces empty reads that look exactly like "OCR is useless on these covers".
The sidecar reports `engine: "unavailable"` for that case and this script
REFUSES to print a yield when any run carries it — because a 0% that means
"broken pipe" and a 0% that means "hard covers" lead to opposite decisions.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path
from typing import Any


def normalise(s: str | None) -> str:
    """Case-, space- and punctuation-insensitive, matching the eval's own rule."""
    if not s:
        return ""
    return re.sub(r"[^a-z0-9]+", " ", str(s).lower()).strip()


def match(expected: str | None, read: str | None) -> bool:
    """Containment either way, which is what the eval harness scores.

    A cover prints "Flyboys: A True Story of Courage" while ground truth records
    the work, "Flyboys" — and a reader searching either finds the book. Equality
    would call every correct read a miss.
    """
    e, r = normalise(expected), normalise(read)
    if not e or not r:
        return False
    return e in r or r in e


def load(directory: Path) -> list[dict[str, Any]]:
    files = sorted(directory.glob("run-*.json"))
    if not files:
        sys.exit(f"FAIL: no run artefacts in {directory} — nothing to measure")
    out = []
    for f in files:
        try:
            out.append(json.loads(f.read_text()))
        except json.JSONDecodeError as exc:
            sys.exit(f"FAIL: {f.name} is not readable JSON ({exc}); n would be wrong")
    return out


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit("usage: ocr-yield.py <artefact-dir>")
    runs = load(Path(sys.argv[1]))
    cases = [c for r in runs for c in r.get("cases", [])]

    attempted = [c for c in cases if c.get("ocr_attempt")]
    n = len(attempted) if (attempted := [c for c in cases if c.get("ocr_attempt")]) else 0

    def pc(subset: list[dict[str, Any]]) -> str:
        """A share of the attempted cases, or a blank when there are none."""
        return f"{len(subset) / n:.0%}" if n else "n/a"

    print(f"runs {len(runs)}   cases {len(cases)}   with an OCR attempt {len(attempted)}")

    if not attempted:
        print("\n⛔ NO OCR ATTEMPTS AT ALL.")
        print("   Either the pass is disabled (VISION_COVER_TEXT_ENABLED) or the")
        print("   artefact is dropping the field. This is not a 0% yield — it is")
        print("   no measurement. Fix before reading anything below as evidence.")
        return 1

    broken = [c for c in attempted if c["ocr_attempt"].get("engine") == "unavailable"]
    if broken:
        print(f"\n⛔ THE ENGINE IS NOT INSTALLED in {len(broken)}/{len(attempted)} cases.")
        print("   Every read from those is empty for a reason that has nothing to")
        print("   do with the covers. REFUSING to report a yield: a 0% that means")
        print("   'broken pipe' and a 0% that means 'hard covers' lead to opposite")
        print("   decisions. Rebuild the image with tesseract-ocr and re-run.")
        return 1

    # Read anything at all
    read_something = [c for c in attempted if c["ocr_attempt"].get("raw_text")]
    got_title = [c for c in attempted if c["ocr_attempt"].get("title")]

    print("\n=== what it read ===")
    print(f"  read any text      {len(read_something):3}/{n} = {pc(read_something)}")
    print(f"  produced a title   {len(got_title):3}/{n} = {pc(got_title)}")

    # ⬛ The figure that decides the architecture question.
    def matched(c: dict[str, Any]) -> bool:
        return match(c.get("expect_title"), c["ocr_attempt"].get("title"))

    hits = [c for c in attempted if matched(c)]
    labelled = [c for c in attempted if c.get("expect_title")]

    print("\n=== yield against ground truth ===")
    if labelled:
        print(
            f"  title matched      {len(hits):3}/{len(labelled)} = {len(hits) / len(labelled):.0%}"
            f"   <- P(OCR yields a resolvable title)"
        )
    else:
        print("  ⚠️  no case carries expect_title, so a match rate cannot be computed.")
        print("      The corpus labels most covers by title; if this is empty the")
        print("      eval is not passing the label through.")

    # Per stratum, because an aggregate hides exactly the cases that matter
    by_stratum: dict[str, list[dict[str, Any]]] = {}
    for c in attempted:
        by_stratum.setdefault(c.get("stratum") or "unknown", []).append(c)

    print("\n=== per stratum ===")
    for stratum, cs in sorted(by_stratum.items()):
        lab = [c for c in cs if c.get("expect_title")]
        hit = [c for c in lab if matched(c)]
        rate = f"{len(hit)}/{len(lab)} = {len(hit) / len(lab):.0%}" if lab else "no labels"
        titled = sum(1 for c in cs if c["ocr_attempt"].get("title"))
        print(f"  {stratum:<22} n={len(cs):<3} title read {titled:>2}   matched {rate}")

    # What it cost
    ms = [
        c["timings_ms"]["ocr"]
        for c in attempted
        if (c.get("timings_ms") or {}).get("ocr") is not None
    ]
    if ms:
        s = sorted(ms)
        p95 = s[min(round(0.95 * (len(s) - 1)), len(s) - 1)] if len(s) >= 12 else None
        p95s = f"{p95:7.0f}" if p95 is not None else "   n<12"
        print("\n=== what it cost ===")
        print(
            f"  ocr ms   p50 {statistics.median(s):7.0f}   "
            f"p95 {p95s}   max {max(s):7.0f}   n={len(s)}"
        )
        print("  ⚖️  On the CPU front door, which is warm by construction: this")
        print("     time opens no billable container lifetime and owes no idle tail.")

    confs = [c["ocr_attempt"]["confidence"] for c in got_title]
    if confs:
        print("\n=== confidence, where a title was produced ===")
        print(
            f"  median {statistics.median(confs):.2f}   min {min(confs):.2f}   max {max(confs):.2f}"
        )
        for bar in (0.70, 0.80, 0.90):
            above = [c for c in got_title if c["ocr_attempt"]["confidence"] >= bar]
            right = [c for c in above if matched(c)]
            prec = f"{len(right) / len(above):.0%}" if above else "n/a"
            print(
                f"  at >= {bar:.2f}: would answer {len(above):3}/{len(attempted)}"
                f"   and be right {prec}"
            )
        print("  ⛔ The right-hand column is precision, and it is the number that")
        print("     gates promotion: a wrong identification costs more than a")
        print("     fall-through to the VLM, which is merely expensive.")

    answered = [c for c in attempted if c["ocr_attempt"].get("answered")]
    print(
        f"\n  short-circuited {len(answered)}/{len(attempted)}"
        f"   ({'SHADOW — the VLM answered every case' if not answered else 'LIVE'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
