"""Cost and latency decomposition over repeated vision-eval runs.

⛔ READ-ONLY OVER ARTEFACTS. It computes; it never runs the eval, deploys anything,
   or writes outside the output path it is given.

Why repeated runs rather than one: three prior runs of this corpus showed vlm-cls
median variance of **60%** and max variance of **6.8x** against a 2% barcode control.
A percentile from a single run is noise, so every figure here carries its sample
count and nothing is reported without one.

Why artefacts rather than live counters: PromEx counters live in the memory of one
node and a preview wipes them on every deploy — a drive hit exactly that, with the
month-to-date read returning :error because the machine had restarted 197s earlier.
Artefacts are files that outlive the process that produced them, which is the only
property a distribution needs.

⚠️ The eval's DEFAULT artefact path is a single file (`priv/eval/vision_last_run.json`)
   that each run overwrites, so N runs must each be given their own
   `EVAL_VISION_RESULT_PATH`. This script reads a directory of such files.

Usage:
    python3 -I scripts/characterise/vision-cost-decomposition.py <dir-of-run-artefacts>
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

# Published A10G rate, confirmed via `modal billing rates`: $0.000306/s = $1.10/hour.
# Mirrors Stacks.Costs.a10g_micro_cents_per_second/0 (3_060 micro-cents per second);
# kept as a literal here so this script states the price it used rather than
# importing one it cannot show.
MICRO_CENTS_PER_GPU_SECOND = 3_060
SCALEDOWN_WINDOW_S = 300


def stage_ms(case: dict[str, Any]) -> float:
    """Total GPU-stage milliseconds for one case, ignoring stages that did not run.

    ⛔ `timings_ms` carries an explicit null per stage that was skipped — a barcode
    answer has no classify or extract, and a classify-only answer has no extract.
    An earlier version summed the values directly and crashed on the FIRST real
    artefact set (`float(None)`), having passed on a synthetic fixture whose
    timings were all numeric. A stage that did not run contributes zero.
    """
    return sum(float(v) for v in (case.get("timings_ms") or {}).values() if v is not None)


def pct(values: list[float], p: float) -> float | None:
    """Percentile with no interpolation games, and None below the sample floor.

    ⚖️ Returns None under 5 samples rather than a number: a 'p95' over 3 points is
    the maximum wearing a percentile's name, which is exactly the false precision
    this decomposition exists to avoid.
    """
    if len(values) < 5:
        return None
    s = sorted(values)
    idx = min(round(p * (len(s) - 1)), len(s) - 1)
    return s[idx]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = Path(sys.argv[1])
    files = sorted(root.glob("*.json"))
    if not files:
        print(f"FAIL: no run artefacts in {root} — nothing to decompose.")
        return 1

    runs = []
    for f in files:
        try:
            runs.append(json.loads(f.read_text()))
        except Exception as exc:
            print(f"WARN: skipping {f.name}: {type(exc).__name__}")

    cases = [c for r in runs for c in r.get("cases", [])]
    if not cases:
        print(f"FAIL: {len(runs)} run(s) carried no cases.")
        return 1

    # ⛔ A case with no `tier` predates the artefact carrying the measurements, and
    # counting it as a tier would silently merge two populations. Separated and
    # reported, not dropped.
    untiered = [c for c in cases if c.get("tier") is None]
    tiered = [c for c in cases if c.get("tier") is not None]

    print(f"runs: {len(runs)}   cases: {len(cases)}   with tier: {len(tiered)}")
    if untiered:
        print(
            f"⚠️  {len(untiered)} case(s) carry no tier — artefacts written before the "
            f"measurements were recorded. Excluded from per-tier figures."
        )

    by_tier: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for c in tiered:
        by_tier[str(c["tier"])].append(c)

    print("\n=== per tier ===")
    for tier, cs in sorted(by_tier.items()):
        walls = [float(c["wall_ms"]) for c in cs if c.get("wall_ms") is not None]
        gpu = [stage_ms(c) for c in cs if c.get("timings_ms")]
        colds = [c for c in cs if c.get("gpu_cold") is True]
        p95 = pct(walls, 0.95)
        print(f"\n{tier}  n={len(cs)}")
        if walls:
            print(
                f"  wall ms       p50 {statistics.median(walls):9.1f}   "
                f"p95 {f'{p95:9.1f}' if p95 is not None else '  n<5':>9}   "
                f"max {max(walls):9.1f}"
            )
        if gpu:
            print(f"  stage ms      p50 {statistics.median(gpu):9.1f}   n={len(gpu)}")
        rate = len(colds) / len(cs) if cs else 0
        print(f"  cold starts   {len(colds)} of {len(cs)}  ({rate:.0%})")

    # ⚖️ The headline: idle vs inference. Priced from the SAME constant the cost page
    # uses, so a discrepancy between this and the page is a real disagreement rather
    # than two different rate cards.
    print("\n=== cost decomposition ===")
    all_gpu_s = sum(stage_ms(c) for c in tiered if c.get("timings_ms")) / 1000.0
    cold_count = sum(1 for c in tiered if c.get("gpu_cold") is True)
    idle_s = cold_count * SCALEDOWN_WINDOW_S
    inf_c = all_gpu_s * MICRO_CENTS_PER_GPU_SECOND / 100_000
    idle_c = idle_s * MICRO_CENTS_PER_GPU_SECOND / 100_000

    print(f"  GPU-active      {all_gpu_s:8.1f} s  ->  {inf_c:7.2f} c")
    print(
        f"  idle tail       {idle_s:8.1f} s  ->  {idle_c:7.2f} c   "
        f"({cold_count} cold container(s) x {SCALEDOWN_WINDOW_S}s)"
    )
    total = inf_c + idle_c
    if total > 0:
        print(f"  idle share      {idle_c / total:7.0%} of GPU cost")
    ident = len(tiered)
    if ident:
        print(f"  per identification  {total / ident:7.3f} c   over n={ident}")

    gpu_tiers = {"ANALYSIS_TIER_VLM_CLASSIFY", "ANALYSIS_TIER_VLM_EXTRACT"}
    no_gpu = sum(len(cs) for t, cs in by_tier.items() if t not in gpu_tiers)
    if tiered:
        print(
            f"\n  barcode-tier hit rate  {no_gpu}/{len(tiered)} = {no_gpu / len(tiered):.0%} "
            f"answered without a GPU  ⚠️ over THIS corpus, not a general rate"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
