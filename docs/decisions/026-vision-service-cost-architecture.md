# ADR 026: Vision Service Cost, Hardware and Architecture — Wave 7 Findings

**Status:** Proposed — ⚠️ DRAFT for a ruling at the end of wave 7. Sections marked
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
| 1v2 | warmed clean re-run | `PENDING — mid-run` |
| 2 | T4 + `max_pixels=1003520` | `PENDING — queued` (expectation: marginal; cannot fix weight shuttling) |
| 3a | T4 + 7B bnb-int8 | ⛔ **Fits, and is unusable — the pre-registered prediction confirmed in the worst way.** 30/122 scored, 88 unscored: every success came from the CPU barcode tier and **zero VLM answers survived the HTTP serving path** (all died as upstream failures). The model answers through Modal's patient direct client, so this is pure inference speed: bnb-int8 on Turing is slow enough that every call outlives the caller. Fails criterion (b) absolutely. |
| 3b | T4 + 7B AWQ int4 | ⛔ **BLOCKED after three distinct toolchain failures** (gptqmodel missing → Triton AWQ kernel rejects the vision-merger shape on sm75 → autoawq demands IPEX on a CPU builder). ⬛ Finding: the quantisation ecosystem has moved past Turing; fast kernels (Marlin) start at Ampere. |
| 4 | T4 + Qwen3-VL-4B fp16 | ✅ **84/122, 0 unscored.** Perfect clear_cover (22/22) and rotation (12/12); **illegible collapsed 5/10 → 1/10**, hostile_barcode −1, book_adjacent −1. Latency T4-viable (cls p50 7.0s ≈ A10G 7B). ⚖️ As a drop-in swap, **our own slice gate refuses it** — correctly. As a cascade role-player (clean input only), strongest candidate measured. |

Harness facts with standing value: Modal binds **decorator args at deploy time but
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

`EMPTY — to be made at the end of wave 7.`
