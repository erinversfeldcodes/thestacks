# ADR 026: Vision Service Cost, Hardware and Architecture — Wave 7 Findings

**Status:** Accepted (2026-11-17)
`PENDING` await experiments still in flight or data not yet collected; the ruling
slot at the bottom is deliberately empty until then.
**Date:** 2026-11-16 (draft)
**Deciders:** Platform owner
**Technical area:** Vision sidecar — GPU selection, model selection, cascade
architecture, cost ceiling, responsiveness targets
**Relates to:** [ADR 025](025-vision-model-training-data-provenance.md) (training-data
provenance; its per-checkpoint licence rule is applied here), the ISBN hard gate
(CLAUDE.md, *Core Conventions*), `plans/residue-ledger.md` RL-499/RL-500.

---

## Context

The vision service identifies books from reader photographs on a **$50/month total
inference budget**. It runs Qwen2.5-VL-7B-Instruct (Apache 2.0) behind a CPU
FastAPI front door on Modal; the cascade is `pyzbar barcode decode → VLM`, with
every candidate identification verified against Open Library / Google Books by the
ISBN hard gate before anything enters the catalogue.

This ADR consolidates what wave 7 measured, broke, researched and concluded, so the
wave can end with one ruling instead of a dozen scattered threads.

---

## 1. The measured economics — the bill is wake-ups, not inference

- A lone identification costs ~9.34c, of which **98.1% is idle GPU tail** after
  answering (at the former 300s scaledown window; since cut to 60s against the
  measured decomposition).
- At hobby-scale traffic the container is cold for **95–99% of requests** — the
  system is expensive *because* it is quiet. Cost per identification falls as
  volume rises.
- The simulated frontier (`scripts/characterise/scaledown-frontier.py`, validated
  against both measured extremes after an 11×-optimistic first version was caught):

  | load (A10G, 60s window) | $/month | within $50? |
  |---|---:|---|
  | 12 uploads/day | 9.83 | yes |
  | 48/day | 37.60 | barely |
  | 240/day | 162 | no |

  **The ceiling on A10G is ~60 uploads/day.** Rates: A10G $1.10/hr, L4 $0.80, T4
  $0.59 (`modal billing rates`, 2026-11-13).
- ⚠️ Arrival rate is **assumed** — no production telemetry exists. Every figure
  above is a band, not a point.
- ⬛ Consequence that shapes everything below: a change that halves how often the
  GPU *wakes* beats any change to the GPU's hourly rate, and the two compound.

## 2. The corpus, the baseline, and the gate that now guards it

- 122 labelled images (94 owner-shot, 20 derived, 8 pre-existing), every
  identity-bearing image carrying a check-digit-verified ISBN, provenance per image.
- **Reference baseline: 86/122 (70%) — A10G, 7B, bf16, default pixels**, recorded
  per-stratum: negatives 20/20, clean_barcode 18/19, hostile_orientation 11/12,
  clear_cover 20/22, book_adjacent 6/12, illegible 5/10, hostile_typography 2/4,
  **hostile_barcode 3/20**.
- ⛔ The eval gate now **compares strata before totals** and names the slice that
  fell. It exists because a prompt change moved the total 57→67 while
  clear_cover collapsed 20/22 → 2/22 — a regression a total-only gate reported as
  an improvement. Replayed against those numbers it fires:
  `clear_cover: 20/22 -> 2/22`.
- ⛔ **The corpus has no spine stratum** (3 shelf photos, all filed as
  "should decline"), while the owner states face-on covers and **spines** of
  varying quality are the primary real input. Every number in this ADR is measured
  on an input mix known to under-represent the primary case. `PENDING: spine
  photographs (target 15–20) before any final ruling.`

## 3. What the prompt fiasco taught (2026-11-13, same wave)

- **A prompt is global state.** A change measured only on its target stratum
  shipped a 91%→9% collapse elsewhere. Full-corpus scoring before belief is now
  enforced by the slice gate.
- **A well-formed hallucination defeats structural guards.** A real example ISBN
  in the output template was copied verbatim onto 10 of 16 unrelated books; its
  check digit held and it resolved. The surviving mitigations, each
  probe-verified: checksum validation at the seam, and a **title cross-check**
  (ISBN-resolved title vs cover-read title; disagreement between two independent
  readings is the only signal left when a value is wrong but well-formed).
- The template now describes fields, never exemplifies them.

## 4. Research findings adopted as premises

- **Nobody puts a VLM behind a failed decoder.** Published practice is uniformly
  *restore → read → match-against-catalogue*: the middle tier emits a catalogue
  identifier by retrieval, not a description by generation.
- ⬛ **The ISBN hard gate converts the middle tier's requirement from precision to
  recall-within-k** (generator-verifier literature): propose k candidates, let
  checksum + catalogue select, abstain structurally. This is the licence for
  smaller/cruder tiers.
- **Only CPU-resident gates are free** in this cost structure (a confidence-gated
  cascade replication cost 2.4× bare-cheap because the gate was itself a model
  call) → routing decisions belong *before* the GPU wakes.
- **Structural gates beat learned gates** in the one directly comparable book
  experiment (a BERT re-ranker with an abstention head lost to plain CLIP and to
  fuzzy string matching on a 2.3M catalogue). NNDR (nearest-neighbour distance
  ratio), checksum, catalogue resolution and title agreement are the gate
  vocabulary, not thresholds on model confidence — measured locally too: OCR
  confidence 0.95 while reading the wrong object (legibility, not relevance).
- **Catalogue size inverts retrieval**: embeddings beat strings on a 15k list
  (0.939 vs 0.783) and lose on 2.3M (0.449 vs 0.505) → constrain with text first,
  rank with similarity second.
- **Restoration recovers half to two-thirds of failed decodes, not all**
  (wearable-QR study: 217 raw + 83 recovered of 340; 40 never).

## 5. The T4 experiment series (in flight)

Pre-registered criteria, in order: **(a)** no stratum regresses vs the 86/122
baseline under the slice gate; **(b)** a lone cold request survives the client
timeout; **(c)** lowest GPU-seconds per identification among survivors.

⬛ **Series conclusion already forced, whatever 1v2/2 add: the T4 cannot serve
the 7B in any tested configuration** — fp16 offloads and crawls, int8 fits and
times out, AWQ is toolchain-blocked. The T4's only measured viable config is
the 4B, which the slice gate refuses as a drop-in.

| # | config | result |
|---|---|---|
| 1 | T4 + 7B fp16 "as is" | ⛔ **Does not fit — `device_map="auto"` silently offloads to CPU.** Scored-case accuracy at parity (85/113), but p-max latency 151s and 9 lone requests died against timeouts. Fails criterion (b). |
| 1v2 | warmed clean re-run | ⚠️ **Aborted by an infrastructure collision, not re-run.** A concurrent preview deploy reset the shared Neon preview branch mid-run and killed the eval at its budget lookup, four hours in. The as-is verdict rests on run 1 plus the container's own offload evidence; another four offloaded hours would polish a conclusion already forced. |
| 2 | `max_pixels=1003520` (repointed to L4 by owner decision after the T4-7B disqualification) | ⬛ **A no-op by construction, and the discovery is the result**: the CPU front door already resizes every image to ≤672px (~452k pixels) — under half the tested cap — so the knob never bit. Accuracy byte-identical (86/122, every stratum); the ±5–8% latency deltas between two identical L4 runs calibrate **run-to-run jitter (~5–8% on medians)** — no smaller delta is ever signal. The pixel lever was pulled before this wave began. |
| L4 | L4 + 7B bf16 as-is | ✅ **86/122, 0 unscored, per-stratum identical to the A10G baseline** — zero model risk, measured rather than assumed. Extract p50 16.5s (+32%, the bandwidth ratio); warm cost/extract a wash (0.367c vs 0.382c); **idle tail per lone identification −27% (1.33c vs 1.83c) — the dominant term.** No cold-start failure mode, unlike every tested T4 configuration. |
| 3a | T4 + 7B bnb-int8 | ⛔ **Fits, and is unusable — the pre-registered prediction confirmed in the worst way.** 30/122 scored, 88 unscored: every success came from the CPU barcode tier and **zero VLM answers survived the HTTP serving path** (all died as upstream failures). The model answers through Modal's patient direct client, so this is pure inference speed: bnb-int8 on Turing is slow enough that every call outlives the caller. Fails criterion (b) absolutely. |
| 3b | T4 + 7B AWQ int4 | ⛔ **BLOCKED after three distinct toolchain failures** (gptqmodel missing → Triton AWQ kernel rejects the vision-merger shape on sm75 → autoawq demands IPEX on a CPU builder). ⬛ Finding: the quantisation ecosystem has moved past Turing; fast kernels (Marlin) start at Ampere. |
| 4 | T4 + Qwen3-VL-4B fp16 | ✅ **84/122, 0 unscored.** Perfect clear_cover (22/22) and rotation (12/12); **illegible collapsed 5/10 → 1/10**, hostile_barcode −1, book_adjacent −1. Latency T4-viable (cls p50 7.0s ≈ A10G 7B). ⚖️ As a drop-in swap, **our own slice gate refuses it** — correctly. As a cascade role-player (clean input only), strongest candidate measured. |

**The production SLO gate, run report-only against a T4+4B preview (2026-11-16):
formally "would roll back", substantively a pass with one caveat.** The breach was
availability 0.7143 vs 0.99 — but its decomposition is 287 synthetic probes, 205
succeeded, **zero 5xx, zero timeouts**: every failure was a 4xx-class refusal from
probe types that presuppose production fixtures a preview does not carry. The
signal the gate measured cleanly all passed: 40/40 real uploads succeeded, no
circuit fuse opened, DB pool queues single-digit ms, BEAM memory flat at 138MB of
a 400MB ceiling — the 4B under concurrent upload load destabilised nothing.
⚠️ Two caveats: the reported upload p95 (47ms) is implausibly small against known
10–20s identification streams and measures something narrower than the pipeline —
not to be quoted until understood; and ⬛ the gate itself is not preview-portable
(prod-fixture assumptions), which is a gap worth closing before the gate is ever
pointed at a preview as a release check.

Harness facts with standing value: the **preview Neon branch is shared mutable
state** — a preview deploy resets it and kills every consumer mid-flight (cost:
one four-hour run); Modal binds **decorator args at deploy time but
re-resolves module globals in the container**, so experiment knobs must be baked
into the image env (a max_pixels "variant" would otherwise silently re-run the
baseline); the GPU must be warmed through Modal's own client (an HTTP warmup
loses the race against the cold load + client timeout + 60s window, forever); the
load line **prints** model, dtype and **device map** (`devices=['cpu','cuda:0']`
is a measurement of the offload, not the GPU).

## 6. Licensing rule (applied, with teeth)

Licences differ **per checkpoint within one family**: Qwen2.5-VL-**3B** is under
the Qwen Research License (research/evaluation only; Alibaba claims IP in
derivatives), while 7B/72B are Apache 2.0, and Qwen3-VL is Apache 2.0 throughout.
⛔ Rule: read the LICENSE file of the exact checkpoint on every swap. The small-
Qwen path runs through Qwen3-VL-4B/2B, never 2.5-VL-3B.

## 7. Strategy candidates for the ruling

Ordered by expected leverage; none yet ruled on.

1. **CPU-first text path** — rotation-aware OCR (PaddleOCR-class) → *bag-of-words*
   catalogue search (not title extraction) → ISBN-gate verify; GPU only on miss.
   Attacks wake frequency (the dominant cost term), responsiveness (~2–3s for
   whatever fraction resolves) and is naturally spine-shaped. The measured 23%
   Tesseract yield was a *selection* failure and predates the bag-of-words
   framing. `PENDING: resolution-rate measurement on the corpus.`
2. **L4 for the 7B as-is** — 24GB fits fp16 with no quantisation, Ampere gets
   maintained kernels, −27% rate, zero model risk. The AWQ dead-end and the
   offload discovery both point here.
3. **Cold-start attack** — smaller weights load proportionally faster (the 4B
   roughly halves the 20.5s load); `PENDING: verify Modal GPU memory snapshots`
   (would cut cold starts with no model change; feature status unconfirmed).
4. **Answer-now, confirm-right** — return the CPU tier's candidate immediately,
   GPU refines asynchronously; perceived latency becomes CPU-bound. Proposed
   responsiveness target to adopt with the ruling: p50 ≤ 5s, p95 ≤ 15s perceived.
5. **Digit-beam barcode rescue** — k candidates over OCR confusions, checksum +
   catalogue select. `PENDING: the false-accept measurement (perturb known-good
   ISBNs, count wrong-but-resolving) — the load-bearing unknown, measurable
   offline for free.`
6. **Model roles, not model swap** — 4B (or smaller specialist) where input is
   clean; 7B-class where it is degraded. Only meaningful after (1) exists.

## 8. What the ruling must decide

- [ ] GPU: stay A10G / move L4 / T4-with-mitigations — against criteria (a)–(c)
- [ ] Model: 7B as-is / 4B / role-split — ⚠️ gated on the spine stratum existing
- [ ] Build the CPU-first text path (and its measurement) — yes/no/scope
- [ ] Adopt the responsiveness target — p50 ≤ 5s / p95 ≤ 15s perceived, or other
- [ ] Scaledown window at the chosen configuration — re-run the frontier
- [ ] Disposition of pending items above if still pending at wave end

## Ruling

**Status: ACCEPTED (2026-11-17). Owner's decision, on a pre-stated condition:
"if the SLO gate passes for T4+4B, that's our new architecture."**

**GPU + model: T4 + Qwen3-VL-4B-Instruct (Apache 2.0).** The production SLO
gate — the same gate and thresholds that guard a prod deploy, run report-only
against a T4+4B preview with a 10-minute soak and 40 real uploads — **passed,
exit 0**: availability 1.0, 5xx 0.0, auth p95 232ms, catalogue 47ms,
bookshelves 242ms, upload 913ms (all ≤ their thresholds), upload success 1.0,
every circuit fuse closed. The GPU rate is −46% vs the A10G baseline.

⚖️ **What this ruling IS and IS NOT.** It is a decision that T4+4B holds the
**operational** KPIs the current stack holds, at lower cost — availability,
latency, error rate, stability. It is **NOT** a finding that the 4B matches the
7B on **identification accuracy**: §5 records the opposite — the 4B is perfect
on clean covers (clear_cover 22/22, rotation 12/12) and **weaker on degraded
input** (illegible 5/10 → 1/10, hostile_barcode −1, book_adjacent −1), and our
own eval slice gate refuses it as a drop-in. The owner adopts that trade
**knowingly**: cheaper and better on clean input, measurably weaker on poor
input, on a corpus that under-represents the stated primary case (spines,
varying quality).

⛔ **Named review trigger: the spine photographs.** The accuracy trade is
accepted *provisionally against the review trigger*, not closed. When the spine
stratum exists (LORA-DATASET.md §5 priority set), the 4B is re-measured on it;
if degraded-spine accuracy falls below a bar the owner sets then, this ruling is
revisited — either a role-split cascade (4B on clean input, a 7B-class fallback
on degraded) or a return to a larger model on L4.

**The L4 alternative, declined but recorded as the fallback.** L4 + 7B as-is
also passed every accuracy check (86/122, per-stratum identical to baseline) at
−27% rate and carries **zero accuracy risk**. It is the standing fallback if the
spine review rejects the 4B: it keeps the exact model and costs less than today,
just less than the T4.

### Decisions on §8

- [x] **GPU + model:** T4 + Qwen3-VL-4B. (L4 + 7B is the recorded fallback.)
- [x] **Responsiveness target REVISED 2026-11-17 to the architecture's physics
  (owner decision: keep T4+4B, revise the bar + make the tail honest).** The
  original p95 ≤ 15s was shown unmeetable on T4+4B synchronously: CPU-first tops
  out at a 63% resolution ceiling (negatives/adjacent/illegible need the GPU,
  measured U1) and GPU snapshots give no cold-path speedup on our T4 (measured
  U2: 24.8s restore vs 26.3s baseline). Rather than buy a different card for a
  tail number, the target is set to what a scale-to-zero $50/mo architecture
  actually delivers, as **time-to-ANSWER**:
    - **p50 ≤ 5s** — kept; met once CPU-first resolves the median (U1 path).
    - **p95 ≈ 30s** — the cold-start physics (≈26s), accepted, not fought.
    - **warm p95 ≤ 10s** — the number that holds once a reader is in a session.
    - **time-to-acknowledgement < 1s** — the async affordance below.
  ⬛ And C (make the tail honest): the EXISTING SSE stream delivers an immediate
  "identifying your book…" state and the verified result when ready. CPU-resolved
  answers are FINAL (the ISBN hard gate makes them non-speculative), so there is
  no wrong-then-corrected flicker — a cold wait is shown honestly, not frozen.
  ⚖️ This is B+C from the responsiveness fork, not a redefinition of "perceived"
  to paper over a missed bar: the slow tail is named and owned, and the product
  commits to fast acknowledgement + a fast median rather than a fast worst case.
- [ ] **CPU-first text path:** still YES as the next build — it is orthogonal to
  this hardware ruling and attacks the dominant cost term (wake frequency) and
  the spine case at once. Scoped as wave-8 work, not gated on this decision.
- [x] **Scaledown window at T4+4B: 60s, MEASURED 2026-11-17.** The preview cost
  harness (packed+spaced billing solve) measured T4+4B at COLD_LOAD=24.98s (clean;
  matches the 26s cold-wall), model fit exact. Frontier at those constants: at
  48 uploads/day the 60s window = **$21.98/mo** (vs 7B/A10G $37.60 — a 42% cut,
  tracking the rate delta), within budget through ~60/day. **Keep 60s at hobby
  scale.**
- [ ] ⛔ **Responsiveness is a MEASURED blocker, not a hypothetical — async is
  now a GATING requirement, not an optional optimisation.** The same frontier
  shows **p95 wait = 32.6s at every window**, because at hobby traffic ~94% of
  lone requests are cold and the cold path (cold-load 25s + inference) dominates.
  That is **2.2× over the adopted p95≤15s target**, and no window setting or GPU
  choice moves it — only a warm floor or the answer-now/confirm-later async
  pattern (§7 item 1/4) can. So the responsiveness target is unmeetable
  synchronously on the chosen architecture: the CPU-first path + async response
  is promoted from "next build" to a **precondition for meeting the responsiveness
  bar this ADR adopted**. (⚠️ the 32.6s carries the sequential-driving ACTIVE_S
  inflation, but cold-load alone keeps it far over 15s, so the conclusion holds.)

### Implementation consequences (follow-on, NOT done in this ADR)

1. **Default the sidecar to T4+4B** — `modal_app.py` / deploy config. Until this
   lands, production still runs 7B/A10G; the ruling is adopted, not yet shipped.
2. **Re-record the eval baseline to the 4B**, per the slice gate's own protocol
   (`--record`, naming in the commit which slice was sold and for what) — done
   *with* step 1, not before, so the baseline never describes a model that isn't
   the deployed one.
3. **Residue filed:** the suite's intermittent telemetry-test flake (seen twice
   this wave); the gate's upload-p95 metric is now meaningful (the probe fix made
   it read a real 913ms instead of a failed-fast 47ms) — caveat retired.

### What this ruling does not touch

The **writing assistant** half of the branch inherits none of this: ADR 025's
containment argument (verified identifier, not generated prose) does not extend
to it, and its model choice is its own decision. ⚠️ Its *substrate* is a
different matter — see Addendum §4.

---

## Addendum (2026-11-19): review findings, folded in before the build

A pre-build review of this ADR found the ruling sound and the following gaps.
They amend the implementation consequences; nothing below reopens the GPU/model
decision.

**1. Baseline protocol — the trade must expire, not compound.** Re-recording the
eval baseline to the 4B (consequence 2) makes the knowingly-accepted per-stratum
concessions (`illegible` 5/10 → 1/10, `hostile_barcode` −1, `book_adjacent` −1)
the *reference*, so later cascade work could regress against today's system while
every gate stays green. Protocol: the 4B-keyed baseline recorded with the swap is
the **interim drop-in gate only**. The **end-state bar for the full cascade**
(CPU tiers + GPU fallback, measured at the `/analyze` boundary) remains the
7B reference — **86/122, no stratum below its 7B score** — with the named
concessions tolerated *only until* the CPU-first path and the spine review land,
at which point the full-cascade score must meet or beat the reference or the
fallback ruling (L4 + 7B) is taken. The build wave's gate states both baselines
and which one each change answers to.

**2. The spine review trigger, armed.** The ruling's trigger had no bar, no date
and no owner — the shape a provisional ruling needs to become permanent by
default. Armed as: the owner shoots the 15–20 spine photographs
(`LORA-DATASET.md` §5 priority set); on arrival both models are scored on the new
stratum; **proposed bar, owner to confirm or replace when the stratum exists: the
4B's full-cascade spine score is no worse than the 7B's on the same set**. Below
the bar → role-split cascade or the recorded L4+7B fallback. The embedding-index
experiment and any LoRA work stay blocked behind this stratum
(`plans/vision-accuracy-program.md`, items 3 and 5).

**3. One alternative recorded as rejected, not unconsidered: hosted VLM APIs.**
Per-call pricing at this volume is cost-comparable with zero cold start —
rejected on grounds independent of cost: reader photographs are personal data
under a deletion promise (the photograph is destroyed ~24h after identification;
record at 30 days), and ADR 025's provenance posture. Shipping reader photographs
to a third-party inference API is a different privacy architecture, not a
cheaper instance of this one.

**4. The one-substrate brief, cross-referenced.** The 2026-10-14 ruling was one
substrate for recognition *and* blog writing. This ADR settles the GPU half; the
shared half is the **pgvector embedding substrate**
(`plans/vision-accuracy-program.md` §4a): the assistant needs a text-embedding
index regardless, and cover/spine embeddings ride the same index as a top-k
candidate generator over the reader's own catalogue. The serving story —
what runs where, its cold-start profile, cost at 10× — is **open design debt**
(discharged 2026-11-19: `docs/vision-embedding-substrate.md`),
carried to the build wave, not resolved by this paragraph.

**5. The promotion rule, consolidated.** The rule currently lives in four
places: the per-stratum slice gate, the production SLO gate, the revised
responsiveness targets above, and the cost frontier. The build wave wires them
into **one gate**: slice gate against the §1-addendum baselines (negatives
scored separately, never blended), the revised responsiveness thresholds
(p50 ≤ 5s, warm p95 ≤ 10s, acknowledgement < 1s) written into the SLO gate's
own thresholds — superseding the p95 ≤ 15s still printed in
`plans/vision-responsiveness-plan.md` — and the `/costs` Modal line re-based
from post-R0 measurements. A gate that cannot fail is not a gate: the wiring
ships with a planted-violation red run.

**6. `hostile_barcode` gets an owner.** The worst stratum (3/20) is attacked by
the digit-beam rescue, whose false-accept measurement (§7 item 5) was named
load-bearing and free, then landed in neither follow-on plan. It belongs to the
build wave's gate work: measure offline (perturb known-good ISBNs, count
wrong-but-resolving) before any rescue ships.

**7. Arrival rate: stop assuming.** Every cost figure above is a band on an
assumed rate while the platform already counts vision jobs and uploads. The
capacity model consumes the measured monthly rate from the existing cost
telemetry; the re-based `/costs` line cites it.

**8. Sequencing: R0 first.** The double-dispatch collapse
(`plans/vision-responsiveness-plan.md` R0) is free, invisible, gated on nothing —
and it changes the constants this ADR quotes (the harness measured
single-dispatch cost; real books pay two forward passes). It lands before the
4B swap so the re-based cost numbers describe the corrected dispatch, not the
accident.
