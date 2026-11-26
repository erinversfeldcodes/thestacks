# Small Vision-Language Models and Task Specialisation for Reading Book Covers on a T4

Research date: 2026-11-13. Scope: can a sub-4B model, specialised before deployment, match the
measured 91% clear-cover accuracy of Qwen2.5-VL-7B on A10G, while fitting a T4 and a $50/month
inference budget?

**A note on benchmark scales that runs through everything below.** There are at least three
incompatible "OCRBench" numbers in circulation and they are routinely mixed in model cards and
leaderboards:

- **Original OCRBench**: raw points out of **1000** (e.g. InternVL3-2B at 835, InternVL3-78B at 906).
- **Original OCRBench reported as a percentage** out of 100 (some cards divide by 10, e.g. SmolVLM2's 72.9).
- **OCRBench v2**: a different benchmark reported as a **percentage**, with separate English and
  Chinese averages across 8 and 5 task categories respectively. Scores are much lower —
  Qwen2.5-VL-7B sits at 41.8 EN / 49.5 ZH.

A 822 and a 47.5% in the same table are not rankable against each other
([search synthesis across OCRBench sources](https://99franklin.github.io/ocrbench_v2/)). Every
number below is labelled with its scale. Do not let a report collapse them.

---

## Key Question 1: What small VLMs (under ~4B) are credible in 2026 for text-in-image reading?

### Takeaway

The credible sub-4B field in late 2026 is led by **Qwen3-VL-2B / 4B (Apache-2.0)**, which supersedes
Qwen2.5-VL-3B and fixes that model's fatal licence problem; **InternVL3.5-2B (Apache-2.0)**;
**SmolVLM2-2.2B (Apache-2.0)**; and a cluster of 3B *OCR-specialist* fine-tunes (dots.ocr,
DeepSeek-OCR, Nanonets-OCR2). Florence-2 and Moondream2 are small and permissively licensed but are
an older generation with materially weaker document/text scores. The binding deployment constraint
is not parameter count but the T4's Turing architecture: no bf16 tensor cores and no FlashAttention-2.

### Cited Findings

**Qwen family**

- Qwen3-VL-4B-Instruct is listed on its Hugging Face model card as **License: apache-2.0**, with
  "4B params" and BF16 tensor type. The card gives **no numeric OCR benchmark scores** — its
  performance charts are images — and states no VRAM requirement. It recommends `flash_attention_2`
  for multi-image and video use. It supports 32 languages, up from 19 — [Qwen3-VL-4B-Instruct model card](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct)
- Qwen3-VL-2B-Instruct is reported as Apache-2.0 by multiple third-party mirrors and hosts —
  a Hugging Face mirror carries the Apache 2.0 notice crediting Qwen/Alibaba, Voxel51's model zoo
  lists "Apache-2.0", Mixpeek shows the `license:apache-2.0` tag, and Ollama's page includes the
  Apache 2.0 text — but I could **not** confirm it from the official Qwen repo page directly — [Voxel51 model zoo](https://docs.voxel51.com/model_zoo/models/Qwen_Qwen3_VL_2B_Instruct.html); [Mixpeek listing](https://mixpeek.com/model/Qwen/Qwen3-VL-2B-Instruct); [Ollama](https://ollama.com/library/qwen3-vl:2b-instruct/blobs/7339fa418c9a)
- A Qwen3.5-0.8B model card's comparison table gives **OCRBench 80.8 for Qwen3-VL-4B and 79.2 for
  Qwen3-VL-2B** (percentage scale) — [Qwen3.5-0.8B README](https://huggingface.co/Qwen/Qwen3.5-0.8B/blob/main/README.md)
- A third-party guide gives conflicting figures for the 4B — roughly 85% (Instruct) and 86%
  (Thinking) — [codersera Qwen3-VL-4B vs 8B](https://codersera.com/blog/qwen3-vl-4b-vs-qwen3-vl-8b-benchmarks-vram-guide/)
- On **OCRBench-V2 English** (percentage scale), Qwen3-VL-4B-Instruct ranks 8th at **63.70%** and
  4B-Thinking at 61.80%, both dated 2026-11-08 — [llmboard OCRBench-V2 EN](https://www.llmboard.ai/benchmarks/ocrbench-v2-en-456)
- Qwen2.5-VL-3B-Instruct reports **DocVQA(test) 93.9, InfoVQA(test) 77.1, TextVQA(val) 79.3**;
  OCRBench and ChartQA are not reported on the card, and no VRAM figure is given. The card's
  Safetensors metadata says "4B params" while the prose says 3B — the card is internally
  inconsistent — [Qwen2.5-VL-3B-Instruct model card](https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct)
- Qwen2.5-VL-7B (the measured baseline's model) scores **41.8 EN / 49.5 ZH on OCRBench v2**, and
  is listed on that leaderboard as "8B" — [OCRBench v2 leaderboard](https://99franklin.github.io/ocrbench_v2/)

**InternVL**

- InternVL3.5-2B's Hugging Face page states "This project is released under the **apache-2.0**
  License" and notes it uses pre-trained Qwen3 as a component — [OpenGVLab/InternVL3_5-2B](https://huggingface.co/OpenGVLab/InternVL3_5-2B)
- InternVL3-2B pairs InternViT-300M-448px-V2.5 with a Qwen2.5-1.5B language model. A comparison
  table in the InternVL3.5 paper lists InternVL3-2B at **OCRBench 835** (out of 1000) with DocVQA
  88.3 and InfoVQA 66.1 — this was read off column alignment in the search result, so treat the 835
  as likely but unconfirmed — [InternVL3.5 paper](https://arxiv.org/html/2508.18265v1)
- InternVL3-78B is cited in the InternVL3 paper as attaining "a remarkable OCRBench score of 906" —
  [InternVL3 paper](https://arxiv.org/pdf/2504.10479)
- On OCRBench v2, InternVL2.5-8B scores 40.5 EN / 42.8 ZH and InternVL3-8B 45.3 EN / 49.0 ZH; no
  sub-4B InternVL entry appears on that leaderboard — [OCRBench v2 leaderboard](https://99franklin.github.io/ocrbench_v2/)

**SmolVLM2**

- SmolVLM2-2.2B-Instruct is released under **Apache 2.0** ("We release the SmolVLM2 checkpoints
  under the Apache 2.0 license"), scores **OCRBench 72.9** and **DocVQA(val) 79.98**, and pairs a
  SigLIP image encoder with a SmolLM2 text decoder. It needs about **5.2 GB of GPU RAM for video
  inference** — [SmolVLM2-2.2B-Instruct model card](https://huggingface.co/HuggingFaceTB/SmolVLM2-2.2B-Instruct)

**Moondream**

- moondream2 is **Apache 2.0** on its official card, and is explicitly marked as "the previous
  generation". Benchmarks for the 2024-08-26 release: **TextVQA 65.2, DocVQA 70.5** (VQAv2 80.3,
  GQA 64.3). A later changelog in a mirrored README reports DocVQA rising to 79.3 and TextVQA to
  76.3, and OCRBench rising from 58.3 to 61.2 (percentage scale) — [vikhyatk/moondream2](https://huggingface.co/vikhyatk/moondream2)
- Reported parameter counts for moondream2 disagree across sources: ~1.87B (PromptLayer), "just 1.6
  billion" (The Decoder), ~1.7B elsewhere — [PromptLayer](https://www.promptlayer.com/models/moondream2); [The Decoder](https://the-decoder.com/seattle-startup-shrinks-computer-vision-ai-to-fit-in-your-pocket/)
- Moondream 3.1 is **9B total / 2B active** (mixture-of-experts), 32K context, released under the
  bespoke "Moondream Model License" v1.0. Its OlmOCR score of **32.37 is marked preliminary** and
  the page warns benchmark figures may change before public release. It runs locally on **NVIDIA
  Ampere or newer** and Apple Silicon — [moondream/moondream3.1-9B-A2B](https://huggingface.co/moondream/moondream3.1-9B-A2B)
- Moondream 3 Preview weights are under **Business Source License 1.1** with an Additional Use
  Grant; commercial hosting or rehosting requires an agreement with contact@m87.ai; the licence
  converts to Apache 2.0 two years after first public release — [Moondream docs](https://docs.moondream.ai/)
- A third-party listing notes that for Moondream "small text in images needs a dedicated OCR model",
  i.e. fine print is a known weak point — [FreeAPIHub](https://freeapihub.com/ai-models/moondream-3)

**Florence-2**

- Florence-2 is **MIT**-licensed from Microsoft Research. Florence-2-large is **0.77B** parameters,
  Florence-2-base is **0.23B**. OCR is invoked with the `<OCR>` prompt token returning plain text,
  or `<OCR_WITH_REGION>` returning `quad_boxes` (8 coordinates each) plus a `labels` list of
  recognised text. Output formatting differs between checkpoints — one fine-tuned variant inserts
  `\n` line separators — [Roboflow Florence-2](https://blog.roboflow.com/florence-2/); [Roboflow inference docs](https://inference-models.roboflow.com/models/florence2/)
- Florence-2 runs at **roughly one second per image on an NVIDIA T4**; CPU inference is possible but
  slow — [Roboflow Florence-2](https://blog.roboflow.com/florence-2/)
- Florence-2 does **not appear** on the OCRBench v2 leaderboard — [OCRBench v2](https://99franklin.github.io/ocrbench_v2/)

**PaliGemma 2** — see Key Question 2; its licence disqualifies it before benchmarks matter.

**Sub-4B OCR specialists (not general VLMs)**

- OCRBench v2 sub-4B entries: **dots.mocr (3B) 43.3 EN / 50.6 ZH** (2026.03 table), **LFM2.5-VL-3B
  42.6 EN / 37.9 ZH** (2026.09), Ovis1.6-3B 38.0/31.7, MiniCPM-V-4.6 (1B) 40.4/52.3,
  Janus-1.3B 14.3/7.5. Note dots.mocr at 43.3 EN **exceeds Qwen2.5-VL-7B's 41.8 EN** on the same
  leaderboard — [OCRBench v2 leaderboard](https://99franklin.github.io/ocrbench_v2/)
- Hugging Face's OCR model round-up table (OlmOCR Bench average): **dots.ocr 3B — 79.1 ± 1.0**,
  **DeepSeek-OCR 3B — 75.4 ± 1.0**, OlmOCR-2 8B — 82.3 ± 1.1, Chandra 9B — 83.1 ± 0.9. It also
  lists PaddleOCR-VL at 0.9B and Granite-Docling-258M, both without scores — [HF blog: Supercharge your OCR Pipelines with Open Models](https://huggingface.co/blog/ocr-open-models)
- dots.ocr-1.5 (3B) reports **OCRBench 86.0** (percentage scale) — [davanstrien/dots.ocr-1.5](https://huggingface.co/davanstrien/dots.ocr-1.5/blob/main/README.md)

**T4 / Turing hardware constraints (the real gate)**

- Upstream **FlashAttention-2 does not support Turing**: the project states it "currently supports
  Ampere, Ada, or Hopper GPUs" and that "FlashAttention 1.x should be used on Turing for now". Its
  bf16 path likewise requires Ampere or newer — [Dao-AILab/flash-attention issue #720](https://github.com/Dao-AILab/flash-attention/issues/720)
- **bf16 tensor cores arrived with Ampere (compute capability 8.0); Turing is 7.5.** Running bf16 on
  Turing falls back to non-tensor-core matmuls with "typical slowdown is 2–4× on Turing" —
  [InvokeAI issue #9153](https://github.com/invoke-ai/InvokeAI/issues/9153)
- A Turing fork of FlashAttention states "Turing implementation supports FP16 precision only" —
  [flash-attention-2080ti](https://github.com/farnghwai/flash-attention-2080ti)
- Recommended mitigation on T4-class GPUs: FlashAttention 1.x or PyTorch memory-efficient attention;
  loading code should fall back to fp16 when bf16 is requested on pre-Ampere GPUs — [Perlod hosting guide](https://perlod.com/tutorials/flash-attention-hosting/); [HF commit adding the fp16 fallback](https://huggingface.co/my-ai-stack/Stack-2-9-finetuned/commit/bdf34ba766c828c935cc70eaa9bf8cd58f414ed8)

### Inferences

- **Qwen3-VL-2B/4B is the single most decision-relevant finding.** It is the direct successor to the
  baseline model family, is confirmed Apache-2.0 at 4B, and its OCRBench-v2 EN score (63.70%)
  is ~22 points above the Qwen2.5-VL-7B figure (41.8%) on a comparable v2 scale. If that holds, the
  "small vs large" trade-off the project assumed may simply have been dissolved by a generation
  change — a 4B 2026 model plausibly beats the measured 7B 2025 baseline *before* any specialisation.
  This should be measured against the project's own corpus before anything else is attempted.
- **Qwen3-VL-4B's card declares BF16 tensors and recommends FlashAttention-2 — both unavailable on
  T4.** Expect to load in fp16 with SDPA/memory-efficient attention. This is a correctness risk
  (fp16 overflow in a model trained in bf16) as well as a speed one, and it needs a measured check,
  not an assumption.
- Florence-2's measured ~1s/image on a T4 is the only *first-party-ish* T4 latency datapoint found
  for any candidate, and it is for a 0.77B model. A 2–4B model on the same hardware without
  FlashAttention-2 will be meaningfully slower; budget planning should assume several seconds per
  image, not one.
- Moondream 3.x is architecturally interesting (2B active params) but is disqualified twice over:
  bespoke licence (KQ2) and an Ampere-or-newer requirement that excludes the T4 outright.
- Florence-2 and moondream2 are both permissively licensed and T4-friendly but are a 2024-generation
  capability. moondream2's DocVQA 70.5–79.3 versus Qwen2.5-VL-3B's 93.9 is a large gap on a
  text-reading task. They are credible only as *fine-tuning bases*, not as drop-in replacements.

### Gaps

- **No model card found states VRAM at inference** for Qwen3-VL-2B/4B, Qwen2.5-VL-3B, or
  Florence-2. The only concrete figure is SmolVLM2-2.2B at ~5.2 GB for video inference. The T4's
  16 GB is almost certainly sufficient for any sub-4B model in fp16, but this is inference from
  parameter count, not a cited measurement, and it ignores the vision-encoder activation cost at
  high image resolutions — which for Qwen-VL scales with the pixel budget.
- **Qwen3-VL-2B's licence is not confirmed from the official repo.** Four third-party sources agree
  on Apache-2.0 and none contradict it, but the authoritative check (the `license` field on
  `huggingface.co/Qwen/Qwen3-VL-2B-Instruct`) was not completed. Do this before committing.
- **Qwen3-VL-4B's own card publishes no numeric OCR scores** — its charts are images. The 80.8/79.2
  figures come from a *different* model's comparison table, and a third-party guide contradicts them
  (~85/86%). The OCRBench-v2 EN figure (63.70%) is from a leaderboard, not the authors.
- The InternVL3-2B OCRBench figure (835) was derived from column alignment in a search result, not
  read from the paper's table directly.
- No OCRBench score found for the original dots.ocr 3B; the 86.0 belongs to dots.ocr-1.5, which
  carries different licence terms.
- **No book-cover-specific benchmark exists** in any of these leaderboards. Every score above is on
  documents, charts, and scene text — none is a photograph of a book cover with glare, perspective
  skew, and stylised display type. The project's own 91% measurement is more informative than any
  published number here.

---

## Key Question 2: Licence posture — applying the DINOv3 standard

### Takeaway

**Qwen2.5-VL-3B is disqualified**: unlike its 7B sibling it ships under the Qwen Research License,
non-commercial only. **PaliGemma 2 is disqualified** on precisely the DINOv3 grounds — bespoke
Google terms with an explicit pass-through clause requiring the agreement to travel with every
derivative. **Moondream 3.x is disqualified** (BSL 1.1 / bespoke Moondream License). The clean
Apache-2.0 / MIT set is: Qwen3-VL-2B/4B, InternVL3.5-2B, SmolVLM2-2.2B, moondream2, Florence-2 (MIT),
PaddleOCR / PP-OCRv5, and dots.ocr (MIT, with the 1.5 revision adding supplementary terms).

### Cited Findings

**Disqualifying: Qwen2.5-VL-3B (the obvious candidate) is non-commercial**

- The official LICENSE file on the Qwen2.5-VL-3B-Instruct repo is the **Qwen Research License**,
  which defines "Non-Commercial" as research or evaluation only; commercial users must request a
  licence from Alibaba — [LICENSE on Qwen/Qwen2.5-VL-3B-Instruct](https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct/blob/main/LICENSE)
- Jina AI, when building jina-embeddings-v4 on Qwen2.5-VL-3B, **contacted the Qwen team directly for
  permission**, and noted its agreement covered publishing the model but **not** commercial use —
  [HF discussion on jinaai/jina-embeddings-v4](https://huggingface.co/jinaai/jina-embeddings-v4/discussions/44)
- Corroborated by Wikiwand's Qwen model table ("Qwen Research" for the 3B variant) and by ai-tldr's
  description of the 3B as restricted to non-commercial use — [Wikiwand: Qwen](https://www.wikiwand.com/en/Qwen); [ai-tldr Qwen2.5-VL](https://ai-tldr.dev/models/qwen2-5-vl/)
- **One source contradicts this**: openlaboratory.com lists the model as Apache-2.0. It is a
  third-party aggregator contradicting the repo's own LICENSE file and should be discounted —
  [openlaboratory](https://openlaboratory.com/models/qwen2_5-vl-3b-instruct/)
- Note: the Qwen2.5-VL **7B and 72B** are Apache-2.0; only the 3B carries the research licence. The
  project's existing 7B baseline is therefore *not* affected.

**Disqualifying: PaliGemma 2 — the DINOv3 pattern, almost clause for clause**

- PaliGemma 2's Hugging Face model pages route to **Google's Gemma Terms of Use** at
  `ai.google.dev/gemma/terms`; the Gemma Terms appendix explicitly covers "PaliGemma and PaliGemma 2"
  — [google/paligemma2-3b-pt-896](https://huggingface.co/google/paligemma2-3b-pt-896)
- **The pass-through clause the project already rejected once**: under Section 3, anyone distributing
  the model or derivatives must include the use restrictions referenced in §3.2 **as an enforceable
  provision in their own agreements**, and must give "all third party recipients of Gemma or Model
  Derivatives a copy of this Agreement" — [Gemma Terms of Use](https://open.windriver.com/info/uni-license-list/licenses/gemma-tou-2025-03-24.html)
- Commercial use is permitted but "subject to the terms of the Gemma Prohibited Use Policy", and a
  hosted API counts as distribution — [vorplabs Gemma licence summary](https://vorplabs.com/models/gemma-license)
- The Gemma licence has been flagged as **likely incompatible with CC-BY-4.0** in at least one
  model-card dispute, showing the downstream-compatibility friction is real, not theoretical —
  [HF discussion](https://hface.pages.dev/kyutai/moshika-vis-pytorch-bf16/discussions/3)
- An additional unresolved conflict: a Hugging Face discussion flags that the PaliGemma model card
  contains a "for research purposes only" statement that conflicts with the Gemma licence reference
  — [HF discussion on paligemma-3b-mix-224](https://huggingface.co/google/paligemma-3b-mix-224/discussions/7)
- **Gemma 4 moved to Apache 2.0**, but earlier Gemma models including PaliGemma 2 remain under the
  custom terms — [vorplabs](https://vorplabs.com/models/gemma-license)
- A Roboflow page claims PaliGemma 2 is under a "Tongyi Qianwen License" from Alibaba. This
  contradicts every Google source and is an error — [Roboflow](https://playground.roboflow.com/models/google/paligemma-2)

**Disqualifying: Moondream 3.x**

- Moondream 3 Preview is **Business Source License 1.1** with an Additional Use Grant. Personal
  projects and self-hosting inside a company (including commercial use) are allowed, but commercial
  *hosting or rehosting* requires an agreement with contact@m87.ai. The licence converts to Apache
  2.0 two years after first public release — [Moondream docs](https://docs.moondream.ai/)
- Moondream 3.1 moved to a **bespoke "Moondream Model License" v1.0** (HF tag
  `moondream-model-license-1.0`), which the team describes as "the same underlying theme as before,
  but simpler to understand" — [moondream3.1-9B-A2B card](https://huggingface.co/moondream/moondream3.1-9B-A2B); [Moondream blog](https://moondream.ai/blog/moondream-3-1-beyond-benchmarks)

**Clean: Apache-2.0 / MIT**

- **Qwen3-VL-4B-Instruct: apache-2.0**, stated on the official card — [model card](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct)
- **InternVL3.5-2B: apache-2.0**, stated on the official page — [OpenGVLab/InternVL3_5-2B](https://huggingface.co/OpenGVLab/InternVL3_5-2B)
- **SmolVLM2-2.2B: Apache 2.0**, stated on the official card, corroborated by Roboflow and
  PromptLayer, with no conflicting source found — [model card](https://huggingface.co/HuggingFaceTB/SmolVLM2-2.2B-Instruct)
- **moondream2: Apache 2.0**, on the official card — [vikhyatk/moondream2](https://huggingface.co/vikhyatk/moondream2)
- **Florence-2: MIT** (Microsoft Research), with the LICENSE file in the Microsoft repo —
  [Roboflow model page](https://inference-models.roboflow.com/models/florence2/)
- **PP-OCRv5: Apache License 2.0**, per the Baidu AI Studio model page metadata —
  [AI Studio](https://aistudio.baidu.com/modelsdetail/28601)
- **dots.ocr (3B): MIT**, ungated, per the GitHub mirror's licence field and third-party listings.
  **But dots.ocr-1.5 is "other" — a custom `dots-ocr-license` "based on the MIT License with
  supplementary terms covering responsible use, attribution, and data governance"** —
  [davanstrien/dots.ocr-1.5](https://huggingface.co/davanstrien/dots.ocr-1.5/blob/main/README.md); [ecosyste.ms listing](https://awesome.ecosyste.ms/projects/github.com%2Frednote-hilab%2Fdots.ocr)
- An EMD123 re-upload of dots.ocr-1.5 states "the model was removed from huggingface, so I re-uploaded
  it here from modelscope" — the model's availability has already changed once —
  [EMD123/dots.ocr-1.5](https://huggingface.co/EMD123/dots.ocr-1.5)

**Unclear — treat as disqualified until proven**

- **Nanonets-OCR2-3B**: Hugging Face's own OCR round-up table labels its licence **"Unclear"**, in a
  table where every other entry is "Open-source" or "OpenRAIL" — [HF blog: OCR open models](https://huggingface.co/blog/ocr-open-models)
- Its model card names `Qwen/Qwen2.5-VL-3B-Instruct` as `base_model`, and a community thread argues
  Nanonets models derived from that base are "subject to 'Qwen RESEARCH LICENSE AGREEMENT'" — one
  user's claim, not an official statement — [HF discussion #35](https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct/discussions/35)
- Counter-example showing it is not automatic: **OCRFlux-3B, also a Qwen2.5-VL-3B fine-tune, declares
  `license: apache-2.0`** on its card. A fine-tune's declared licence can differ from its base's —
  which means at least one of the two is wrong about its rights — [ChatDOC/OCRFlux-3B](https://huggingface.co/ChatDOC/OCRFlux-3B/blob/7a9d91bb8771a922b92a5517c8c8883961d67aa6/README.md)
- **Chandra (9B) is OpenRAIL**, which carries use restrictions and is not an OSI-approved permissive
  licence — [HF blog: OCR open models](https://huggingface.co/blog/ocr-open-models)

### Inferences

- **PaliGemma 2 fails the exact test DINOv3 failed.** The §3 clause requiring the agreement to be
  passed to all third-party recipients and the use restrictions to be made enforceable in your own
  downstream agreements is structurally the same pass-through obligation that was rejected.
  For a source-available project that wants contributors to be able to fork without inheriting a
  Google-authored contract, this is a hard no regardless of benchmark.
- **The Qwen2.5-VL-3B licence finding is the kind of trap that is easy to miss**, because the *same
  model family at 7B* is Apache-2.0. Any plan that says "shrink from 7B to 3B in the same family"
  silently crosses a licence boundary. Qwen3-VL-2B/4B is the way to get a small Qwen *and* keep
  Apache-2.0.
- **A base model's licence propagates to fine-tunes, and the ecosystem is inconsistent about this.**
  OCRFlux-3B and Nanonets-OCR2-3B are both Qwen2.5-VL-3B derivatives with incompatible licence
  claims. This project cannot rely on a downstream card's declaration; it must check the base. The
  practical rule: for any candidate fine-tune, trace to the base model's LICENSE file, and if the
  base is research-only, the derivative is unusable whatever its card says.
- **dots.ocr's licence drift (MIT at 1.0, bespoke supplementary terms at 1.5) plus its disappearance
  from Hugging Face is a stability warning.** Even the MIT 1.0 weights should be mirrored locally if
  used, because the upstream has already demonstrated it will move or re-license.
- The clean set that both fits a T4 and survives the licence filter is small and worth stating
  plainly: **Qwen3-VL-2B/4B, InternVL3.5-2B, SmolVLM2-2.2B, Florence-2, moondream2, PP-OCRv5,
  dots.ocr 1.0.** Everything else in this space is either too big, too restricted, or both.

### Gaps

- The **full text of the Gemma Terms was not read first-hand**; the §3 pass-through quotation comes
  from a licence-list mirror (Wind River) rather than `ai.google.dev/gemma/terms` directly. The
  quotation is specific and consistent across sources, but confirm before citing it in a decision
  record.
- The **Moondream Model License v1.0 full text** (`moondream.ai/licenses/model/1.0`) was not read.
  Whether it contains a unilateral-modification clause of the DINOv3 kind is therefore unknown — but
  since it is bespoke and non-OSI, and since Moondream 3.x needs Ampere anyway, this is moot.
- **Qwen3-VL-2B's licence is unconfirmed from the primary source** (see KQ1 gaps).
- The authoritative licence for **Nanonets-OCR2-3B** could not be established; Hugging Face itself
  calls it unclear.
- I found **no reliable source** on whether the Qwen Research License has a 2026 revision; one
  aggregator (mungomash.com) refers to one but it could not be confirmed against an official source.

---

## Key Question 3: Does specialising a small VLM close the gap to a larger general model?

### Takeaway

**The evidence found does not support this, and the strongest systematic evidence points the
opposite way.** The one large controlled study (LoRA Land, 310 fine-tuned models) found fine-tuned
7B models beat fine-tuned 2B models on 29 of 31 tasks; the closest OCR-specific LoRA comparison
(Manchu script) found the fine-tuned 7B beat the fine-tuned 3B. What *is* well-evidenced is a
different and weaker claim: specialised ~3B models beat *untuned general* models of similar or
somewhat larger size, and the single supporting "small beats huge" datapoint is a blog post, not a
paper.

### Cited Findings

**Evidence against — the systematic study**

- **LoRA Land** (Predibase, 310 fine-tuned LLMs): "fine-tuned 7B models are almost always better
  than fine-tuned 2B models (29/31 tasks)". The notable exception was Phi-2 (2B), which after
  fine-tuning outperformed all the 2B and 7B Gemma models on overall average. This is general
  tasks, not document extraction — [LoRA Land technical report](https://arxiv.org/pdf/2405.00732)

**Evidence against — the closest OCR-specific LoRA comparison**

- Manchu-script OCR study: **LoRA-tuned Qwen2.5-VL-7B reached 87.5% accuracy / 0.978 F1; LoRA-tuned
  Qwen2.5-VL-3B reached 84.4% / 0.973** on word-image OCR. The 3B was trained for *more* epochs and
  still lost. This is word-image OCR for a low-resource script, not document OCR —
  [Finetuning VLMs as OCR Systems for Low-Resource Languages: Manchu](https://arxiv.org/html/2507.06761v1)

**Evidence that specialisation beats bigger — but with caveats**

- A write-up reports fine-tuning IBM **Granite-Vision 2B** for table-to-HTML extraction and
  surpassing both reference models including a 90B, with LoRA giving "+21 percentage point" gain to
  0.77. This is a **blog post**, the comparison is against a 90B general model rather than a 7B, and
  the 90B was presumably not fine-tuned — [Towards Data Science](https://towardsdatascience.com/how-i-fine-tuned-granite-vision-2b-to-beat-a-90b-model-insights-and-lessons-learned/)
- A 2026 arXiv paper reports a **fine-tuned 7B outperforming both the untuned 7B and a larger 72B**
  on general document information extraction. No 2B involved —
  [Visual Information Extraction from Documents via Classification-Guided LVLMs](https://arxiv.org/pdf/2607.22723)
- A fine-tuned Qwen2.5-VL-7B on W2 forms reached **97.23% overall accuracy versus LlamaExtract's
  70.75%** — a fine-tuned 7B against a cloud service, not against a 2B —
  [chrisalehman/ai-document-extraction](https://github.com/chrisalehman/ai-document-extraction)
- **The existence proof for 3B OCR specialists**: Nanonets-OCR2-3B was built by fine-tuning
  Qwen2.5-VL-3B-Instruct on a corpus of >3M pages. No head-to-head against a 7B is published —
  [Nanonets research](https://nanonets.com/research/nanonets-ocr-2/index.html)
- **A 3B specialist does beat the 7B general baseline on a shared benchmark**: dots.mocr (3B) scores
  **43.3 EN** on OCRBench v2 versus Qwen2.5-VL-7B's **41.8 EN** — though the two rows are from
  different leaderboard snapshots (2026.03 vs 2025.09) — [OCRBench v2](https://99franklin.github.io/ocrbench_v2/)

**Evidence on fine-tuning method**

- **olmOCR's authors tried LoRA on a Qwen2-VL-7B base and abandoned it**, choosing full fine-tuning
  for the final model, because "LoRA resulted in higher loss values compared to full fine-tuning" —
  [olmOCR paper](https://arxiv.org/pdf/2502.18443)
- Infinity-Parser tuned a 7B with **reinforcement learning, not LoRA**, and compared against base
  Qwen2.5-VL-7B on OmniDocBench — [Infinity Parser](https://arxiv.org/pdf/2506.03197)
- NVIDIA's Megatron Bridge documents **LoRA and DoRA finetuning for the 3B, 7B, 32B and 72B
  Qwen2.5-VL variants**, so the tooling path is supported and documented —
  [NVIDIA Megatron Bridge: Qwen2.5-VL](https://docs.nvidia.com/nemo/megatron-bridge/0.2.0/models/vlm/qwen2.5-vl.html)

### Inferences

- **The honest framing of the available evidence is: specialisation reliably beats *not*
  specialising, at every size — it does not reliably substitute for parameters.** LoRA Land's 29/31
  is the only large-N controlled comparison found, and it says a fine-tuned 7B usually beats a
  fine-tuned 2B. The Manchu study says the same thing for an OCR task specifically. Any plan that
  budgets on "specialised 3B ≈ general 7B" is betting against the two best-controlled datapoints
  available.
- **However, the comparison the project actually faces is different and more favourable.** The
  baseline is an *untuned, general* Qwen2.5-VL-7B at 91%. The question is not "tuned 3B vs tuned 7B"
  but "tuned small vs untuned 7B". Every datapoint that addresses *that* comparison — Granite-Vision
  2B vs 90B, the 7B-tuned vs 72B-untuned paper, dots.mocr 3B vs Qwen2.5-VL-7B on OCRBench v2 —
  points the right way. The literature gap is exactly at the question that matters, and the most
  relevant datapoints are the weakest sources.
- **The ceiling matters more than the gap here.** 91% on clear covers leaves 9 points of headroom,
  and a narrow-task fine-tune's realistic gain over an untuned general model on *its own* task is
  often large (the Granite blog's +21pp; the W2 fine-tune's 97%). A specialised small model plausibly
  *exceeds* 91% while also being cheaper — but nothing found proves it, and the project should treat
  this as a hypothesis to measure on its own corpus, not a conclusion to plan around.
- **olmOCR abandoning LoRA for full fine-tuning is the most important methodological warning.** If
  the task shifts the output distribution substantially (strict JSON, title/author fields only,
  ignore-the-blurb behaviour), a low-rank adapter may not have the capacity. The project should plan
  for the possibility that full fine-tuning of a 2B is needed rather than LoRA on a 3B — which is
  still cheap at that size, but changes the GPU memory maths (see KQ4).
- **The project's "read the title not the author" failure mode is a *selection* problem, not a
  *recognition* problem**, and that is precisely the kind of behaviour a fine-tune installs cheaply:
  it needs no new visual capability, only a learned output convention. This is the strongest
  theoretical argument for specialisation here, and it is an argument from task structure rather
  than from a cited result.

### Gaps

- **No same-recipe 3B-vs-7B comparison on a document/OCR task was found.** To make the claim
  properly you would need matched training data, epochs, and LoRA rank across both sizes, evaluated
  on a shared benchmark such as OmniDocBench. I found no such study and would treat the "specialised
  3B matches general 7B on document OCR" claim as **unproven**.
- **No published before/after numbers for fine-tuning a small VLM on a book-cover task.** The
  quantified gaps requested ("before and after") exist only for adjacent tasks: table-to-HTML
  (+21pp, blog), W2 extraction (97.23% tuned vs 70.75% service), Manchu OCR (87.5%/84.4% both tuned,
  no untuned baseline cited in the snippet).
- Nanonets-OCR2-3B is the closest precedent for a 3B document-OCR specialist but publishes no
  head-to-head against a 7B.
- The Granite-Vision 2B result is a blog post, and the 90B comparator's tuning status is unclear —
  it is almost certainly an untuned-general vs tuned-specialist comparison, which is a much weaker
  claim than the headline implies.

---

## Key Question 4: What fine-tuning approach fits, and can training be done cheaply?

### Takeaway

Training cost is not the obstacle. Published rules of thumb put a QLoRA run on a **7B** model at
**2–4 hours on a single A100** at roughly **$1.19–$1.48/hr**, i.e. single-digit to low-tens of
dollars; a 2–4B VLM should be cheaper. But every cost figure I could find is for **text LLMs**, from
vendor and blog sources, and none accounts for the VLM-specific overhead of image tokens and the
vision encoder — which for a cover-photo task is the dominant cost.

### Cited Findings

- A QLoRA run on a 7B model over a small dataset "typically finishes in **2 to 4 hours**" —
  [Spheron: How to Fine-Tune LLMs in 2026](https://www.spheron.network/blog/how-to-fine-tune-llm-2026/)
- A 7–8B model on **5,000 instruction samples for 3 epochs** takes roughly **45 minutes to 1.5 hours
  on a single A100 40GB** — [tech-insider](https://tech-insider.org/how-to-fine-tune-an-llm-2026/)
- At **50,000 samples**, expect **4 to 6 hours** —
  [DEV: Fine-Tune LLMs with LoRA and QLoRA, 2026 Guide](https://dev.to/jangwook_kim_e31e7291ad98/fine-tune-llms-with-lora-and-qlora-2026-guide-33lf)
- Dataset-size guidance: **100–10,000 examples, with 500+ recommended for production** —
  [DEV guide](https://dev.to/jangwook_kim_e31e7291ad98/fine-tune-llms-with-lora-and-qlora-2026-guide-33lf)
- GPU rates cited: **A100 at $1.48/hr**; **A100 80GB at $1.19/hr on RunPod** —
  [Spheron](https://www.spheron.network/blog/how-to-fine-tune-llm-2026/); [techsy](https://techsy.io/en/blog/how-to-fine-tune-llm)
- One guide estimates a **5K-sample 7B run at ~$15–50**, higher than the hourly arithmetic implies —
  [techsy](https://techsy.io/en/blog/how-to-fine-tune-llm)
- Memory for **3B models under QLoRA 4-bit: ~4–6 GB** —
  [tensoria LoRA/QLoRA guide](https://tensoria.fr/en/blog/lora-qlora-fine-tuning-guide)
- **Tooling exists and is first-party-documented**: NVIDIA Megatron Bridge supports LoRA and DoRA for
  Qwen2.5-VL at 3B/7B/32B/72B — [NVIDIA docs](https://docs.nvidia.com/nemo/megatron-bridge/0.2.0/models/vlm/qwen2.5-vl.html)
- Practical VLM fine-tuning walkthroughs for this exact model family exist —
  [Roboflow: fine-tune Qwen2.5-VL on a custom dataset](https://blog.roboflow.com/fine-tune-qwen-2-5/); [UbiAI: Qwen2.5-VL for document information extraction](https://ubiai.tools/how-to-fine-tune-qwen2-5-vl-for-document-information-extraction/)
- **Counter-evidence on method**: olmOCR abandoned LoRA for full fine-tuning because "LoRA resulted
  in higher loss values compared to full fine-tuning" — [olmOCR paper](https://arxiv.org/pdf/2502.18443)

### Inferences

- **The "rented A100 for hours, not days" premise is sound** on the published numbers: a 2–4B VLM
  with a few thousand cover images at 3 epochs should land inside a single-digit number of A100
  hours, i.e. **under $20**. Even a 10x miss on the VLM overhead keeps it inside one month's
  inference budget as a one-off.
- **The economics strongly favour trying this**: the training cost is roughly one month of the
  inference budget, paid once, against a permanent per-inference saving from T4 ($0.59/hr) versus
  A10G. The decision should not hinge on training cost at all — it should hinge on whether the
  accuracy lands, which is a measurement question.
- **Dataset size is the real unknown and the real work.** The 500+-examples floor is for text
  instruction tuning. For a narrow visual extraction task with a fixed output schema, a few hundred
  to a few thousand labelled covers is the plausible range — and the project already has a corpus
  intake pipeline and a shot list in flight (`images/CORPUS-INTAKE.md`, `images/SHOT-LIST.md` in the
  working tree), so labelled photographs with known ISBNs are obtainable. Ground truth is free: the
  ISBN resolves to canonical title/author.
- **Budget for full fine-tuning, not just LoRA.** At 2–4B, full fine-tuning fits comfortably on a
  single A100 80GB, and olmOCR's experience says it may be necessary. The cost difference at this
  scale is hours, not an order of magnitude.
- A hidden cost not in any source: **the fine-tuned model must be served in fp16 on a T4 without
  FlashAttention-2**. Training on an A100 in bf16 and serving in fp16 on Turing is a precision
  mismatch that should be validated as part of the eval, not discovered in production.

### Gaps

- **No source found measures fine-tuning cost for a 3B *vision*-language model specifically.** All
  hours/cost figures above are text-LLM analogues from vendor and blog sources, not benchmarks. VLM
  training cost is dominated by image-token count per sample, which none of them models. A short
  measured run on the project's own data, extrapolated by throughput, is the only reliable estimate.
- No source gives the optimal LoRA rank, learning rate, or epoch count for a narrow VLM extraction
  task.
- No evidence found on whether freezing the vision encoder (common practice, much cheaper) is
  sufficient for cover photographs, where the visual domain shift from document scans is large
  (glare, skew, depth of field, stylised type).

---

## Key Question 5: Is a generative VLM even the right shape?

### Takeaway

**The evidence favours a hybrid, and specifically argues against treating this as a single
model-shape choice.** The project's rejected 23% Tesseract result was mostly a *selection* failure
(author instead of title, blurb text), not a recognition failure — and the two non-VLM shapes attack
different halves of the problem: a modern OCR pipeline (PP-OCRv5, ~5M params, Apache-2.0) fixes
recognition far better than Tesseract and leaves selection unsolved, while embedding/retrieval
against a cover index skips text entirely and is the strongest shape for the *in-print, catalogued*
majority of covers. A small generative VLM is the only shape that solves selection and recognition
in one model, which is why it remains the primary candidate — but it should be the fallback tier,
not the only tier.

### Cited Findings

**(a) Specialised OCR / text-detection pipeline**

- **PP-OCRv5 mobile is a ~5 million parameter model** described as "a meticulously optimized,
  lightweight OCR system with merely 5 million parameters" that "achieves accuracy comparable to
  state-of-the-art billion-parameter VLMs on standard OCR benchmarks" —
  [PP-OCRv5 arXiv paper](https://arxiv.org/abs/2507.05595)
- PP-OCRv5 claims a **13-point gain over PP-OCRv4**, but from Baidu's internal multi-scenario
  evaluation sets, **not a public benchmark**. An English-specific model reportedly gains a further
  11% in English scenarios — [arXiv 2507.05595](https://arxiv.org/abs/2507.05595); [PaddleOCR docs](https://www.paddleocr.ai/v3.1.1/en/index.html)
- **Licence: Apache 2.0** per the Baidu AI Studio model page — [AI Studio](https://aistudio.baidu.com/modelsdetail/28601)
- A successor, **PP-OCRv6**, reports +4.6% detection and +5.1% recognition over v5 (project's own
  wiki; licence unverified) — [PaddleOCR wiki](https://github.com/PaddlePaddle/PaddleOCR/wiki)
- Hugging Face's OCR round-up calls older pipelines that detect words then handle layout in
  post-processing **"brittle"**, and says modern models incorporating layout metadata do better at
  reading order. It concludes there is **"no single best model"** and that the choice depends on use
  case, output format, and your own domain data. It also notes **many current OCR models are
  themselves fine-tuned VLMs** — [HF blog: OCR open models](https://huggingface.co/blog/ocr-open-models)
- **Florence-2's `<OCR_WITH_REGION>` returns text *with* quad-box coordinates** — i.e. a 0.77B
  MIT-licensed model that gives text plus geometry, at ~1s/image on a T4 —
  [Roboflow inference docs](https://inference-models.roboflow.com/models/florence2/); [Roboflow blog](https://blog.roboflow.com/florence-2/)

**(b) Embedding / retrieval against a cover index**

- **A large-scale book cover retrieval dataset exists with exactly the right annotations**: built
  from the Stanford Mobile Visual Search book-cover set plus additional covers and metadata from
  **openlibrary.org**, with **100K distractor covers** and title and author strings for every image.
  The authors claim it is "the first large-scale book cover retrieval dataset to contain author and
  title text annotation for every single image" —
  [Efficient Media Retrieval from Non-Cooperative Queries](https://arxiv.org/html/1411.5307)
- The query model is explicitly **"non-cooperative queries"** — i.e. real photographs taken in the
  wild, which is this project's exact input condition — [arXiv 1411.5307](https://arxiv.org/pdf/1411.5307)
- Classical local-feature matching for book cover identification (SIFT, SURF, ORB, A-KAZE) has been
  evaluated head-to-head — [Evaluating image matching methods for book cover identification](https://arxiv.org/pdf/2001.05200)
- A Siamese network with triplet loss matching cover images against a database of embeddings is a
  documented approach, though that paper's dataset is small (762 images) —
  [Library Automation System: Book cover recognition using deep learning](https://www.researchgate.net/publication/339907127_Library_Automation_System_Book_cover_recognition_using_deep_learning)
- Large cover corpora for pretraining exist: **"Judging a Book by its Cover" provides 137,788 books
  in 32 classes with cover image, title text, author text and category** —
  [arXiv 1610.09204](https://arxiv.org/pdf/1610.09204)
- A prior art survey of the exact use case: [Visual Companion for Booklovers](https://arxiv.org/pdf/2011.00329)

**(c) Generative VLM**

- See KQ1/KQ3. Relevant shape-specific finding: Hugging Face's round-up notes Qwen3-VL "isn't
  optimized for a single, universal OCR prompt" (unlike the OCR specialists, which were fine-tuned
  on fixed prompts), and recommends prompt experimentation — i.e. a general VLM's OCR behaviour is
  prompt-sensitive in a way a specialist's is not —
  [HF blog: OCR open models](https://huggingface.co/blog/ocr-open-models)

### Inferences

- **The 23% Tesseract result should not be read as "OCR is ruled out".** The three named failure
  modes — reading the author instead of the title, reading blurb text, reading nothing on stylised
  covers — are two selection failures and one recognition failure. PP-OCRv5 attacks only the third,
  but attacks it hard: a 5M-parameter Apache-2.0 model claiming parity with billion-parameter VLMs on
  standard OCR is a very different proposition from Tesseract, and it costs almost nothing to run.
  The project rejected a 2006-era engine, not the OCR *shape*.
- **The selection problem has a cheap non-VLM solution that was apparently not tried**: OCR that
  returns text *with bounding boxes and confidences* (PP-OCRv5, or Florence-2's `<OCR_WITH_REGION>`)
  turns "which string is the title?" into a small structured-prediction problem over (text, box,
  size, position) tuples — solvable by a tiny classifier trained on a few hundred labelled covers, or
  even by handing the box list to a text-only LLM. The measured 23% used a "largest-text heuristic",
  which is the weakest possible selector. This is a materially cheaper experiment than fine-tuning a
  VLM and should be run first, because it also establishes the recognition ceiling.
- **Embedding/retrieval is the strongest shape for the common case and the weakest for the tail.**
  Where the cover is in Open Library's image corpus, retrieval returns the ISBN *directly* — skipping
  the title-search resolution step entirely, with no text reading, no hallucination risk, and
  inference cost that is a single image embedding (CPU-feasible, let alone T4). The 1411.5307 dataset
  proves this is a solved research problem with 100K distractors. It fails on covers not in the index:
  new editions, obscure imprints, foreign-language printings, damaged or heavily cropped photographs.
- **The architecture the evidence actually favours is a cascade, which is the shape this project
  already uses for vision** (per the project's own barcode → cover-embedding → OCR → VLM fallback
  model). The research here *validates* that ordering rather than overturning it: retrieval first
  (cheapest, highest precision where it hits), OCR+selector second, specialised small VLM last. The
  question "which shape" is the wrong question; the live question is **what fraction each tier
  absorbs**, because that determines whether the VLM tier is hit often enough to justify a T4 at all.
- **If retrieval absorbs most of the volume, the VLM tier's accuracy requirement drops and the
  budget maths changes completely.** A tier that handles 15% of uploads can afford to be slower, or
  can even stay on a bigger model, within $50/month. Measuring the tier split on the project's own
  corpus is higher-value than any further model comparison.
- **One risk specific to the generative shape, underweighted in the sources**: a generative VLM can
  return a fluent, plausible, *wrong* title — which then resolves cleanly against the cached title
  search to the wrong ISBN. OCR and retrieval both fail noisily (garbage string, low similarity
  score); a VLM fails quietly. Given the project's ISBN hard gate, a confidence signal on the VLM
  tier matters more than a few points of top-1 accuracy.

### Gaps

- **No source directly compares the three shapes on book covers.** The comparison above is assembled
  from a document-OCR round-up, a 2014 retrieval paper, and a scene-text OCR paper. No 2026 study
  evaluates VLM vs OCR-pipeline vs retrieval on photographs of book covers.
- **PP-OCRv5's headline claims rest on Baidu's internal evaluation sets**, not a public benchmark.
  The "comparable to billion-parameter VLMs" claim is from the authors about their own model and
  should be verified on the project's corpus before being relied on.
- The retrieval dataset (arXiv 1411.5307) is from **2014**. Its reported accuracies would be
  superseded by modern embedding models, but I found no 2020s successor benchmark, so there is no
  current number for "what fraction of in-the-wild cover photos does retrieval resolve correctly".
- **No current, maintained book-cover embedding benchmark was found**, and the Kaggle "Book covers
  dataset" is URL-based and organised by 33 genre classes rather than for identity retrieval.
- Open Library's cover-image coverage (what fraction of ISBNs have a usable cover image) was not
  established — this is the single number that determines the retrieval tier's hit rate, and the
  project can measure it directly from its own Open Library integration rather than from literature.
