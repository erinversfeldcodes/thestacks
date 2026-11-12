# Vision recognition: candidate architectures and the measurement plan

Research input for the vision-architecture ADR. ⛔ **This file exists because the research it records
was living only in an issue file, and `issues/` is gitignored** — so the evidence an ADR argues from
would not have survived a clone or been reviewable in a PR.

Owner ruling: do the redesign **once**, for the whole AI ecosystem — book recognition *and* blog
writing — rather than taking an interim quantised-model stepping stone. Drive cost as low as it goes
at a few hundred users.

## The number the decision turns on

Measured on a deployed stack: **9c idle against 1c inference** per identification, so **~90% of the
cost is a GPU waiting rather than working**. Corroborated three ways — an independent ~93% reading,
`modal billing report` at 84% idle, and the decomposition harness at 89%. Latencies: barcode ~7 ms,
VLM warm ~5.2 s, VLM cold ~20.5–32.9 s, with a 300 s scaledown window per woken container.

⬛ **The target is therefore the idle tail, not inference speed.** Any tier that answers a request
without waking a GPU removes ~10c, and the *sign* of that effect is independent of how often the tier
fires — which is what makes a decision possible without traffic prevalence.

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
