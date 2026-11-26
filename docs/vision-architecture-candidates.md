# Vision recognition: candidate architectures and the measurement plan

Research input for the vision-architecture ADR. ⛔ **This file exists because the research it records
was living only in an issue file, and `issues/` is gitignored** — so the evidence an ADR argues from
would not have survived a clone or been reviewable in a PR.

Owner ruling: do the redesign **once**, for the whole AI ecosystem — book recognition *and* blog
writing — rather than taking an interim quantised-model stepping stone. Drive cost as low as it goes
at a few hundred users.

## The number the decision turns on

⬛ **Most of an identification's cost is a GPU waiting rather than working — and how much
depends on traffic shape, so it is a range, not a figure.**

| traffic shape | idle share | cost per identification |
|---|---|---|
| **one upload after a quiet period** (the common case at a few hundred users) | **~90%** | **~9.8 c** |
| **40 consecutive identifications** (measured, 5 runs × 8 fixtures) | **≥60%** | **≥0.429 c** |
| perfect amortisation, zero idle (the floor) | 0% | 0.176 c |

⚠️ **Quote the condition with the number.** An earlier version of this document stated "~90%"
alone, as if it were the figure rather than one end of a range; it also attributed "89%" to the
decomposition harness, which never produced that number. The sustained figure is a **lower bound**
(see below), and corroboration from `modal billing report` put a real billing period at **84%**,
which sits inside the range exactly as expected for mixed traffic.

⚖️ **What makes a decision possible despite the range:** any tier that answers without waking a
GPU removes the idle tail entirely, so the *sign* of the effect is prevalence-independent even
though its size is not. That is why the promotion rule is a safety gate plus a cost sensitivity
band, and not a single cost figure.

### ⚠️ The idle figure is a lower bound, and the wire is why

Idle is bounded, not measured. `gpu_container_age_s` was removed from the response as
double-counting — which was half right: age-at-last-inference is active time *plus* the warm gaps
between requests, and those gaps are billed. Without it, idle can only be bounded from the run
timestamps (span + one scaledown window − active). On the measured series the window-only model
said 300 s where the bound says **334 s**, so the model that ships on the cost page undercounts in
the direction that makes the GPU look cheap.

### ⛔ The 300-second scaledown window is a knob, and it is not priced here

`scaledown_window=300` is a literal in the sidecar, chosen for a cold-start latency reason that was
never priced in money. Shortening it captures much of the same saving as an architecture change:

| window | lone cold identification |
|---|---|
| 300 s (today) | 9.81 c |
| 120 s | 4.30 c |
| 60 s | 2.46 c |

⬛ **So "the GPU is 56× above its floor" does not by itself justify a redesign** — a 60 s window is
a ~4× reduction on the lone-upload case for one literal. The ADR must place a GPU-free tier on that
frontier rather than against today's window, or it will credit the redesign with a saving a
parameter change would have delivered. ⚠️ The latency cost of a shorter window is real and
unmeasured; that is the trade the ADR has to make, and it needs both numbers.

### ⚠️ Latency: the first request of a run is the slow one, and that is not transport

Wall time minus GPU stage, by position in the run (median of 5 runs):

| position | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| residual (ms) | **5,283** | 2,692 | 2,836 | 2,626 | 2,062 | 2,000 | 1,902 | 1,827 |

⛔ **A monotone warm-up curve (Spearman ρ = −0.976 against position), not a per-request transport
cost.** An earlier version of this document read the barcode tier's 5.3 s residual as upload and
network overhead that "every tier pays". It is not: the barcode fixture is always case #1, and the
upload hypothesis is directly falsified by payload size — a 108 KB image at position 3 carries a
2,836 ms residual while a 20 KB image at position 1 carries 5,283 ms. Five times the bytes, half
the residual. ⚠️ The corpus runs in a fixed order, so tier and position are confounded; permuting
fixture order per run would decorrelate them and costs nothing.

⚖️ **The CPU case is stronger than the transport reading suggested, for a different reason.**
Against the real non-first-request envelope (~2.4 s residual), a CPU tier at ~200 ms of compute
lands near **2.6 s** against VLM_EXTRACT's measured **9,745 ms** p50 — roughly a **3.7× latency
improvement**, not the "close to invisible" an earlier version claimed. ⚠️ `download` reads 0 ms in
all 40 cases, so ~108 s of wall time is genuinely unattributed; "transport" remains a hypothesis,
not a reading.

## Shortlist

### 1. OCR + text match — a producer swap at an existing production seam
`ISBNResolver.search_by_title/4` is a two-level-cached production title→ISBN path, already called at
the vision-output seam. The match target is the whole Open Library / Google Books corpus; there is no
index. Missing hop:

```
image → [OCR engine: MISSING] → {title, author, raw_text} → Moderation → search_by_title
      → ISBN → hard gate → edition
```

One `requirements.txt` line plus one sidecar function. No OCR engine ships today — the existing
"local OCR" is `pyzbar` **barcode** decoding only. Metric: `P(OCR yields a title the existing cached
search already resolves)`. Licence: Tesseract / PaddleOCR, both Apache-2.0.

### 2. SigLIP 2 ViT-B/16 — cover embedding, CPU-feasible
86M params, **Apache-2.0**, **768**-dim float32. ~130 ms (INT8) to ~220 ms (FP32) per image on
desktop CPU.

### 3. DINOv2 ViT-B/14 — favoured on near-duplicate retrieval
**Apache-2.0**, confirmed from the repository's own `## License` section.

### Rejected, with reasons
- **DINOv3** — bespoke "DINOv3 License", not Apache. The clause that bites a source-available
  project is **§1.b.i pass-through**: distributing the materials or any derivative requires shipping
  a copy of the agreement. **§8** lets Meta modify the agreement unilaterally, *"effective
  immediately"* — a stronger objection than the litigation-termination clause. §1.b.iv bars reverse
  engineering, which a quantised export should be checked against. ⚖️ Rejected on **legal posture,
  not capability**; it is likely the strongest model. Revisit only if (2) and (3) both fail on recall.
  ⚠️ The licence contains no non-commercial restriction and no purpose limit, but never affirmatively
  permits commercial use — a reasonable reading, not a quotable fact.
- **A smaller/quantised VLM** — declined by owner ruling as the interim stepping stone.
- **CLIP** — superseded. SigLIP 2 gained only 1.2 mAP over SigLIP on retrieval; CLIP scored 28.45%
  against DINOv2's 64% on DISC21 ⚠️ *which is Meta's own benchmark*.

⬛ These are **complementary, not competing**. The current cascade is barcode → VLM with nothing
between, and candidates 1 and 2 both sit in that gap.

## The index-scale fork — resolved

`op.book_editions` is **downstream** of identification, so an index over the local catalogue can only
recognise a book someone already identified — a **re-identification cache**, worth ≈0 at launch. The
alternative is an index over the addressable corpus. At 768-dim float32 with HNSW at 2×:

| index population | +HNSW | fits | one-time CPU build |
|---|---|---|---|
| 20,000 | 0.12 GB | 512 MB | ~4 s |
| **~100,000 — the books people shelve** | **0.61 GB** | **2 GB** | **3.6 h @130 ms** |
| 1,000,000 | 6.14 GB | 8 GB | 36 h |
| ~10,000,000 | 61.4 GB | >8 GB | 360 h |

**Resolved: ~100k.** First-sighting recognition, no GPU in the request path, recall over that index
is the right metric and prevalence does not arise. **RAM is the binding constraint**, not disk —
pgvector wants the HNSW index resident.

⚠️ **There is no local cover corpus.** `cover_image_url` is a third-party URL and
`Storage.store_cover/3` was deleted having never written an object, so building the index means a
**bulk fetch of ~100k covers from Open Library** — sustained third-party load with rate limits and
terms to respect. The one cost here that is neither CPU nor storage.

## There is no text-embedding substrate to share

`op.embeddings` is a schema with an HNSW cosine index and **no producer**: 0 rows,
`together_client.ex` serves only completions, and the `bge-m3` references are a test factory, the
proto, and design docs. **Both halves are unbuilt**, so one story can be chosen for two unbuilt
consumers rather than retrofitted.

⚠️ **Do not put cover vectors in `op.embeddings`.** It is user-scoped and GDPR-PERSONAL
(`user_id null: false`, `on_delete: :delete_all`); a cover vector is per-edition and non-personal, so
a user deletion would erase catalogue data. The schema already carries two `vector(1024)` columns and
pgvector dimensions are per-column — separate columns are the status quo, not a compromise, and no
two encoders need to agree on width.

## Measurement plan

**Corpus: the plan's 155**, per `vision-eval-corpus-plan.md`'s nine strata and distribution rule.

⚠️ **~45 of the 155 are rejection strata**, where recall@k is **undefined for a retriever** — so
recall-usable N is ~110. At 155 the **aggregate** ranking of two architectures is sound (0.6
points/image); **per-stratum rankings are DIRECTIONAL only**. Per-stratum verdicts would need ~40 per
recall-bearing stratum ≈ 285 total, nearly twice the plan — a decision about effort, taken knowingly.

**Metrics, per candidate, per stratum:** recall@1, recall@5 **and precision@1 via a similarity
threshold sweep**, reported as a curve with the operating point fixed by a stated rule, so candidates
are compared at **equal safety**. Plus query latency p50/p95 on CPU and the smallest viable GPU, and
index build time and storage.

⚠️ **Repeat runs and report n.** Three runs of the current corpus showed vlm-cls **median variance
60%**, **max 6.8×**; a single run ranks nothing.

⚠️ **This is cross-domain retrieval** — publisher renders indexed, reader photographs as queries.
That is *not* what DISC21 measures (edited copies of index images), so fix the index's provider and
resolution and do not inherit those leaderboards.

## The promotion rule

1. **Safety — the corpus settles this, and it gates promotion absolutely.** No regression in
   precision@1 on any stratum, and false-accept on the rejection strata ≤ the VLM's current rate.
2. **Cost — the corpus does NOT settle this.** Converting recall into cost needs traffic prevalence,
   which a deliberately boundary-weighted corpus cannot supply. Report **fall-through rate per
   stratum** and state cost as a **sensitivity band** across plausible prevalences. A single cost
   figure would be the corpus's weighting masquerading as traffic.

⬛ The ISBN hard gate gives these candidates **no precision protection**: it proves an ISBN resolves,
never that it is the right book for this photograph — and for a catalogue retriever it is satisfied
by construction. precision@1 is the only defence.
