# Improving Responsiveness of a Cold-Start-Dominated Serverless-GPU Vision Pipeline (Modal T4, Nov 2026)

> Scope: concrete, ranked, costed techniques to cut cold-start / perceived latency for a Qwen3-VL-4B vision service on a Modal T4 (scale-to-zero, $50/mo total inference budget), classified by whether they are (a) INVISIBLE to UX, (b) a minor UX addition that rides the existing SSE stream, or (c) a real flow change. Current-state as of November 2026. Every technique below also assumes the project's measured baseline: cold ≈ 26–32s (≈15s container/boot + ≈25s model-load reported; see note on the discrepancy under Q1/Q2), warm ≈ 2.4–7.6s, ~94% of requests cold at hobby traffic, p95 ≈ 32.6s vs a target of p50 ≤ 5s / p95 ≤ 15s perceived.

## Q1. Modal-specific cold-start mitigation (snapshots, min/buffer containers, boot reduction) as of Nov 2026

### Takeaway
Modal's headline lever is **GPU Memory Snapshots** (restore CUDA/GPU state instead of re-running imports + JIT/CUDA compile), reported at up to ~10x faster cold starts — but it is **alpha**, needs code rewrites, does **not** speed weight loading, and Modal does **not** confirm T4/Turing support (the single biggest open risk for this project). The warm-capacity knobs (`min_containers`, `buffer_containers`, `scaledown_window`) all trade cold-start latency for *billed idle GPU time*, so on a $50 T4 budget only partial/scheduled use is viable.

### Cited Findings
- **GPU Memory Snapshots exist and are the primary cold-start feature.** Enabled with `enable_memory_snapshot=True` plus `experimental_options={"enable_gpu_snapshot": True}`; GPU-loading work goes in a `@modal.enter(snap=True)` method so it runs before the snapshot — [Modal docs: Memory Snapshots](https://modal.com/docs/guide/memory-snapshots); [Modal GPU snapshot example](https://modal.com/docs/examples/gpu_snapshot).
- **Reported speedups (P0 cold-start times):** Parakeet ~20s → as low as 2s; ViT with torch.compile 8.5s → 2.25s; vLLM Qwen2.5-0.5B 45s → 5s; "Functions starting up to 10x faster than baseline." — [Modal blog, GPU Memory Snapshots, Jul 30 2025](https://modal.com/blog/gpu-mem-snapshots).
- **Most recent datapoint (Dec 2 2025):** Ministral 3 **3B** served with vLLM, median cold start **~118s → ~12s (≈9.8x)** using Sleep Mode + `enable_gpu_snapshot`. GPU type not named; speedup reported for one model size only; still "in alpha." — [Modal blog, Mistral 3, Dec 2 2025](https://modal.com/blog/mistral-3).
- **Snapshots do NOT speed weight loading from storage:** "GPU Memory Snapshots do not speed up model loading from storage," and for weight-bound startups they "will generally not improve your cold start times — and may even worsen them, by adding overhead." They are "better suited to skipping imports and JIT compilation." — [Modal docs: Memory Snapshots](https://modal.com/docs/guide/memory-snapshots).
- **GPU snapshot caveats:** alpha; generally incompatible with multi-GPU and non-CUDA/graphics code; `torch.compile` can make snapshot creation fail (mitigate with `TORCHINDUCTOR_COMPILE_THREADS=1`); many functions need code rewrites; GPU functions need ~2–3 snapshots per GPU type and snapshots are recaptured over time; deleting files in a Volume used during restore breaks restore; random state is frozen at snapshot time (breaks uniqueness assumptions); first-request work shows as tail latency unless warmup passes are included in the snapshot phase. — [Modal docs: Memory Snapshots](https://modal.com/docs/guide/memory-snapshots).
- **Driver dependency:** The GPU-snapshot blog ties the feature to NVIDIA driver **570/575 branches** and CUDA checkpoint/restore; "the underlying checkpoint/restore technology in the device drivers is still quite new." — [Modal blog, GPU Memory Snapshots](https://modal.com/blog/gpu-mem-snapshots).
- **Underlying `cuda-checkpoint` constraints:** Linux only, x64 only, single process (not a process tree), no UVM or IPC memory, no GPU migration; restore must be onto the **same chip type** with enough memory and requires persistence mode / prior `cuInit`; "as of display driver 550 … still being actively developed." NVIDIA's own docs/repo do **not** state Turing/T4 support (research benchmarks used H100/A100). — [NVIDIA/cuda-checkpoint (GitHub)](https://github.com/NVIDIA/cuda-checkpoint); [NVIDIA CUDA Checkpointing driver API](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__CHECKPOINT.html).
- **Warm-capacity knobs:**
  - `min_containers` — floor that keeps N containers warm so the function doesn't scale to zero (example uses 3). — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md).
  - `buffer_containers` — spare idle containers kept while the function is *active* so new inputs don't queue behind a fresh boot; helps bursty traffic (example 3). — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md).
  - `scaledown_window` — idle time before shutdown; **default 60s**, range **2s–20min**; "longer windows cost more because you pay for idle resources." Both `min_containers` and `buffer_containers`/scaledown can be changed at runtime and revert to decorator values on next deploy. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); [Modal scale guide](https://modal.com/docs/guide/scale).
- **Warm containers are billed while idle:** Modal bills GPU, CPU and memory per second *while a container runs*, so anything kept warm via `min_containers`/long `scaledown_window` is billed for its idle time. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); third-party confirmation [activepieces Modal pricing 2026](https://www.activepieces.com/blog/modal-labs-pricing-2026-gpu-rates-plans-and-credits).
- **Container "boot" per Modal is ~1s**, not 15s: "Containers boot in about one second," but a container is not *warm* until global-scope code (imports) and all `@modal.enter` methods finish; "Containers will not be considered warm until all `enter` methods have completed." Downloading large models during boot is the main slowdown; pre-downloading weights "can reduce boot from minutes to seconds." — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md).
- **No Modal feature reduces the pure sandbox boot further** than the ~1s it already is; the lever for the non-weight portion (imports, CUDA init, kernel/JIT compile) is specifically GPU snapshots. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); [Modal memory snapshots](https://modal.com/docs/guide/memory-snapshots).

### Inferences
- **The project's measured "~15s container boot" is almost entirely the snapshot-addressable layer** (imports, torch/transformers init, CUDA context + kernel/JIT compile) — exactly what GPU snapshots skip — whereas the "~25s model-load" splits into weight load (snapshots do NOT help) plus GPU-transfer/compile (snapshots DO help). So GPU snapshots target the *larger, non-weight* share of this pipeline's cold start. If the reported Qwen2.5-0.5B 45s→5s and Ministral-3B 118s→12s ratios hold shape on a 4B, a realistic cold-start for this service could drop from ~26–32s toward roughly single-digit-to-~12s — which would by itself bring p95 under the 15s target without any UX change.
- **Classification: GPU snapshots = (a) INVISIBLE to UX** (pure infra/code change). This is the single highest-leverage *invisible* technique available — IF it runs on T4.
- **The gating risk is hardware:** Qwen3-VL uses HF `transformers` on a T4 (Turing). GPU snapshots are proven by Modal on A10G/H100-class cards with vLLM; neither Modal nor NVIDIA confirms Turing/T4 checkpoint-restore. This must be empirically tested on the project's actual T4 + driver before being ranked #1. Using HF transformers (not vLLM) also means the project cannot copy Modal's vLLM "sleep/wake" recipe verbatim; it would place `transformers`/CUDA init in a `@modal.enter(snap=True)` and accept possible `torch.compile` incompatibilities.
- **`min_containers=1` persistent warm T4 is out of budget** (~$425/mo, see Q6 math) — so this knob is only usable scheduled/partial, covered in Q6.
- **`buffer_containers` is nearly useless at hobby traffic** because it only helps when the function is already *active* (concurrent/bursty inputs); at 12–48 uploads/day that rarely overlap, there is almost never an active container to buffer behind.

### Gaps
- **Whether GPU Memory Snapshots work on a T4/Turing at all is unconfirmed by any source.** Neither Modal's docs/blogs nor NVIDIA's cuda-checkpoint docs state Turing support; all public benchmarks use A10G/H100/A100. Requires a direct test on the project's T4 + driver branch. If unsupported, the project's biggest *invisible* lever is gone and it must lean on Q3–Q6.
- No public figure for snapshot speedup on an HF-`transformers` (non-vLLM) VLM, nor for a 4B specifically; the 0.5B/3B numbers are the nearest proxies.

## Q2. Weight-load reduction — is it worth it? (confirm it is NOT the lever)

### Takeaway
Confirmed: for this pipeline weight-load is a small, already-near-optimal share, and the techniques that attack it are either low-yield here or counter-productive. Do not spend effort shrinking a ~4s weight load.

### Cited Findings
- **Snapshots explicitly do not help weight load** (restated): weight-bound startups get no benefit and may get *worse* with snapshots. — [Modal docs: Memory Snapshots](https://modal.com/docs/guide/memory-snapshots).
- **Pre-download weights into the Image or a Modal Volume** rather than downloading on every cold start; this is the main weight-load reduction and "can reduce boot from minutes to seconds" for tens-of-GB models. Modal's Volume file-system cache is described as ~3–5x faster than downloading without a cache. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); [Modal GPU snapshot blog](https://modal.com/blog/gpu-mem-snapshots).
- **Load independent large files concurrently** (ThreadPoolExecutor), and beware the Python GIL blocking parallelism. Relevant only when loading several files. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md).

### Inferences
- A 4B model in fp16 is ~8GB; the project already reports only ~4s to load it, implying weights are already baked into the image/Volume (not re-downloaded). safetensors/mmap, lower dtype (int8/int4), or faster loaders might shave 1–2s but cannot touch the ~15s import/CUDA-init layer that dominates. **Net: weight-load reduction is confirmed NOT the lever; it is a rounding error against the cold-start total.** Smaller dtype also risks the ISBN/vision accuracy the hard gate depends on — a bad trade for ~seconds.
- Classification: any weight-load tweak = (a) INVISIBLE, but low value — deprioritize.

### Gaps
- None material; the project's own ~4s measurement already settles this.

## Q3. The answer-now / confirm-later (speculative / progressive) pattern — names, evidence, failure modes

### Takeaway
This is a well-established family under several names — **optimistic UI**, **speculative execution/tool-calling**, and (for the CPU→GPU tiering specifically) a **model cascade** with a deferral rule. It rides the project's existing SSE stream, so it is a **(b) minor UX addition, not a flow change**. The dominant failure mode is showing a confident wrong early answer and having to retract it — which the project's ISBN hard gate largely neutralizes.

### Cited Findings
- **Speculative execution saves real latency:** incident.io calls the LLM before a tool result is confirmed and re-calls with the error if it was wrong; reports **2–3s saved per interaction, ~50% latency reduction for most users.** — [incident.io: speculative tool calling](https://incident.io/building-with-ai/speculative-tool-calling).
- **Optimistic UI** is standard in Gmail/Slack (message shown before server confirmation); its main risk is "the confirmed result can differ from the prediction, leaving the user in an inconsistent state with no clear remedy." — [theneuralbase: Optimistic UI](https://theneuralbase.com/building-ai-products/learn/intermediate/optimistic-ui/).
- **Model cascade (formal framing):** "first executes the lowest cost model, and uses a deferral rule to determine whether to terminate with its prediction, or to invoke the next cheapest model"; "cascades can reduce the average inference cost if only a small fraction of inputs are deferred." — [arXiv 2404.10136, Language Model Cascades](https://arxiv.org/pdf/2404.10136).
- **Cascade cost/latency trade:** escalated queries cost *more* than an all-premium baseline (you paid for the cheap attempt first); sequential cascading "adds latency every time a query escalates." A cascade escalating 10% of the time can show p50 = one call but p99 = three calls, so "a p50-only SLO can look healthy while the tail is poor." — [tianpan.co: LLM Routing and Model Cascades](https://tianpan.co/blog/2025-11-03-llm-routing-model-cascades); [mohakchugh: LLM routing cascade](https://mohakchugh.is-a.dev/blog/llm-routing-cascade-inference-cost-quality-optimization).
- **Fallback vs. cascade distinction:** a fallback exists to keep the system *available*; a cascade exists to make it *cheap-but-correct* (escalates on the cheap answer's quality). — [alpeshnakrani: static/dynamic/cascade/fallback/ensemble](https://alpeshnakrani.com/books/routing/static-dynamic-cascade-fallback-ensemble-five-words-that-are-not-synonyms/).
- **Threshold drift failure mode:** a confidence threshold "tuned in March can start passing bad answers in June as your traffic mix shifts." — [tianpan.co: LLM Routing and Model Cascades](https://tianpan.co/blog/2025-11-03-llm-routing-model-cascades).
- **Mitigations named in the literature:** run models in parallel with speculation; stream the cheap answer while a verifier checks it; route obviously-easy/obviously-hard cases directly and reserve the cascade for the ambiguous middle. "Speculative cascades" (combine cascade savings + speculative-decoding latency) is a 2026 preprint with limited independent validation. — [tianpan.co](https://tianpan.co/blog/2025-11-03-llm-routing-model-cascades); [arXiv 2406.14424](https://arxiv.org/html/2406.14424v1).

### Inferences
- **The right name for this project's design is a cost/latency cascade with an immediate (optimistic) first response over SSE**: CPU tier (barcode → OCR→catalogue match) answers immediately; GPU (Qwen3-VL) is the escalation tier, woken only when the CPU tier can't resolve. Because the pipeline is *already* async behind Oban + SSE, surfacing "we think this is X (checking…)" then a refine event is a progress-stream addition, **not a new user step → classification (b)**.
- **The classic failure mode (retracting a wrong early answer) is strongly mitigated here by the ISBN hard gate.** A barcode decode that verifies against Open Library/Google Books is not speculative — it is *correct* and final; it needs no GPU confirmation at all. Only the OCR→catalogue-match tier is genuinely speculative, and it too passes the same ISBN verification before being shown as confirmed. So the project can show the *verified* CPU answer as final (no retraction) and reserve "still looking…" for the unresolved tail. This avoids the optimistic-UI inconsistency risk almost entirely.
- The cascade's "p50 healthy, p99 poor" warning is exactly this project's situation inverted: here the CPU tier *improves* the tail (removes the GPU wake) rather than adding to it, provided the CPU tier is the first hop and returns in sub-second.

### Gaps
- No single canonical industry name for "verified-cheap-tier-now, GPU-refine-later"; it is a cascade + optimistic-UI composite. Report-writer should present it as such rather than claim a single term of art.

## Q4. Reducing how often the GPU is woken — CPU-first resolution rate vs p95

### Takeaway
At this traffic, **the only way to hit p95 ≤ 15s by avoiding cold starts is to resolve the overwhelming majority of requests on CPU** — roughly ≥95% — because p95 is set by the fraction of requests that still hit a cold GPU. This is the highest-leverage lever that is fully within the project's control and mostly invisible to UX.

### Cited Findings
- Cascades "reduce average inference cost if only a small fraction of inputs are deferred" — the inverse statement (the cost/latency you keep is proportional to the deferral rate) is the governing relationship. — [arXiv 2404.10136](https://arxiv.org/pdf/2404.10136).
- Practitioner arithmetic example: if the economy tier handles 70% correctly, you only pay premium on the remaining 30%. — [mohakchugh](https://mohakchugh.is-a.dev/blog/llm-routing-cascade-inference-cost-quality-optimization).

### Inferences (arithmetic derived from the project's own measured numbers — not externally cited)
- Let **f** = fraction of uploads resolved on CPU (sub-second, no GPU wake), and assume the baseline "94% of GPU-bound requests are cold." The fraction of all uploads that experience a cold-GPU wait is **(1 − f) × 0.94**.
  - p95 ≤ 15s (i.e. the cold path must fall out of the top 5%) requires **(1 − f) × 0.94 ≤ 0.05 → f ≥ ~0.947**. **≈95% CPU resolution is the threshold** to get p95 under target purely by avoiding GPU.
  - p50 ≤ 5s requires the cold path to be below the top 50% → **(1 − f) × 0.94 ≤ 0.50 → f ≥ ~0.47.** So ~47% CPU resolution already fixes the *median*; the *tail* is what demands ~95%.
- Worked points (perceived p95, assuming CPU answers ≈ sub-second and are shown immediately; cold GPU ≈ 32s):
  - f = 0.50 → 47% of requests hit cold GPU → p95 ≈ 32s (tail unchanged).
  - f = 0.80 → 18.8% cold → p95 ≈ 32s (still above the 95th percentile).
  - f = 0.90 → 9.4% cold → p95 ≈ 32s (just misses).
  - f = 0.95 → 4.7% cold → **p95 ≈ warm/CPU (≈ ≤8s)** — target met.
  - f = 0.95 **combined with** a GPU-snapshot'd cold path of ~10–12s → p95 ≈ 10–12s with comfortable margin; and even f ≈ 0.90 passes once the cold path itself is ≤15s.
- **Key consequence:** CPU-first and GPU-snapshots are complementary, and *either one alone is marginal* — CPU-first alone needs an implausibly high ~95% barcode/OCR hit-rate to fix the tail; snapshots alone need T4 support. Together, a moderate CPU hit-rate (~70–90%) plus a ~10–12s snapshot cold path clears both p50 and p95. This is the strongest recommendation of the whole study.
- Classification: the CPU tier itself is **(a) INVISIBLE** (it runs before any GPU wake and, when it verifies an ISBN, returns the final answer). Surfacing "still looking…" for the unresolved tail is the **(b)** SSE addition from Q3. No flow change.

### Gaps
- The project's **actual CPU-tier hit-rate is unknown** (barcode-decodable fraction of reader photos; planned OCR→catalogue-match recall). This single empirical number determines whether CPU-first alone is sufficient or must be paired with snapshots/warming. Must be measured on real upload samples. The barcode-only rate is likely well below 95% for arbitrary reader photos (angled spines, no visible barcode), which is why the snapshot/warming levers remain necessary for the tail.

## Q5. Request coalescing / batching at sparse traffic

### Takeaway
Modal supports dynamic batching (`@modal.batched`), but at 12–48 uploads/day that essentially never overlap, batching gives **no cold-start or responsiveness benefit** and can only *add* up to `wait_ms` of latency. It is a throughput tool for concurrent load, not a sparse-traffic tool. Do not adopt it for responsiveness.

### Cited Findings
- `@modal.batched` waits for the lesser of `max_batch_size` requests or `wait_ms`, whichever comes first; set `wait_ms` to (target latency − execution time). — [Modal docs: Dynamic batching (beta)](https://modal.com/docs/guide/dynamic-batching).
- Vendor-published gain is a *throughput* gain under concurrency: Whisper batch size 64 raised throughput from ~1.2 to ~3.3 req/s per container. — [Modal blog: Batching Whisper](https://modal.com/blog/batching-whisper).
- Dynamic batching is still **beta**; Modal's docs don't describe cold-start interaction. — [Modal docs: Dynamic batching](https://modal.com/docs/guide/dynamic-batching).

### Inferences
- With requests arriving minutes-to-hours apart, a batch almost always contains exactly one request, which is simply delayed by up to `wait_ms` and then run alone — pure downside. Batching helps only if the project ever sees short bursts (e.g. a user uploading a whole shelf of photos at once); in that narrow case a small `max_batch_size` with a short `wait_ms` could amortize one cold GPU wake across several photos — but that is an edge optimization, not a responsiveness strategy. Classification: (a) INVISIBLE if used, but **not recommended** at this traffic.

### Gaps
- Whether users ever upload multi-photo bursts (which would make per-session batching worthwhile) is a product-usage question not answerable from Modal docs.

## Q6. Scheduled / predictive warming — real technique and cost

### Takeaway
There is **no native Modal predictive/scheduled autoscaler**; you build it yourself by toggling `min_containers` (or hitting a warm endpoint) on a `modal.Cron`. On a T4 at ~$0.59/hr it is only budget-viable for a **narrow daily window** (~2h/day ≈ $35/mo of the $50 budget), so it is a *partial* mitigation for the tail during known peak hours, not a general fix.

### Cited Findings
- **No Modal predictive-scaling feature found;** guidance is to set `min_containers`/`buffer_containers`/`scaledown_window`, and the practical substitute is a scheduled job you own. `modal.Cron("...")` uses standard cron syntax and is stable across deploys. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); multiple third-party summaries (one notes a developer who "tried pre-warm by hitting the endpoint on a cron — works but defeats the point").
- **T4 price:** ~**$0.59/hr ($0.000164/sec)**, billed per second *only while the container runs*; CPU/memory billed separately (~$0.0472/core-hr, ~$0.0080/GiB-hr). — [computeprices.com: Modal T4](https://computeprices.com/providers/modal/gpus/t4); [activepieces: Modal pricing 2026](https://www.activepieces.com/blog/modal-labs-pricing-2026-gpu-rates-plans-and-credits); [spheron: Modal GPU pricing 2026](https://www.spheron.network/blog/modal-gpu-pricing-2026-per-second-billing/).
- `min_containers` and related knobs are **adjustable at runtime** (revert to decorator defaults on next deploy), which is what makes scheduled toggling feasible without redeploys. — [Modal cold-start guide](https://modal.com/docs/guide/cold-start.md); [Modal scale guide](https://modal.com/docs/guide/scale).

### Inferences (cost math at T4 = $0.59/hr, 30-day month)
- Persistent warm (`min_containers=1`, 24×7): 0.59 × 24 × 30 = **~$425/mo** → blows the $50 budget ~8.5x (matches the figure in the task brief). Out.
- 12h/day warm window: 0.59 × 12 × 30 = **~$212/mo**. Out.
- 4h/day (evening peak): 0.59 × 4 × 30 = **~$71/mo**. Out.
- **2h/day: 0.59 × 2 × 30 = ~$35/mo** — fits only if base inference spend is low (see next bullet).
- 1h/day: **~$18/mo**.
- **Budget headroom check:** base compute is cheap because cold+inference GPU-seconds are few. At 48 uploads/day × 30 = 1,440/mo, each burning ~32s of billed cold+inference GPU time → ~12.8 GPU-hr/mo × $0.59 ≈ **~$7.5/mo** of unavoidable inference. That leaves ~**$40/mo** of the budget, i.e. room for ≈2.25h/day of scheduled warm T4 — but only if snapshots/CPU-first haven't already solved it.
- **Hit-rate problem:** scheduled warming only converts cold→warm for uploads that land *inside* the warmed window. At hobby traffic spread across the day, a 2h window likely catches a minority of uploads unless usage is strongly clustered (e.g. evenings). So scheduled warming is a **low-coverage, tail-only** mitigation — best reserved for a measured peak hour or two, or triggered reactively.
- **Better-value variant (reactive warming, (a) INVISIBLE):** instead of a fixed clock, warm on a *leading signal* — e.g. when a user opens the upload page / starts the camera, fire a cheap warm ping so the GPU boots in parallel with the human taking/cropping the photo (~10–20s of human time that currently overlaps nothing). This spends GPU-seconds only when an upload is actually imminent, giving far better $/hit than clock-based warming, and is invisible to the user. Classification: (a) INVISIBLE. This is the most cost-efficient warming option and should outrank fixed-schedule cron warming.

### Gaps
- No Modal-published cost model for scheduled `min_containers` toggling; all pricing is third-party aggregators (consistent at $0.59/hr but not Modal's own page — verify at modal.com/pricing).
- The upload-funnel timing (does opening the camera reliably precede the GPU-needing request by ~10–20s?) is a project-specific measurement needed to size the reactive-warming win.

## Cross-cutting ranked recommendation (synthesis for the report-writer)

Ranked by responsiveness-per-dollar and respecting "no unnecessary UX change." Letters = UX classification: (a) invisible, (b) rides existing SSE, (c) real flow change.

1. **CPU-first resolution as the first hop of a cascade** — (a)/(b). Resolve barcode + OCR→catalogue (ISBN-verified) *before* any GPU wake; GPU is the escalation tier. Biggest controllable lever; invisible except the optional "still looking…" SSE event. Needs the real CPU hit-rate measured (Q4 gap).
2. **GPU Memory Snapshots on the escalation tier** — (a). Targets the ~15s import/CUDA-init layer (the dominant, non-weight share here); reported up to ~10x, could take the cold path to ~10–12s. **Blocked on confirming T4/Turing support** — must be tested first (Q1 gap). If it works, #1+#2 together clear both p50 and p95 with no warming spend.
3. **Reactive (leading-signal) warming on upload-page/camera open** — (a). Overlaps GPU boot with human photo-taking time; spends GPU-seconds only when an upload is imminent; best $/hit of any warming option. Fits budget as a thin layer.
4. **Pre-bake weights into Image/Volume + concurrent load** — (a). Cheap hygiene; ensures the ~4s weight load isn't secretly a re-download. Low but free value.
5. **Scheduled cron warming of a narrow measured peak window (≤2h/day ≈ ≤$35/mo)** — (a). Only if usage clusters and after 1–3 haven't closed the tail; low coverage per dollar.
6. **Dynamic batching** — (a) but **not recommended** at this traffic; only worth it for multi-photo upload bursts.
7. **Weight-dtype/loader shrinking** — (a) but **deprioritized**; rounding error vs cold start and risks vision accuracy behind the ISBN gate.

**Explicitly avoid:** persistent `min_containers≥1` warm T4 (~$425/mo), long `scaledown_window` as a warm-keeping hack at sparse traffic (bills idle GPU for windows that rarely catch the next upload), and any external message broker / flow redesign (c) — none are justified given the async+SSE architecture already in place.
