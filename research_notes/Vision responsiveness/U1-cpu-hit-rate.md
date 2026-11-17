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
