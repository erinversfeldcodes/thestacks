# Cost and latency decomposition — 5 runs, 2026-11-12

Five consecutive `mix eval.vision` runs against a deployed preview with real Modal vision.
Each run writes its own artefact; the eval's default path is a single file every run
overwrites, so `EVAL_VISION_RESULT_PATH` was set per run.

Reproduce the analysis:

    python3 -I scripts/characterise/vision-cost-decomposition.py \
      apps/core/priv/eval/decomposition-2026-11-12

**Model:** `Qwen/Qwen2.5-VL-7B-Instruct` · **8 fixtures × 5 runs = 40 identifications** ·
all five runs scored 8/8.

## What these artefacts are for

The figures the vision-architecture decision is argued from. They are committed because a
cost decomposition nobody else can recompute is an assertion, not a measurement — and
because PromEx counters cannot supply it: they live in one node's memory and a preview
wipes them on every deploy.

## ⚠️ Two things to read before quoting a number

**The idle share depends on traffic shape, and both figures are real.** These runs
amortised ONE cold start across 40 identifications, giving **57%** idle. A single
identification after a quiet period carries its own 300 s tail and gives **~90%** — which
is the realistic lone-upload case at a few hundred users. Quote the condition with the
number; the honest range is 57–90%.

**Wall time is dominated by transport, not inference.** The barcode tier's GPU stage is
**4 ms** while its wall time is **5,288 ms** — so "barcode is ~7 ms" describes the stage,
not what a reader waits. Any CPU tier at ~200 ms of compute sits inside the same envelope.

## Corpus caveat

8 fixtures across 5 strata. Adequate for this architecture's cost and latency
distributions; **not** adequate for ranking two architectures, which needs the corpus at
the size `docs/vision-eval-corpus-plan.md` specifies. The barcode-tier hit rate (12% here)
is bounded by the corpus composition and is **not** a general rate.
