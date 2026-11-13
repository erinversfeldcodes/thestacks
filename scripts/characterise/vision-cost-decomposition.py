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
from datetime import datetime
from pathlib import Path
from typing import Any

# Published A10G rate, confirmed via `modal billing rates`: $0.000306/s = $1.10/hour.
# Mirrors Stacks.Costs.a10g_micro_cents_per_second/0 (3_060 micro-cents per second);
# kept as a literal here so this script states the price it used rather than
# importing one it cannot show.
MICRO_CENTS_PER_GPU_SECOND = 3_060
SCALEDOWN_WINDOW_S = 300


# ⛔ ONLY the stages that run on the GPU, matching `Client.gpu_stage_ms/1`
# ("classify", "extract"). `download` is the sidecar fetching bytes and
# `barcode` is a CPU decode in the sidecar; charging either to the GPU inflates
# the figure with work no A10G did, and worse, it would bill a future CPU
# cover-embedding tier at $1.10/hour A10G rates — biasing the measurement
# against the candidate this analysis exists to evaluate.
GPU_STAGES = ("classify", "extract")

# See pct() — p95 equals max for all n <= 11.
MIN_SAMPLES_FOR_PCT = 12

# ⚠️ Duplicated from `Costs.gpu_tiers/0`. A proto enum would be the single
# source of truth; this script cannot reach it, so the duplication is named
# rather than hidden, and the no-GPU figure lists the tiers it counted so a
# new tier shows up as itself instead of being absorbed.
GPU_TIERS = frozenset({"ANALYSIS_TIER_VLM_CLASSIFY", "ANALYSIS_TIER_VLM_EXTRACT"})


def stage_ms(case: dict[str, Any], only_gpu: bool = True) -> float:
    """Total GPU-stage milliseconds for one case, ignoring stages that did not run.

    ⛔ `timings_ms` carries an explicit null per stage that was skipped — a barcode
    answer has no classify or extract, and a classify-only answer has no extract.
    An earlier version summed the values directly and crashed on the FIRST real
    artefact set (`float(None)`), having passed on a synthetic fixture whose
    timings were all numeric. A stage that did not run contributes zero.
    """
    timings = case.get("timings_ms") or {}
    items = (
        [(k, v) for k, v in timings.items() if k in GPU_STAGES]
        if only_gpu
        else list(timings.items())
    )
    return sum(float(v) for _, v in items if v is not None)


def run_span_seconds(runs: list[dict[str, Any]]) -> float | None:
    """Seconds from the first run's end to the last, or None if unknowable.

    ⚖️ `ran_at` is written AFTER a run's results, so it marks the run's END.
    The span between the first and last therefore EXCLUDES the first run's own
    duration, which makes this a conservative lower bound on how long a
    container was up — exactly what is wanted for a floor.
    """
    stamps = []
    for r in runs:
        raw = r.get("ran_at")
        if not raw:
            continue
        try:
            stamps.append(datetime.fromisoformat(str(raw).replace("Z", "+00:00")))
        except ValueError:
            continue
    if len(stamps) < 2:
        return None
    return (max(stamps) - min(stamps)).total_seconds()


def pct(values: list[float], p: float) -> float | None:
    """Percentile with no interpolation games, and None below the sample floor.

    ⛔ The floor is TWELVE, not five. With `idx = round(p*(n-1))`, p95 EQUALS the
    maximum for every n <= 11 — so a "p95" below that floor is the largest
    observation wearing a percentile's name, which is exactly the false precision
    this function exists to refuse. The first published BARCODE "p95 5,710 ms"
    WAS its max, at n=5, under a floor of 5 that could not catch it.
    """
    if len(values) < MIN_SAMPLES_FOR_PCT:
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
                f"p95 {f'{p95:9.1f}' if p95 is not None else f'  n<{MIN_SAMPLES_FOR_PCT}':>9}   "
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

    # ⛔ `cold_count * SCALEDOWN_WINDOW_S` PRICES ONLY THE TRAILING WINDOW and
    # misses every warm-but-idle second BETWEEN requests, which Modal also
    # bills. On the first real series that was 34 s of 334 s — and the error
    # runs in the direction that makes the GPU look cheap, which is the
    # direction that would wrongly settle the architecture question.
    #
    # ⚖️ The wire does not carry container age (a reviewer had it deleted as
    # double-counting; it was not, since age-at-last-inference is active time
    # PLUS the warm gaps). Until it returns, bound idle from the run
    # timestamps: a container spanning the whole series was up for at least
    # that span plus one tail. Reported as a LOWER BOUND, never as a figure.
    span_s = run_span_seconds(runs)
    idle_floor_s = cold_count * SCALEDOWN_WINDOW_S
    idle_s = (
        max(idle_floor_s, span_s + SCALEDOWN_WINDOW_S - all_gpu_s)
        if span_s is not None
        else idle_floor_s
    )
    bounded = span_s is not None and idle_s > idle_floor_s
    inf_c = all_gpu_s * MICRO_CENTS_PER_GPU_SECOND / 100_000
    idle_c = idle_s * MICRO_CENTS_PER_GPU_SECOND / 100_000

    print(f"  GPU-active      {all_gpu_s:8.1f} s  ->  {inf_c:7.2f} c")
    lead = "idle   >=   " if bounded else "idle tail   "
    detail = (
        f"(span {span_s:.0f}s + {SCALEDOWN_WINDOW_S}s tail - active; "
        f"window-only would say {idle_floor_s:.0f}s)"
        if bounded
        else f"({cold_count} cold container(s) x {SCALEDOWN_WINDOW_S}s)"
    )
    print(f"  {lead}    {idle_s:8.1f} s  ->  {idle_c:7.2f} c   {detail}")
    total = inf_c + idle_c
    if total > 0:
        share = "idle share >= " if bounded else "idle share    "
        print(f"  {share}  {idle_c / total:7.0%} of GPU cost")
    ident = len(tiered)
    if ident:
        qual = ">=" if bounded else "  "
        print(f"  per identification {qual}{total / ident:7.3f} c   over n={ident}")
        # ⚖️ The price is stated so a reader of the OUTPUT can check it, not
        # just a reader of the source.
        print(f"  (A10G at {MICRO_CENTS_PER_GPU_SECOND} micro-cents/s)")

    # ⚠️ This counts every tier that is NOT a GPU tier, so it is a no-GPU
    # share, NOT a barcode hit rate. Calling it "barcode-tier hit rate" was
    # wrong the moment a second non-GPU tier existed: with cover-embedding
    # cases present it reported them as barcode hits. The planned cascade
    # (barcode -> cover-embedding -> OCR -> VLM) adds exactly such tiers, so
    # the label is fixed and the counted tiers are listed.
    no_gpu_tiers = sorted(t for t in by_tier if t not in GPU_TIERS)
    no_gpu = sum(len(by_tier[t]) for t in no_gpu_tiers)
    if tiered:
        print(
            f"\n  no-GPU-tier share  {no_gpu}/{len(tiered)} = {no_gpu / len(tiered):.0%} "
            f"answered without a GPU  ⚠️ over THIS corpus, not a general rate"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
