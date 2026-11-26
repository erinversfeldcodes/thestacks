# T4 Hardware Bounds for VLM Inference (book-cover identification), as of 2026-11-13

Scope note for the report writer: every number below is either (a) quoted from a cited
source, or (b) arithmetic I did myself from cited config values — those are always in the
**Inferences** blocks and labelled as derived. Nothing is from memory. Where sources
conflict I say so rather than picking one.

Freshness: the hard architectural facts (SM75 capability set, no bf16) are permanent. The
*software* facts (vLLM backends, PyTorch wheels, TensorRT-LLM support matrix) are the ones
that move; I have flagged ages inline. Two load-bearing sources are from Nov 2025 –
Mar 2026 and are explicitly flagged as approaching/past the 12-month staleness line.

---

## Q1. T4 exact specs, SM75 capability set, and what Turing lacks

### Takeaway
A T4 is 16 GB GDDR6 at 320 GB/s, 65 FP16 TFLOPS / 130 INT8 TOPS / 260 INT4 TOPS, 70 W,
PCIe Gen3 x16, compute capability 7.5. The decisive gaps versus Ampere+ are: no bfloat16,
no FP8, no async copy / `cp.async`, and therefore no FlashAttention-2 and no Marlin.
Memory bandwidth — 320 GB/s against the A10G's 600 GB/s — is the single number that caps
decode speed, and it is roughly half.

### Cited Findings
- T4 official specs: **8.1 TFLOPS FP32; 65 TFLOPS mixed-precision FP16/FP32; 130 INT8 TOPS;
  260 INT4 TOPS; 16 GB GDDR6; 320+ GB/s; 70 W; 2,560 CUDA cores; 320 Turing Tensor Cores;
  Gen3 x16 PCIe** — [NVIDIA T4 product page](https://www.nvidia.com/en-us/data-center/tesla-t4/)
- The 320 GB/s figure is NVIDIA's; third-party listings (PNY, Afox) say 300 GB/s. NVIDIA's
  own number is the one to cite — [PNY T4 listing](https://www.pny.com/en-tw/nvidia-tesla-t4)
- Memory bus is 256-bit; launch-era coverage cited 75 W where the datasheet says 70 W —
  [WCCFTech T4 announcement](https://wccftech.com/nvidia-tesla-t4-turing-75w-gpu-announced/)
- T4 is compute capability **7.5** — [Wikipedia: Turing microarchitecture](https://en.wikipedia.org/wiki/Turing_(microarchitecture))
- **Turing tensor cores do fp16, int8 and int4, but not bf16** —
  [tech-cosmos/turing-bf16 README](https://github.com/tech-cosmos/turing-bf16)
- vLLM's own logs on a T4 emit: *"FA2 is only supported on devices with compute capability
  >= 8"* — [vLLM issue #29743, Isotr0py comment, 2025-11-30](https://github.com/vllm-project/vllm/issues/29743)
- FP8 (W8A8) is unsupported on **both** Turing *and* Ampere; it first appears on Ada (8.9) —
  [vLLM supported hardware for quantization kernels](https://docs.vllm.ai/en/v0.9.0/features/quantization/supported_hardware.html)
- A10G (the measured baseline's GPU) is 24 GB GDDR6 at **600 GB/s**, **70 dense FP16 tensor
  TFLOPS** (140 with sparsity), 300 W TDP —
  [Flopper A10G spec sheet](https://flopper.io/gpu/nvidia-a10g-24gb); [getdeploying A10G](https://getdeploying.com/reference/cloud-gpu/nvidia-a10g)
- ⚠️ **Conflict on A10G compute**: Flopper/getdeploying say 70 dense FP16 TFLOPS for the
  A10G; other listings give 125 dense (A10) and PNY gives 165 TFLOPS / 330 with sparsity
  for the A10 — [morphllm A10 page](https://www.morphllm.com/nvidia-a10);
  [PNY A10](https://www.pny.com/en-eu/nvidia-a10). The A10G is the cut-down AWS SKU and is
  not the same part as the A10, so the 70 figure is the one that applies to the measured
  baseline. I could not find an NVIDIA-published A10G datasheet to settle this.
- Compute capability 8.6 for the A10/A10G is asserted by only one source and I could not
  corroborate it from NVIDIA — [gpupoet A10](https://gpupoet.com/gpu/learn/card/nvidia-a10)

### Inferences
- **Derived bandwidth ratio T4:A10G = 320/600 = 0.53×.** Autoregressive decode is
  memory-bandwidth bound (every token re-reads the whole weight set), so a T4 should decode
  at roughly **half** the A10G's tokens/sec for the same weights in the same precision.
  This is the floor, before any kernel-quality penalty.
- **Derived compute ratio T4:A10G = 65/70 = 0.93×** (using the 70 TFLOPS A10G figure). The
  vision-tower forward pass and prefill are compute-bound, so on *paper* the T4 is near
  parity there. In practice it will be worse because Turing cannot use FlashAttention-2
  (see Q5) and must fall back to slower attention kernels.
- **The T4's fp16 and INT8 rates sit in a 2:1 ratio (65 TFLOPS → 130 TOPS), and INT4 is
  4:1 (260 TOPS).** Turing is one of the few architectures with *native INT4 tensor core
  throughput*, which is the one genuinely favourable fact for a 4-bit deployment — but
  realising it requires a kernel that actually targets `mma.m8n8k32` INT4, and the mainstream
  4-bit serving kernels (Marlin) do not (Q4).
- PCIe **Gen3** x16 ≈ 16 GB/s theoretical / ~12 GB/s practical host→device, versus Gen4
  x16 ≈ 32 GB/s on A10G. This halves the H2D leg of cold start, though H2D is not the
  dominant term (Q6).

### Gaps
- NVIDIA does not publish an "A10G" datasheet distinct from the A10, so the 70-vs-125
  TFLOPS conflict is unresolved from primary sources. The report should carry the range.
- I could not find a published NVIDIA statement of Turing's lack of `cp.async`; the claim
  is inferred from the FA2 requirement (`compute capability >= 8`) rather than cited.

---

## Q2. ⛔ bf16-trained models run in fp16 on Turing: what actually breaks

### Takeaway
This is a real, documented, model-specific failure mode — not a theoretical concern.
fp16's max representable value is 65,504; bf16-trained activations routinely exceed it.
Qwen2.5-VL specifically has a **reproduced, maintainer-acknowledged** fp16-only failure
(garbage `!!!` output on certain images at default resolution), and a separate documented
fp16 overflow in the Qwen2-VL naive-attention path that was closed *without a merged fix*.
Mitigations exist (power-of-two row scaling with fp32 accumulation) but ship as unmaintained
research code.

### Cited Findings
- **The mechanism:** fp16 tops out at **65,504**. "Many bf16 models (Gemma 2/3, T5, video
  DiTs) overflow and produce NaN or black frames." Casting with `.half()` is the fast path
  and the one that breaks — [turing-bf16 README](https://github.com/tech-cosmos/turing-bf16)
- Gemma 3 at **4B produces NaN with `.half()`**; Unsloth reported Gemma 3 activations from
  1B to 27B exceeding fp16's 65,504 maximum — [turing-bf16 README](https://github.com/tech-cosmos/turing-bf16);
  [technolynx BF16 vs FP16](https://www.technolynx.com/post/bf16-vs-fp16-dynamic-range-precision)
- **Qwen2.5-VL-3B, fp16-only garbage output** (vLLM #13817, opened Feb 2025, **closed
  completed 2025-02-27 via PR #13968**): the model returned *a series of "!!!"* for a
  specific image. Reporter: *"I tested and confirmed this would only happen if I set
  `--dtype half/float16`."* Reproduced on an **RTX 2080 Ti (Turing, XFormers backend)** and
  on an L40S (FlashAttention backend), vLLM 0.7.2/0.7.3. Affected the 3B only — *"72b & 7b
  were okay."* Maintainer Isotr0py: *"Seems that it's caused by the default
  `max_pixel_values`"*, workaround `max_pixels=1003520` via `--mm-processor-kwargs` —
  [vLLM issue #13817](https://github.com/vllm-project/vllm/issues/13817)
- **The AWQ corollary, from that same thread:** *"The same problem is worse for the case of
  the AWQ checkpoint, since it only supports half (float16) dtype!"* —
  [vLLM issue #13817](https://github.com/vllm-project/vllm/issues/13817)
- **Qwen2-VL naive attention fp16 overflow** (transformers #35151, Dec 2024, **closed
  2025-01-16 with no merged fix, no maintainer reply**): overflow originates in
  `torch.matmul(query_states, key_states.transpose(2, 3))` producing ±inf in fp16; the
  causal mask uses −65504, so mask+score yields −inf. The in-tree fix ("Replace inf values
  with zeros in attention weights to prevent NaN propagation") applies the mask *then* zeros
  infs, which **turns masked positions back into 0 and so breaks causality** — the reporter
  shows the last position receiving attention weight 0.7310/0.5762 where it should be zero —
  [transformers issue #35151](https://github.com/huggingface/transformers/issues/35151)
- **Qwen2.5-VL 7B goes NaN in fp16 training on T4s specifically:** on Kaggle T4×2 with
  FSDP2 the run went NaN from step 4 while DDP stayed finite —
  [unsloth PR #14996](https://github.com/unslothai/unsloth/pull/14996)
- **Mixed-dtype crash on T4 with the Qwen2.5-VL vision tower:** on a Tesla T4 (sm75),
  generation crashes at the first qkv linear in `text_encoder.visual` with
  `RuntimeError: self and mat2 must have the same dtype, but got BFloat16 and Half` —
  the pipeline is forced to fp16 because Turing lacks native bf16, but the visual encoder's
  activations stay BFloat16. Opened 2026-06-26, **closed "not planned" 2026-10-31**, repo
  archived, no fix — [comfyui-sdnq issue #63](https://github.com/EnragedAntelope/comfyui-sdnq/issues/63)
- vLLM itself warns on T4: *"Tesla T4 doesn't support torch.bfloat16"*, forcing float16 —
  [vLLM issue #29743](https://github.com/vllm-project/vllm/issues/29743)
- Qwen2.5-VL is **bf16 by design**: `config.json` has `"torch_dtype": "bfloat16"`; the HF
  card's tensor type is BF16; the official vLLM recipe says *"Since BF16 is the commonly
  used precision type for Qwen2.5-VL training, using BF16 in inference ensures the best
  accuracy"* and contains **no fp16 guidance at all** —
  [Qwen2.5-VL-7B config.json](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct/raw/main/config.json);
  [vLLM Qwen2.5-VL recipe](https://docs.vllm.ai/projects/recipes/en/stable/Qwen/Qwen2.5-VL.html)

### Mitigations, with numbers
- **turing-bf16 (`tbf16`)**: keeps weights bf16, runs the math on fp16 tensor cores. Exploits
  the fact that every in-range bf16 value converts *exactly* to fp16 (bf16 has fewer
  significand bits). Scales each activation row and weight row **by a power of two** (exponent-
  only, therefore exact), runs fp16 GEMMs with **fp32 accumulation**, undoes the scale on
  output. For attention it multiplies Q by 2^a and K by 2^−a (logits unchanged) and applies
  one scale per head to V. Reported error **~1.7e-3 relative to an fp64 reference**, which
  the author says matches torch's own bf16 rounding; greedy tokens expected to match.
  Caveats stated by the author: precision loss on very small elements, and double rounding
  for batches under 256 rows — [turing-bf16 README](https://github.com/tech-cosmos/turing-bf16)
- **tbf16 measured speedups, T4 rows:** large matmuls **2.9 → 24–30 TFLOPS**; attention
  4–16k tokens **12.6–14.5 TFLOPS** ("fp16 speed"). On a 2080 Ti: 4096³ GEMM **torch bf16
  6.6 TFLOPS vs tbf16 41.9 TFLOPS (6.4×)**; Gemma 3 4B at 2048 tokens **2084 → 484 ms
  (4.3×)**; Qwen3-1.7B at 4096 tokens **2455 → 423 ms (5.8×)**. The fp32 fallback runs at
  **~13 TFLOPS** on these cards and doubles memory —
  [turing-bf16 README](https://github.com/tech-cosmos/turing-bf16)
- ⚠️ **Source quality caveat**: turing-bf16 is third-party, self-reported, Linux-only, and
  the author describes it as *"research code"* that is *"not actively maintained."* Its
  benchmarks are on 2080 Ti and T4 only. This is the best-documented mitigation I found and
  it is not something to build a production path on without independent measurement.
- Reported simpler mitigation pattern: fp16 matmuls with **fp32 norms** plus overflow checks
  when serving a bf16-pretrained model on a T4 —
  [technolynx](https://www.technolynx.com/post/bf16-vs-fp16-dynamic-range-precision)

### Inferences
- **The failure mode is silent, not loud.** In vLLM #13817 the model did not crash — it
  emitted `!!!`. In the ComfyUI case it crashed. In the transformers case the in-tree
  "fix" silently broke causality. For a book-cover identifier, the dangerous shape is the
  first: a confident wrong ISBN rather than an error. Any T4 path needs output validation
  that can detect degenerate generations, and the project's existing ISBN hard gate against
  Open Library/Google Books happens to be exactly that backstop.
- **The 3B is the model that broke, not the 7B.** vLLM #13817 explicitly reports "72b & 7b
  were okay" while 3B failed. That is the opposite of convenient: the 3B is the size that
  actually fits a T4 (Q3), and it is the size with a documented fp16 defect.
- **The documented trigger was image resolution**, not the text side: the maintainer's
  workaround was to cap `max_pixels` at 1,003,520. That ties the numerical risk directly to
  the vision-token budget, which is the same lever as the memory budget (Q3) — so capping
  resolution buys both. A book cover is a low-information-density image, so a cap is cheap.
- **Interaction with quantisation:** AWQ checkpoints are fp16-only, so an AWQ deployment on
  a T4 cannot sidestep the fp16 problem by switching dtype. The thread says the problem is
  *worse* there. An AWQ-on-T4 plan inherits this risk by construction.

### Gaps
- Neither the vLLM nor the transformers thread contains a numerical root-cause analysis
  (no measured activation magnitude, no identified layer index). The maintainers pointed at
  the pixel limit as a *trigger*, not a mechanism. I found no source that measures where
  Qwen2.5-VL's activations exceed 65,504.
- PR #13968 fixed vLLM #13817, but the thread does not describe the code change, so I
  cannot say whether it fixed the overflow or merely changed the default pixel budget.
- I found no fp16-vs-bf16 *accuracy* comparison for Qwen2.5-VL on any OCR or
  identification benchmark. The question "does fp16 cost accuracy points even when it does
  not NaN" is unanswered by any source I found.

---

## Q3. What actually fits in 16 GB — weights, KV cache, and vision tokens

### Takeaway
A 7B-class VLM in fp16 does **not** fit a T4: Qwen2.5-VL-7B-Instruct is ~8B parameters,
i.e. **~16 GB of weights alone** against 16 GB of VRAM, before any KV cache, activations or
CUDA context. The realistic T4 configurations are a 3B in fp16 or a 7B-class at 4-bit. The
underestimated term is not KV cache (which is small, 56 KiB/token for the 7B) — it is the
**vision token count**: an unresized 12 MP phone photo produces ~15.5k visual tokens at
Qwen2.5-VL's default limits, and 4× that many patches inside the ViT.

### Cited Findings
- Qwen2.5-VL-7B-Instruct HF metadata lists **"8B params"**; the family is described as
  "three models with 3, 7 and 72 billion parameters" — the card gives **no VRAM table** —
  [Qwen2.5-VL-7B-Instruct model card](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct)
- Qwen2.5-VL-7B `config.json`: **num_hidden_layers 28, num_attention_heads 28,
  num_key_value_heads 4, hidden_size 3584, max_position_embeddings 128000,
  torch_dtype bfloat16**; vision_config **depth 32, hidden_size 1280, out_hidden_size 3584,
  spatial_merge_size 2, patch_size 14** —
  [config.json](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct/raw/main/config.json)
- Qwen2.5-VL-3B `config.json`: **num_hidden_layers 36, num_attention_heads 16,
  num_key_value_heads 2, hidden_size 2048, tie_word_embeddings true, torch_dtype bfloat16**;
  vision_config **depth 32, hidden_size 1280, out_hidden_size 2048** —
  [config.json](https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct/raw/main/config.json)
- **Visual token range is 4–16,384 per image by default**; one token covers a **28×28 pixel**
  area; the card recommends narrowing to **256–1280 tokens** via `min_pixels = 256*28*28`
  and `max_pixels = 1280*28*28` to balance performance and cost —
  [Qwen2.5-VL-7B model card](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct)
- A vLLM user computed that 16,384 tokens × 28 × 28 corresponds to a **3584×3584 image**,
  and called it unreasonable; a maintainer replied that those counts come from the dummy
  data used in vLLM's **memory profiling** — i.e. vLLM *sizes its memory reservation* off
  that worst case — [vLLM issue #20123](https://github.com/vllm-project/vllm/issues/20123)
- The Qwen2.5-VL **ViT is 675M parameters** (stated in the official recipe as "ViT 675M vs
  LM 72B" for the 72B model) —
  [vLLM Qwen2.5-VL recipe](https://docs.vllm.ai/projects/recipes/en/stable/Qwen/Qwen2.5-VL.html)
- **Measured VRAM for small VLMs, single-image inference**: SmolVLM 256M **0.8 GB**,
  500M **1.2 GB**, 2.2B **4.9 GB**; by comparison **Qwen2-VL-2B requires 13.7 GB** and
  **InternVL2-2B requires 10.5 GB** —
  [SmolVLM paper, arXiv 2504.05299](https://arxiv.org/pdf/2504.05299)
- SmolVLM2 (2.2B) scores **72.9% on OCRBench**; dedicated OCR models (PaddleOCR-VL, GLM-OCR)
  outperform general VLMs at that size —
  [Roboflow: best open-source OCR models](https://blog.roboflow.com/best-open-source-ocr-models/)
- Practical T4 serving config reported for Qwen2.5-VL-3B on a Colab T4:
  `dtype="float16"`, `gpu_memory_utilization=0.80–0.85`, `max_model_len=4096` (drop to 2048
  if it still OOMs) — [Medium: Qwen2.5-VL with vLLM on Colab T4](https://medium.com/@imabhi1216/run-qwen2-5-vl-with-vllm-on-google-colab-t4-a-step-by-step-guide-7e945e72e348)
  (⚠️ single-author blog, not a tested reference config)
- Default vLLM behaviour is to **pre-allocate 90% of GPU memory** for weights + KV cache;
  OOM during profiling or cudagraph capture is the expected symptom of over-setting
  `max_model_len` — [vLLM Qwen2.5-VL recipe](https://docs.vllm.ai/projects/recipes/en/stable/Qwen/Qwen2.5-VL.html)

### Inferences — the memory arithmetic (all derived from the cited configs)
**KV cache per token** = 2 (K and V) × layers × kv_heads × head_dim × bytes_per_element.
head_dim = hidden_size / num_attention_heads = 3584/28 = **128** (7B) and 2048/16 = **128** (3B).

| Model | per-token KV (fp16) | 4,096 tok | 16,384 tok | 32,768 tok | 128,000 tok (model max) |
|---|---|---|---|---|---|
| Qwen2.5-VL-**7B** (28L, 4 KV heads, d128) | 2·28·4·128·2 = **57,344 B = 56 KiB** | 224 MiB | 896 MiB | 1.75 GiB | **6.83 GiB** |
| Qwen2.5-VL-**3B** (36L, 2 KV heads, d128) | 2·36·2·128·2 = **36,864 B = 36 KiB** | 144 MiB | 576 MiB | 1.13 GiB | **4.39 GiB** |

**Weights** (derived, 2 bytes/param fp16, using the card's own "8B params" / "3B" figures):

| Config | Weight bytes | Fits 16 GB? |
|---|---|---|
| 7B-class fp16 | ~8e9 × 2 = **~16.0 GB** | **No** — equals total VRAM before context/activations |
| 7B-class INT8 W8A8 | ~8e9 × 1 = **~8.0 GB** | Yes, ~8 GB headroom |
| 7B-class 4-bit (g128: 4 bits + fp16 scale/zero per 128 → ~4.5 bits/param) | ~8e9 × 0.5625 = **~4.5 GB** | Yes |
| 7B-class 4-bit **with the 675M ViT left in fp16** (the usual AWQ VLM recipe) | 4.5 + 1.35 = **~5.9 GB** | Yes |
| 3B fp16 | ~3e9–3.8e9 × 2 = **~6–7.6 GB** | Yes |
| 3B 4-bit | **~2 GB** | Yes, comfortably |

A T4's 16 GB is also not 16 GB to the application: CUDA context plus allocator overhead
typically takes several hundred MB, and vLLM's default reserves 90% of the card.

**Vision tokens — the term people underestimate** (derived from patch_size 14 and
spatial_merge_size 2, so one LLM visual token = 28×28 px, and ViT patch count = 4× the LLM
visual token count):

| Image | Pixels | LLM visual tokens | ViT patches (pre-merge) | KV cost at 7B |
|---|---|---|---|---|
| 448×448 thumbnail | 200,704 | 256 | 1,024 | 14 MiB |
| Model card's recommended cap (1280 tok) | 1,003,520 (~1002²) | 1,280 | 5,120 | 70 MiB |
| 1280×960 phone photo | 1,228,800 | **1,567** | 6,268 | 86 MiB |
| 12 MP iPhone shot, **unresized** (3024×4032) | 12,192,768 | **15,552** | 62,208 | **850 MiB** |
| Qwen default ceiling (3584×3584) | 12,845,056 | **16,384** | 65,536 | 896 MiB |

- **The dominant VLM memory risk on a T4 is the ViT forward pass on an unresized photo, not
  the KV cache.** At 62,208 patches × hidden 1280 × 2 bytes, a *single* activation tensor in
  the vision tower is **159 MiB**, and the ViT has depth 32. Any attention implementation
  that materialises an S×S logits matrix over 62k patches is arithmetically impossible
  (62,208² × 2 B × heads is in the terabytes), which is precisely why the resolution cap is
  not optional on this card.
- This connects directly to Q2: the *documented* Qwen2.5-VL fp16 failure was fixed by
  capping `max_pixels` at 1,003,520. **The same cap that makes it numerically safe is the
  cap that makes it fit.** For book covers — a single large title, high-contrast, low
  information density — 1,280 visual tokens is almost certainly sufficient, but that is an
  assumption the project would need to measure against its own corpus.
- vLLM's memory *profiling* uses the 16,384-token dummy worst case, so on a 16 GB card you
  must pass `--limit-mm-per-prompt` and a `max_pixels` in `--mm-processor-kwargs` or the
  engine will reserve for an image you will never send and fail to start.
- **Best-fit configurations for a T4, ranked by headroom:**
  1. 3B at 4-bit, 1280 visual tokens, 4k context: ~2 GB weights + ~0.15 GiB KV ≈ **3 GB**,
     huge headroom — but this is the size with the documented fp16 defect.
  2. 3B fp16, 4k context: ~6–7.6 GB + 0.14 GiB ≈ **8 GB**, workable.
  3. 7B-class 4-bit with fp16 ViT, 8k context: ~5.9 GB + 0.44 GiB ≈ **6.4 GB**, workable on
     paper — gated entirely on whether the 4-bit kernels run well on SM75 (Q4).
  4. 7B-class fp16: **does not fit.**
- SmolVLM's measured 4.9 GB for a 2.2B model versus 13.7 GB for Qwen2-VL-2B at the same
  parameter count is a ~2.8× difference attributable to visual-token policy, not weights.
  That is the strongest single piece of evidence that *the image-token budget, not the
  parameter count, decides whether a VLM fits a 16 GB card.*

### Gaps
- No source gives an exact total parameter count for Qwen2.5-VL-7B-Instruct (HF metadata
  rounds to "8B"). My ~16.0 GB fp16 weight figure carries that rounding; the true figure
  could be 15.5–16.6 GB. Either way it does not fit.
- I found **no measured VRAM figure for Qwen2.5-VL at any size on a T4**. All the fit
  numbers above are arithmetic, not measurement.
- Qwen2.5-VL's ViT attention scheme (whether it uses windowed attention with a few full
  layers) is not established by any source I fetched, so the ViT peak-activation figure is
  a lower bound on the uncertainty, not a measured peak.

---

## Q4. Quantisation on SM75: what works, what silently isn't there

### Takeaway
Per vLLM's own hardware matrix: **AWQ, GPTQ, INT8 W8A8, bitsandbytes, GGUF, AQLM, BitBLAS
and DeepSpeedFP are supported on Turing. Marlin and FP8 are not.** Marlin is the reason
4-bit serving is fast on Ampere+, so a T4 gets 4-bit *compression* without 4-bit *speed* —
it falls back to the older, slower AWQ/GPTQ kernels. SGLang is stricter than vLLM here and
has removed the non-Marlin GPTQ path on NVIDIA entirely.

### Cited Findings
- vLLM quantisation support matrix (Turing = 7.5 column): **AWQ ✅, GPTQ ✅, INT8 W8A8 ✅,
  BitBLAS (GPTQ) ✅, AQLM ✅, bitsandbytes ✅, DeepSpeedFP ✅, GGUF ✅; Marlin (GPTQ/AWQ/FP8)
  ❌, FP8 (W8A8) ❌.** Marlin is supported only from Ampere (8.0/8.6) upward. FP8 needs
  Ada (8.9) or Hopper —
  [vLLM supported hardware for quantization kernels](https://docs.vllm.ai/en/v0.9.0/features/quantization/supported_hardware.html)
- Marlin was written for Ampere: described as "an optimized CUDA kernel for Ampere GPUs for
  int4*fp16 matrix multiplication" — [AutoGPTQ v0.7.0 release notes](https://github.com/AutoGPTQ/AutoGPTQ/releases/tag/v0.7.0);
  tuned for SM80 and working through Blackwell —
  [Blackwell GPU wiki: Marlin and friends](https://0xsero.github.io/blackwell-gpu-wiki/kernels/marlin-and-friends/)
- **SGLang is stricter than vLLM**: `awq_marlin` and `gptq_marlin` are CUDA-only, its plain
  `gptq` method is **"Removed on NVIDIA GPUs — use gptq_marlin instead"**, and auto mode
  selects Marlin on SM80–SM90 —
  [SGLang quantization docs](https://docs.sglang.ai/advanced_features/quantization.html)
- **bitsandbytes official thresholds**: LLM.int8() requires **compute capability 7.5+**,
  example hardware "Turing (RTX 20 series, T4) or newer"; **NF4/FP4 requires only 6.0+**
  (Pascal or newer) — [bitsandbytes installation guide](https://huggingface.co/docs/bitsandbytes/main/en/installation);
  same thresholds in [HF Transformers bitsandbytes docs](https://huggingface.co/docs/transformers/en/quantization/bitsandbytes)
- NF4 *storage* works on T4, but the NF4 **compute dtype** is fp16/bf16 — a request to use
  int8 as the compute dtype errors in matmul —
  [bitsandbytes issue #1321](https://github.com/bitsandbytes-foundation/bitsandbytes/issues/1321)
- ⚠️ **Conflict**: one guide marks Marlin as supported on Turing with an asterisk meaning
  only "Turing does not support Marlin MXFP4", contradicting vLLM's own table —
  [particula.tech AWQ vs GPTQ vs FP8](https://particula.tech/blog/awq-vs-gptq-vs-fp8-quantization-choice).
  vLLM's table is the authoritative source and says Marlin is ❌ on Turing.
- The **AWQ-is-fp16-only** constraint again, from the vLLM Qwen2.5-VL thread: *"the AWQ
  checkpoint... only supports half (float16) dtype"* —
  [vLLM issue #13817](https://github.com/vllm-project/vllm/issues/13817)

### Inferences
- **The practical 4-bit story on a T4 is "it loads, it saves memory, it is not fast."**
  Marlin exists because the naive AWQ/GPTQ dequant-then-fp16-GEMM kernels leave most of the
  card's throughput on the table; a T4 is stuck with those older kernels. Combined with the
  T4's 320 GB/s, a 4-bit model on T4 will not reach anything like the tokens/sec that the
  same checkpoint reaches on an A10G.
- **Turing's native 260 INT4 TOPS is unreachable through the mainstream stacks.** Neither
  AWQ's nor GPTQ's standard kernel issues INT4 tensor-core MMA; they dequantise to fp16 and
  use the fp16 path. So the one architectural advantage Turing has over Ampere for 4-bit is
  not exposed by any serving framework I found. BitBLAS is the only listed Turing-supported
  method that is a *kernel-generation* approach and might; I found no benchmark of it on T4.
- **Framework choice is forced by this.** SGLang removing non-Marlin GPTQ on NVIDIA means a
  quantised T4 deployment is effectively vLLM-or-transformers, not SGLang. That narrows the
  supported-software surface further than the raw hardware matrix suggests.
- **INT8 W8A8 is the quietly reasonable option on a T4**: it is supported, Turing has native
  130 INT8 TOPS (2× its fp16 rate), it halves weights to ~8 GB for a 7B-class model, and —
  unlike AWQ — it does not force an fp16-only checkpoint. I found no T4 W8A8 VLM benchmark,
  so this is a hypothesis to measure, not a finding.

### Gaps
- No measured throughput numbers for AWQ or GPTQ on a T4 for *any* model, let alone a VLM.
  The "it works but is slow" conclusion is architectural reasoning from the Marlin exclusion,
  not a measurement.
- Whether a Qwen2.5-VL AWQ/GPTQ checkpoint quantises the **ViT** or leaves it fp16 is not
  stated by any source I found; my 5.9 GB figure assumes the ViT stays fp16.
- HQQ is absent from vLLM's table entirely, so its Turing status is unknown.

---

## Q5. Serving stacks on T4 in 2026: vLLM, TensorRT-LLM, llama.cpp

### Takeaway
vLLM **still lists compute capability 7.5 as its floor and names the T4 explicitly**, so
Turing is formally supported. But *model-level* VLM support on Turing is broken-by-default:
FlashAttention-2 requires SM80+, and the Qwen-VL model files hard-reject every backend that
isn't FLASH_ATTN / TORCH_SDPA / ROCM_AITER_FA. Working around it requires an undocumented
flag combination, and the measured result was **5–20 tokens/s on a Tesla T4**. TensorRT-LLM
has dropped Turing from its supported-hardware list. PyTorch keeps sm_75 through CUDA 13.2/13.4.

### Cited Findings
- **vLLM floor is unchanged**: the current GPU install docs state the NVIDIA minimum as
  **"compute capability 7.5 or higher"**, with **T4 among the named examples**. No Turing
  deprecation notice, no bfloat16 restriction note on that page —
  [vLLM GPU installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/)
- vLLM default binaries are built for **CUDA 12.9**, with builds for 12.8 and 13.2 —
  [vLLM GPU installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/)
- **⚠️ The VLM-on-Turing reality (vLLM issue #29743, opened 2025-11-30, closed "not planned"
  2026-03-31 after going stale — roughly 12 months old, flag as possibly moved):**
  - Hardware: NVIDIA T4G, compute capability 7.5, Ubuntu 24.04 aarch64, PyTorch 2.9.1,
    CUDA 12.9, vLLM 0.11.3.dev0+g275de3417.
  - `qwen3_vl.py` raises **"Qwen3-VL does not support {self.attn_backend} backend now."**
    for any backend outside FLASH_ATTN, TORCH_SDPA, ROCM_AITER_FA.
  - FLASH_ATTN requires sm80+; logs show **"FA2 is only supported on devices with compute
    capability >= 8."**
  - TORCH_SDPA is "no longer registered" for general attention — the code comment is
    `TORCH_SDPA = "" # this tag is only used for ViT`.
  - Reporter's only known workaround initially was `--enforce-eager`, at **under 10 tokens/s**.
  - Maintainer Isotr0py tested on a **Tesla T4** on main (0.11.2.dev415+g21c262793): the
    FlashInfer backend reached "Application startup complete", with **generation throughput
    about 5 to 20 tokens/s** — and that test used **`-tp 2`, i.e. two T4s**.
  - The working combination is `VLLM_ATTENTION_BACKEND=TRITON_ATTN` **plus**
    `--mm-encoder-attn-backend TORCH_SDPA`; TRITON_ATTN **fails without** the encoder flag.
    The encoder-backend flag came from PRs #27061/#27124 and was **undocumented**; maintainer
    ywang96 called the documentation gap "a valid point".
  - Issue closed with **no fix in the Qwen-VL code**; the working configs are user-reported.
  — [vLLM issue #29743](https://github.com/vllm-project/vllm/issues/29743)
- **TensorRT-LLM no longer lists Turing.** The current supported-hardware page covers
  Blackwell (B200, GB200, B300, GB300, DGX Spark), Hopper (H100, H200, GH200), Ada
  (L20, L40/L40S) and Ampere (A100). No Turing, no T4, no SM75 —
  [TensorRT-LLM supported hardware](https://nvidia.github.io/TensorRT-LLM/supported-hardware.html)
- Older TensorRT-LLM docs *did* include Turing: the support matrix precision table included
  **Turing (SM75)**, and the README said it "is expected to work on GPUs based on the Volta,
  Turing, Ampere, Hopper and Ada Lovelace architectures" —
  [TensorRT-LLM support-matrix.md](https://github.com/NVIDIA/TensorRT-LLM/blob/main/docs/source/supported-hardware.md);
  [support matrix source](https://nvidia.github.io/TensorRT-LLM/_sources/reference/support-matrix.md.txt)
- The newer TensorRT-LLM support matrix wording: if an architecture is not listed, **"the
  TensorRT-LLM team does not develop or test the software on the architecture and support is
  limited to community support"** —
  [TensorRT-LLM support matrix](https://nvidia.github.io/TensorRT-LLM/reference/support-matrix.html)
- **PyTorch keeps Turing.** The 2.15 CUDA support RFC retains Turing through CUDA 13.2 and
  13.4 — "Turing and newer (sm_75+) are unaffected". What is dropped is the CUDA 12.6 build,
  which removes Maxwell (sm_50), Pascal (sm_60) and Volta (sm_70). 2.15 publishes cu132 and
  cu134 wheels only; cu126 and cu130 are gone —
  [pytorch/pytorch issue #190385](https://github.com/pytorch/pytorch/issues/190385);
  [PyTorch dev-discuss notice](https://dev-discuss.pytorch.org/t/notice-cuda-12-6-wheels-will-no-longer-be-published-from-pytorch-2-15-drops-maxwell-pascal-volta/3432)
- CUDA 13 wheels require **NVIDIA driver 580 or newer** —
  [dplouffe PyTorch 2.15 checklist](https://dplouffe.ca/2026/10/29/pytorch-upgrade-checklist-python-3-10/)
  (secondary source; not verified against PyTorch release notes)
- **A real downstream sm_75 regression exists in the CUDA 13 era**: xllamacpp's CUDA wheels
  shipped with no sm_75 code, breaking RTX 2080/2070 and **T4**; a follow-up PR reports
  cu132 wheels failing on Turing with CUDA 13.0/13.1 drivers because of **PTX version 9.2**,
  and proposes shipping Turing as native SASS —
  [xllamacpp issue #190](https://github.com/xorbitsai/xllamacpp/issues/190);
  [xllamacpp PR #192](https://github.com/xorbitsai/xllamacpp/pull/192)
- **llama.cpp**: Qwen2.5-VL GGUF exists with a separate `--mmproj` vision projector, but the
  model page reports no T4 speeds; Qwen vision support "often needs a from-source build
  because the multimodal code merges before it ships in tagged releases", and a **BF16
  projector gives noticeably better image understanding than lower-precision variants** —
  [Mungert Qwen2.5-VL-7B GGUF](https://huggingface.co/Mungert/Qwen2.5-VL-7B-Instruct-GGUF);
  [MindStudio guide](https://www.mindstudio.ai/blog/how-to-run-qwen-vision-models-locally)
- A Turing-targeted llama.cpp fork exists (`llama-tq`, "tuned for running modern models at
  full context on 12 GB Turing GPUs (RTX 2060/2070/2080, T4)") reporting ~24 tok/s decode
  for a 27B model at 72k context with vision enabled on **2× RTX 2060 12 GB** — a different
  model and different hardware, so not transferable —
  [LL4nc33/llama-tq](https://github.com/LL4nc33/llama-tq)
- mmproj projectors can be converted to `{f32,f16,bf16,q8_0,tq1_0,tq2_0}`; **Q4_0
  quantisation of the projector failed** for one user; another reports an mmproj costing
  ~600 MB VRAM — [llama.cpp discussion #15453](https://github.com/ggml-org/llama.cpp/discussions/15453)
- ⚠️ Several SEO-shaped blogs (speediyo, markaicode) claim vLLM's minimum is 7.0 or that
  SM70 is deprecated. These conflict with vLLM's own docs and should not be cited.

### Inferences
- **The headline number for the decision is 5–20 tokens/s on a Tesla T4** — and that was
  measured with tensor parallelism across **two** T4s on a 4B-class VLM. A single T4 serving
  a 3B/7B VLM should be assumed to land at the low end or below. Against the measured
  baseline of 9.7s warm wall-clock on an A10G, a typical structured identification response
  of 60–120 output tokens would take **3–24 seconds of decode alone** at those rates,
  before prefill and vision-tower time.
- **Turing's vLLM support is "the floor says yes, the model files say no".** The install docs
  are generic; the per-model `*_vl.py` backend whitelists are where Turing dies. That is the
  pattern to expect for *future* VLMs too: each new vision model ships with a FLASH_ATTN-first
  backend list and Turing is an afterthought, fixed by community flag-archaeology or not at
  all. Issue #29743 being closed "not planned" after going stale is the clearest signal in
  this research that Turing VLM support is unowned.
- **TensorRT-LLM is off the table.** Turing's removal from the supported-hardware page,
  combined with the explicit "community support" wording for unlisted architectures, means
  the fastest NVIDIA inference path does not apply to a T4 plan.
- **The CUDA 13 transition is a live operational risk for sm_75 even though PyTorch keeps it.**
  The xllamacpp case shows the realistic failure shape: an upstream project builds for
  CUDA 13 and the sm_75 SASS simply isn't in the wheel, with a PTX-version error at runtime.
  Any T4 container should pin and verify its CUDA/driver combination rather than track latest.
- **llama.cpp is the most likely-to-work path but the least measured.** It has no SM75
  exclusion by design, but there is no T4 Qwen2.5-VL benchmark anywhere I could find, the
  multimodal path often needs a from-source build, and the projector wants bf16 (which the
  T4 cannot compute natively). Choosing it means committing to measure it first.

### Gaps
- vLLM issue #29743 is ~12 months old and was about **Qwen3-VL**, not Qwen2.5-VL. Whether
  Qwen2.5-VL's vLLM implementation carries the same backend whitelist is unverified — it is
  an older model and may predate the whitelist. **This is the single most important thing to
  check before trusting or discarding the T4.**
- I found no release note stating *which* TensorRT-LLM version removed Turing.
- No T4 benchmark for llama.cpp + Qwen2.5-VL + mmproj exists in any source I found.

---

## Q6. Cold start: loading a quantised 3B–7B VLM onto a T4 under Modal

### Takeaway
Nobody publishes a T4-specific VLM cold-start number. What is published: Modal containers
boot in ~1 second, so cold start is **dominated by moving weights from storage into GPU
memory**, and Modal's own GPU memory snapshotting cuts that by 6–10× (118s → 12s on a 3B
model). The T4's PCIe Gen3 link is not the bottleneck; weight *fetch* is. Against the
measured 20.5s A10G cold load for ~16 GB of fp16 weights, a ~5 GB 4-bit model should load
proportionally faster, and snapshotting could take it to the ~12s class.

### Cited Findings
- **Modal containers boot in about one second** (separate from model load) —
  [Modal: how we achieved truly serverless GPUs](https://modal.com/blog/truly-serverless-gpus)
- **Modal GPU memory snapshotting, Ministral 3 (3B): median cold start ~118s → ~12s,
  "almost 10x"** — [Modal + Mistral 3 blog](https://modal.com/blog/mistral-3)
- Modal's engineering post reports GPU memory snapshotting cutting cold starts **~6×,
  from ~70s to ~12s** — [Modal: truly serverless GPUs](https://modal.com/blog/truly-serverless-gpus)
- **GPU memory snapshotting is explicitly experimental**: *"GPU memory snapshotting is an
  experimental feature, so test carefully before using in production!"* —
  [Modal docs: snapshot GPU memory](https://modal.com/docs/examples/gpu_snapshot)
- The mechanism requires **enabling Sleep Mode in vLLM**, which "shifts most of the contents
  of GPU memory to CPU memory, which facilitates the snapshotting process" —
  [Modal + Mistral 3](https://modal.com/blog/mistral-3)
- The snapshot **is not materialised on the very first cold start** and may take a few cold
  starts to appear — [continuumcode Modal review](https://continuumcode.ai/guides/modal-review/)
- **Third-party measurements are slower than Modal's**: one developer measured **57s
  time-to-first-token** from a scaled-to-zero vLLM container, attributing most of it to
  restoring **~19 GB of GPU memory state** —
  [logeshumapathi.com, 2026-05](https://logeshumapathi.com/blog/2026/05/17/vllm-serverless.html);
  another reported ~70s. A GitHub issue estimates **~150s for a cold model load from a cache
  volume without snapshots** —
  [blzee-maker/audbre issue #7](https://github.com/blzee-maker/audbre/issues/7)
- T4 interconnect is **PCIe Gen3 x16** —
  [NVIDIA T4 product page](https://www.nvidia.com/en-us/data-center/tesla-t4/)

### Inferences
- **Decompose the project's measured 20.5s A10G cold load.** ~16 GB of fp16 weights in 20.5s
  is an effective **~0.8 GB/s**. PCIe Gen4 x16 is ~32 GB/s, so **PCIe is not the bottleneck
  at all** — the 20.5s is dominated by pulling weights from the image/volume into host memory
  and the framework's deserialisation, not by the host→device copy. Consequently:
  - Moving to a T4's **Gen3** link (~16 GB/s theoretical, ~12 GB/s practical) should cost
    almost nothing on cold start, because the link is ~15× faster than the observed rate.
  - Shrinking the weights is what pays. A ~5.9 GB 4-bit 7B-class checkpoint is **~2.7× less
    data** than the 16 GB fp16 one; at the same 0.8 GB/s effective rate that is a derived
    **~7.5s** cold load. A ~2 GB 4-bit 3B lands near **~2.5s**.
  - Note the direction of the tradeoff: 4-bit improves cold start and memory but, per Q4,
    *worsens* steady-state throughput on Turing because Marlin is unavailable.
- **Snapshotting changes the shape of the problem more than the GPU choice does.** Modal's
  own 3B figure (118s → 12s) and the project's 20.5s A10G number are in the same order; the
  12s floor appears to be snapshot-restore-bound rather than model-size-bound at these sizes.
  If snapshotting is adopted, cold start stops being a differentiator between T4 and A10G.
- **The dependency chain is awkward**: Modal's snapshot path is documented against **vLLM
  sleep mode** — and vLLM is exactly the stack whose VLM support on Turing is broken-by-default
  (Q5). A T4 deployment that falls back to transformers or llama.cpp to get the model running
  may not be able to use the snapshotting path that makes cold start acceptable.
- **Cost arithmetic against the measured baseline** (derived from the prices given):
  - A10G baseline: 9.7s × $1.10/3600 = **$0.00296 per identification**.
  - T4 is 1.86× cheaper per hour. Break-even is at **18.1s** per identification.
  - At the 0.53× bandwidth ratio, a naive expectation is the 7.4s GPU portion becoming
    ~14s, total ~16.3s → **$0.00267**, i.e. ~10% cheaper for ~1.7× worse latency.
  - At the *measured* 5–20 tok/s figure from #29743 (on two T4s), the T4 would be well past
    break-even and both slower **and** more expensive.
  - **The T4 only wins if it stays under 18.1s per identification, and the one measured
    Turing VLM throughput number suggests it may not.**

### Gaps
- No published cold-start measurement for a T4 specifically, for any model. Every Modal
  figure I found is on unnamed or newer GPUs.
- Modal does not publish a snapshot-restore bandwidth figure, so I cannot say whether the
  ~12s floor would be the same on a T4's Gen3 link.
- No source states whether Modal's GPU snapshotting supports T4/Turing at all. Given it is
  experimental, this should be treated as unverified rather than assumed.

---

## Cross-cutting summary for the report writer

**The three facts that decide this, in order of weight:**

1. **A 7B-class VLM in fp16 does not fit 16 GB** (~16 GB of weights alone, derived from the
   model card's "8B params"). Matching the measured A10G baseline *with the same checkpoint
   at the same precision* is arithmetically impossible on a T4. Any T4 plan is a plan to run
   a *different* configuration — 3B, or 4-bit — and therefore needs its own accuracy
   measurement against the 91% baseline, not an inherited one.
2. **Turing has no bf16, and Qwen2.5-VL is bf16 by design.** The fp16 failure is documented,
   reproduced, model-size-specific (3B broke, 7B/72B did not), and was triggered by image
   resolution. It fails *silently* — garbage output, not an exception.
3. **The one published Turing VLM throughput measurement is 5–20 tokens/s on a Tesla T4**,
   and it used two of them. Break-even against the A10G baseline is 18.1s per identification.

**Where the T4 is genuinely fine:** vLLM still formally supports 7.5 and names the T4;
PyTorch keeps sm_75 through CUDA 13.4; AWQ/GPTQ/INT8/bitsandbytes/GGUF all work; Turing has
native 130 INT8 TOPS and 260 INT4 TOPS; PCIe Gen3 is irrelevant to cold start.

**Where it is not:** no Marlin (so 4-bit is compressed but not fast, and Turing's native INT4
throughput is unreachable through mainstream stacks); no FP8; no FlashAttention-2, which is
what the per-model VLM backend whitelists require; TensorRT-LLM has dropped Turing;
SGLang has removed the non-Marlin GPTQ path on NVIDIA; and the one open issue tracking
Turing VLM support was closed "not planned".

**The cheapest decisive experiment**, if hardware time is ever bought: load
Qwen2.5-VL-3B-Instruct on a single T4 under vLLM with `--dtype float16`,
`--mm-processor-kwargs '{"max_pixels": 1003520}'`, `--max-model-len 4096`, and run the
existing clean-cover corpus. That single run answers (a) does the Qwen2.5-VL implementation
carry the same backend whitelist as Qwen3-VL, (b) what is the real tokens/s, and (c) does
fp16 cost accuracy against the 91% baseline. Everything above is bounds; that is measurement.
