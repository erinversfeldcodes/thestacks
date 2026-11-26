# U1 — CPU-tier hit-rate, measured

**Source:** the exp-4 (T4+Qwen3-VL-4B) run artefact, which records per image the
tier that answered (barcode short-circuit vs GPU) and the shadow OCR read.
Engine was `tesseract` on all 88 OCR attempts (not `unavailable`), so the OCR
reads are real. OCR→catalogue is proxied by title-match to ground truth.

## The number

| | |
|---|---|
| **CPU resolution rate (current, as built)** | **30% (37/122)** — barcode 30 + OCR-title-match 7 |
| books only (ex negatives) | 36% (37/102) |
| **thresholds** | p50 ≤ 5s needs f ≥ 0.47; **p95 ≤ 15s needs f ≥ 0.95** |

**Verdict: the CPU tier as built clears NEITHER threshold** — 30% is below even
the p50 bar (0.47), far below p95 (0.95).

## But 30% is a FLOOR, not a ceiling — two reasons

1. ⬛ **The OCR tier is known-broken and un-improved.** It uses the largest-text
   title-extraction heuristic (a *selection* failure measured earlier this wave),
   not the planned **bag-of-words → catalogue** match, and plain Tesseract, not a
   rotation-aware engine. The tell: on `clear_cover` — 22 LEGIBLE covers — OCR
   resolved only 6 (27%). A working OCR→catalogue should take most of those.
   The OCR contribution (6%) is the unimproved tier's floor.
2. The barcode tier already works where barcodes exist: clean_barcode 95%,
   hostile_orientation 83%.

## ⛔ The structural ceiling, and why it reorders the plan

Even a PERFECT CPU tier cannot resolve the strata that structurally need the GPU
— negatives (must be *rejected*), book_adjacent (must *decline*), illegible,
occlusion, text_clutter, multiple_books: **45/122 = 37% of this corpus.**

    CEILING on CPU-resolvable f (this corpus) = 77/122 = 63%

So **f ≥ 0.95 (the p95 requirement) is UNREACHABLE via CPU-first on this input
distribution**, no matter how good the OCR tier gets. ⚠️ The corpus is adversarial
(16% deliberate negatives) so real-world f is likely higher — but negatives and
bad photos do occur in real use, so a GPU floor always exists and 0.95 stays out
of reach for CPU-first alone.

## What this does to the responsiveness plan

- **p50 ≤ 5s is reachable** by fixing the OCR tier (bag-of-words + rotation-aware)
  — clear_cover headroom alone could lift f past 0.47.
- ⛔ **p95 ≤ 15s is NOT reachable by CPU-first alone** — the structural ceiling
  (63%) is below 0.95. So the cold-path lever (U2: GPU snapshots) is **not optional
  for p95, it is the pivotal unknown.** If snapshots don't work on T4, p95 ≤ 15s is
  likely unmeetable on T4+4B synchronously, which promotes the **L4 reconsideration**
  (ADR 026 fallback; L4 is newer than the A10G snapshots are confirmed on) from a
  footnote to a live option — OR the p95 target is revised, OR a minor "still
  looking…" SSE affordance is accepted for the cold tail.

**Net: U1 confirms CPU-first is worth building (p50 + cost) but cannot carry p95.
U2 (T4 snapshot feasibility) is now the decision's pivot.**

---

# U2 — do GPU memory snapshots work on our T4? NO (measured)

Test (`VISION_GPU_SNAPSHOT=1`, `enable_memory_snapshot=True` +
`experimental_options={"enable_gpu_snapshot": True}`, `@modal.enter(snap=True)`):
deploy snapshot-enabled T4+4B, call 1 creates the snapshot, force scaledown,
call 2 is a cold RESTORE.

| | |
|---|---|
| deploy on T4 | ✅ accepted (rc=0) — not hard-blocked |
| call 1 (create) | 41.0s |
| **call 2 (restore)** | **24.8s — vs 26.3s no-snapshot baseline. NO speedup.** |
| logs | `Creating GPU memory snapshot` on BOTH calls, model re-loads both times; no "Restoring" line |

⛔ **Conclusion: GPU snapshot RESTORE does not work (or does not help) on our T4.**
Modal accepts the config but each cold start re-creates rather than restores —
consistent with the research's warning that snapshots are unconfirmed on
Turing (every Modal benchmark is A10G/H100/A100). The ~10× cold-path lever is
unavailable on T4.

⚠️ One-run caveat: my drive forced scaledown between the two calls, which could
in principle have discarded the snapshot before it persisted. But no-speedup +
re-creation logged is a strong signal; a confirming run is cheap if the decision
hinges on it.

## The box this puts p95 in

- CPU-first ceiling on the corpus = **63%** (negatives/adjacent/illegible need
  the GPU) — below the **f ≥ 0.95** p95 needs.
- GPU snapshots (the fast-cold-path lever) = **dead on T4**.
- ⛔ Therefore **p95 ≤ 15s is unmeetable on T4+4B synchronously.** p50 ≤ 5s is
  still reachable (fix the OCR tier). The decision forks — see below.

## U2 on L4 — INCONCLUSIVE (not re-run; decision went B/C)

Same test on L4: call 1 = 400.0s (hit the 400s timeout), call 2 = 213.2s — both
far beyond the T4's ~26-41s, timeout-dominated by L4 scheduling/capacity or a
stuck snapshot creation, NOT a clean restore measurement. It neither confirms nor
refutes L4 snapshots. Left inconclusive on purpose: the owner chose to keep T4+4B
and revise the target (B+C), so the L4 question is informational only. A clean
re-run is cheap if the budget or responsiveness bar is ever revisited.

---

# R0 — single-dispatch, VALIDATED (modest win, honest)

Flag `VISION_SINGLE_DISPATCH`, off by default. Validated on T4+4B:

| axis | result |
|---|---|
| accuracy | ✅ 84/122, **every stratum identical** to the two-call 4B (exp-4) — R0 changes nothing about identification |
| cold p95 (N=6 concurrent) | ✅ 25.6s vs two-call 29.3s — **~13% / ~3.7s** faster, consistently |
| the ~52s two-cold-start tail | ⚠️ did NOT reproduce at N=6 under the 10-container cap (extracts found warm containers). The tail needs OVER-CAP contention (N > max_containers); untested. The common concurrent case saves one dispatch (~3.7s), not a second cold start (~25s). |

⬛ CORRECTION to the earlier framing: "kills the 52s tail" was the theoretical
worst case. Measured, R0 is a solid ~13% cold-p95 win with zero accuracy cost,
plus halved dispatch count and a shared image encode — worth enabling, but the
dramatic tail is rarer than first claimed.

Flip criterion (config comment) is MET on the 4B. Two caveats before defaulting
on: production still runs 7B/A10G (R0 accuracy validated on 4B only — structurally
identical, but unmeasured on 7B), and it is a production-behaviour change. Flip
with the 4B deployment, or run the 7B slice gate first.
