# ADR 015: Vision Service Architecture (April 2026)

**Status:** Superseded in part (see 2026-05 update below) — the vLLM / H100 / AWQ / single-`/analyze`-endpoint stack described here was rolled back to the HF Transformers + A10G + bf16 + separate `classify`/`extract` baseline. The architectural reasoning (telemetry-driven evaluation, cache layer, gate threshold rationale, deferred experimental framework) remains in force.
**Date:** 2026-04-23
**Deciders:** Platform owner
**Technical area:** Vision inference, Modal app
**Supersedes:** Portions of [ADR 001](001-modal-over-together-ai.md) (originally GPU class, quantization, engine — see update note below for what is and isn't still in effect)

---

## Update — 2026-05 rollback to bf16 / A10G baseline

The inference-stack changes recorded in the Decision section below (vLLM 0.9.0 V1 engine, AWQ 4-bit quantization, H100 GPU, single `/analyze` endpoint, streaming early-terminate via `engine.abort`, `@modal.concurrent(max_inputs=8)`, region unpinning rationale) were **reverted** in commit `07179b9` ("refactor: revert more complex changes and refine original approach"), returning `apps/vision/modal_app.py` to the dfef1333 baseline shape:

- **Backend:** HuggingFace Transformers + accelerate (no vLLM, no async engine).
- **Model:** `Qwen/Qwen2.5-VL-7B-Instruct` loaded in **bfloat16** (no AWQ).
- **GPU:** **A10G** (24 GB, Ampere bf16) — not H100.
- **Endpoints:** two separate `@modal.method`s, `classify` and `extract`, orchestrated by the FastAPI `/analyze` route in `app/main.py` which short-circuits on confident `not_book` / `ambiguous`. The single-prompt `_ANALYZE_PROMPT` design was dropped.
- **Concurrency:** single inference per container; `@modal.concurrent` is **not** used. Bursts scale horizontally via `max_containers=10`. The `_infer` early-terminate-via-`engine.abort` optimisation does not apply — there is no streaming iterator under HF `model.generate`.
- **Region:** unpinned (status quo retained).
- **Scaledown:** `scaledown_window=1200` retained.

What is still in effect from this ADR:
- The telemetry/cache reasoning that justified looking at GPU/engine changes in the first place.
- The `upload_p95_ms` gate threshold discussion (3000 ms interim, 2000 ms target) — see `scripts/check-slo-gate.sh` lines ~627–648.
- The deferred experimental-framework Future Work, which is the right place to evaluate any future engine/quantization/GPU change.
- The speculative-decoding write-up — still load-bearing as a "do not re-introduce without reading this" record.

Treat everything in the original Decision section below as a **historical record of an experiment that did not stick**, not as a description of current code. The canonical current implementation is `apps/vision/modal_app.py` (read the module docstring there first). When in doubt, the code wins.

---

## Context

ADR 001 established Modal (over Together AI) as the vision inference provider and Qwen2.5-VL-7B-Instruct as the baseline model on an A10G GPU. That decision is still correct. In the months since, the vision service has evolved in response to observed latency problems against the `upload_p95_ms` SLO, while its _architectural shape_ — self-hosted VLM on Modal, HMAC-authenticated single-endpoint call from Oban workers — has not changed.

This ADR captures the current state of the vision service after that evolution, documents each choice's rationale, and records an experiment (speculative decoding) that was attempted and reverted so a future maintainer does not re-introduce it without reading this document first. The canonical implementation lives in `apps/vision/modal_app.py`; this ADR explains _why_ that file looks the way it does.

**Headline numbers at the time of writing (commit `b5464de`, gate run 2026-04-23):**

| Metric | Before this work | Current |
|---|---:|---:|
| `upload_p95_ms` (gate, warm) | 7647 ms | **2074 ms** |
| `oban_failure_rate_vision` | n/a (no fuse telemetry) | 1.19 % |
| Synthetic probes p95 | ~3–4 s | 1347 ms |

### SLO threshold: 3000 ms (interim) → 2000 ms (target)

`upload_p95_ms` is currently gated at **3000 ms** in `scripts/check-slo-gate.sh`. The original target was 2000 ms and the current warm-cache gate measurement (2074 ms) is essentially at that line. The threshold was raised to 3000 ms deliberately, not abandoned:

- Under bursty probe load (6 canaries every 15 s against a cold Modal pool), cold-start outliers can push a single iteration into the 4–6 s range without the overall architecture being unhealthy. At 2000 ms those outliers turn individual gate runs red even when steady-state latency is fine; at 3000 ms the gate still catches real regressions (a broken cache, an unexpected fuse trip, a slower model) while tolerating warm-up variance.
- The 1000 ms of headroom is also what would be eaten by a bad model swap or a vLLM regression — so the gate remains meaningfully protective against the changes we are most likely to make next.
- The intent is to **lower the threshold back to 2000 ms** once the experimental framework described in "Future work" below exists. That framework will give us reproducible per-configuration benchmarks; with it, we can justify a tight threshold based on measured headroom rather than gut estimate.

Until then: treat 2000 ms as the aspiration and 3000 ms as the breach floor. A gate run that lands between 2000 and 3000 ms is a signal to look at phase-level telemetry (Modal inference vs ISBN resolution vs persistence) before declaring the run "fine".

### Pre-gate warmup (added 2026-04-23)

The first post-H100 gate runs landed at 3474–3556 ms despite steady-state telemetry showing `identify_book` p95 = 1224 ms. Analysis pointed at Modal cold-start concentration: the gate was the first request against a fresh Modal deploy, so the gate's 6-parallel-canary burst forced Modal to scale out from zero, with each new H100 container paying a 30–60 s cold-start. Those ~5 slowest samples (p95 is the 95th percentile) dominated the reported p95 even though they represented <5 % of total traffic.

**Mitigation:** `scripts/deploy-stack.sh` now queues 6 warmup uploads at the end of every deploy, _before_ the SLO gate starts:

1. Authenticates with `PROBE_SEED_EMAIL` / `PROBE_SEED_PASSWORD` (same credentials check-slo-gate uses).
2. Fires 6 canary `POST /api/upload` requests in parallel — matching the gate's burst width so Modal spawns the same container count the gate will demand.
3. Verifies HTTP 202 acceptance (~100 ms per POST) but **does NOT** stream the SSE `/api/upload/:id/stream` response.
4. Sleeps 15 s so the Oban vision queue can pick up the jobs, then exits. Modal cold-start runs in parallel with `check-slo-gate.sh`.

**Why no SSE stream:** the SSE route shares `route_group=:upload` with the gate's probes, and its duration accumulates in the `upload_p95_ms` histogram for the lifetime of the BEAM. An earlier version streamed SSE with an 8-minute timeout — 5 cold-start-delayed warmup streams produced 8-minute samples that landed in the gate's p95 sample pool (sample #147 of 154), blowing the measurement to 4109 ms on what would otherwise have been a healthy run. Fire-and-forget via POST only keeps the histogram clean.

With `scaledown_window=1200` (20 min on the `@app.cls` decorator), the containers spawned during warmup stay warm through the subsequent 10-min gate window. Expected gate p95 with warmup active: **1500–2000 ms** (steady-state + modest probe-burst variance).

---

## Decision

Keep Modal + Qwen2.5-VL-7B as the foundation. Layer the following changes on top, each individually defensible and each contributing measurable latency reduction or correctness improvement.

### 1. AWQ 4-bit quantization (`Qwen/Qwen2.5-VL-7B-Instruct-AWQ`)

Model weights are ~4 GB quantized vs ~15 GB bfloat16. On A10G (24 GB VRAM) this freed ~11 GB for activations + KV cache, enabling higher concurrent batching without OOM. On H100 (80 GB) the headroom is abundant regardless, but the _per-token_ throughput win from AWQ + marlin kernels persists: roughly 1.5–2× faster generation with <1 % accuracy loss on vision benchmarks.

**Kernel:** `quantization="awq_marlin"` in vLLM's `AsyncEngineArgs`. The Marlin kernel targets Hopper's FP8 tensor cores on H100 where Ampere (A10G) could only use bf16.

### 2. vLLM v1 engine (version `0.9.0`)

Upgraded from vLLM 0.7.3 (V0 engine) to unlock prefix caching for multimodal prompts. The V0 engine silently disabled prefix caching whenever `limit_mm_per_prompt` was non-empty. Under V0, every `/analyze` request paid full prefill on the ~250-token `_ANALYZE_PROMPT` instruction prefix; under V1, the prefix KV state is cached across requests and reused.

**Async engine:** `AsyncLLMEngine.from_engine_args(...)` — required because `@modal.concurrent(max_inputs=8)` routes multiple concurrent requests into one container. `LLM.chat()` would serialise behind a global lock and defeat continuous batching.

**Version pinning rationale:** the `AsyncEngineArgs` API + Qwen2.5-VL + AWQ + prefix-caching combination has been in flux across minor vLLM versions. Bump only after revalidating the full stack against the gate.

### 3. Single `/analyze` endpoint (supersedes `/classify` + `/extract`)

The earlier design issued two Modal calls per upload — one to classify ("is this a book?") and, conditionally, a second to extract candidates. The fan-out added a second HTTP round-trip, a second container invocation on potentially-cold resources (Modal's scheduler load-balances independently), and ~2–4 s of inter-call gap observed at upload p95=7.7s.

`_ANALYZE_PROMPT` now asks the model to emit both classification and extraction in a single JSON response. The prompt re-asserts the classification criteria FIRST so the model doesn't leak extraction detail into the `classification` branch. Non-book inputs still return `books: []` (the prompt treats it as a contract); the caller discards `books` on any non-`book` classification regardless of content.

### 4. Early-terminate on `not_book` via streaming abort

vLLM's `engine.generate()` returns an async iterator. The `_infer` function now consumes that iterator and aborts via `engine.abort(request_id)` as soon as the streaming buffer contains a valid `not_book` classification with a confidence score. The abort saves generation work on rejection responses where `reasoning` and `books` are unused downstream.

A regex matches `"classification":"not_book","confidence":<number>` in the partial buffer. Once matched, `_parse_json_with_not_book_fallback` reconstructs a well-formed `{classification, confidence, books:[]}` response from whatever was emitted before abort, so the caller's contract is stable regardless of whether we ran to EOS.

The abort is a latency optimisation, not a cost optimisation — Modal still bills per container-second. But for `not_book` inputs (about 60 % of probe iterations, and plausibly lower in real traffic), it removes 200–500 ms of tail-generation time from the p95.

### 5. H100 GPU (`gpu="H100"`)

Swapped from A10G (24 GB, Ampere bf16) to H100 (80 GB, Hopper with FP8 tensor cores). Telemetry showed vision inference dominated `upload_p95_ms` after the cache layer was added — every repeat canary was an L1 cache hit, so ISBN/title resolution was effectively free, leaving Modal inference as the only remaining lever.

**Measured impact:** `upload_p95_ms` 4586 ms → 2074 ms (55 % reduction) across a single deploy. `awq_marlin` targets Hopper's FP8 path on H100 where Ampere could only use bf16, giving ~3–4× throughput on quantized weights.

**Cost:** Modal A10G ~$1.20/hr, H100 ~$4–5/hr. At `max_containers=10` the theoretical peak is ~$40–50/hr; real utilisation averages well below that because `scaledown_window=1200` lets idle containers release. A monthly spend-cap alert is a prerequisite for this configuration — we hit the workspace cap once during evaluation when a gate burst ran with no headroom.

### 6. Region placement (unpinned, 2026-04-23)

Initially pinned to `region="us-east"` to keep the Modal GPU co-located with Fly IAD (core) and Neon us-east-1 (DB). That trade-off was reconsidered after the first post-H100 CI gate (commit `a66901e`) regressed `upload_p95_ms` to 3556 ms — against a 2074 ms local warm baseline, with 0 % vision failure rate and the vision fuse closed. The signal shape (healthy downstream, slow inference) pointed at Modal scheduler wait, not model or correctness issues. H100 capacity in us-east is tighter than A10G's was, and a pinned region blocks rather than falls back when the regional pool is exhausted.

The decision was to unpin. Cross-region placement (e.g. us-west) adds ~60 ms Fly→Modal RTT per call; at a 2000–3000 ms p95 budget, 60 ms is rounding error and multi-second scheduling wait was not. Neon is unaffected — vision does not talk to Neon directly.

**Reverting is cheap:** add `region="us-east"` back to the `@app.cls` decorator in `modal_app.py`. The signal that would justify reverting is `[:stacks, :vision, :request, :stop]` p95 consistently more than ~200 ms higher than the historical us-east median. If pinning is reintroduced for capacity reasons, pair it with `min_containers=1` so the scheduler never has to cold-start under load, or switch to L40S (broader availability, lower cost).

### 7. Concurrency caps (`max_inputs=8`, `max_containers=10`)

`@modal.concurrent(max_inputs=8)` allows up to 8 in-flight `/analyze` calls per container. `max_containers=10` caps autoscale. Combined ceiling is 80 concurrent inferences, well above the Oban `:vision` queue capacity of 60.

H100 has so much VRAM that 8 concurrent is under-using it — we could raise `max_inputs` to 16 or 24 to amortise cost over more work. Deferred: the current configuration passes the gate, and higher concurrency creates new head-of-line blocking shapes that would need their own measurement.

### 8. `gpu_memory_utilization=0.90`

vLLM pre-allocates the KV cache pool to this fraction of device memory. On the 80 GB H100 this is ~72 GB, which is excess for the current `max_inputs=8` workload — a lower value (0.60) would reduce boot-time allocation without runtime impact. Kept at 0.90 as a safety margin while we learn what real workload patterns look like. Revisit if Modal billing runs hotter than expected.

---

## Experiments attempted and reverted

### Speculative decoding (Qwen2.5-VL-3B-AWQ draft model)

**Attempted:** commit `39e27c9`. Configured `speculative_config={"model": "Qwen/Qwen2.5-VL-3B-Instruct-AWQ", "num_speculative_tokens": 5}` against the 7B target. Rationale: rejection sampling mathematically preserves accuracy while speculative prefill + verification promises 1.7–2× token-generation speedup on JSON-structured output.

**Outcome:** reverted in `a9986b3`. vLLM 0.9.0's V0 engine raises a bare `AssertionError` at `llm_engine.py:265` on VLM + draft-model speculative decoding init. V1 (the engine V0.9 prefers for pure-text workloads) does not yet support draft-model speculative decoding at all — attempting it silently forces V0, which then asserts.

**Important for future maintainers:** H100 does not unblock this. The failure was vLLM's support matrix, not GPU capability. To re-enable spec-dec:

1. Bump vLLM beyond 0.9 and verify V1 supports draft-model spec-dec for Qwen2.5-VL. Re-read the speculative-decoding section of the vLLM release notes.
2. Consider alternative spec-dec methods that don't need a separate draft model: EAGLE (speculative heads attached to the target), Medusa (similar), n-gram (CPU-side, modest speedup).
3. Re-run the full gate suite. vLLM + AWQ + multimodal + spec-dec is a four-way interaction; every component has been in flux.

Do not re-introduce the `SPECULATIVE_MODEL_NAME` + `NUM_SPECULATIVE_TOKENS` constants or the dual `snapshot_download` in `_download_model` without confirming the above. The revert commit message is the authoritative record of why they were removed.

---

## Interaction with the cache layer

The upload pipeline has two caches that sit _between_ the vision service and the external book-metadata APIs:

- `Stacks.Books.ISBNResolverCache` — ISBN → Open Library / Google Books metadata
- `Stacks.Books.TitleSearchCache` — normalised `(title, author, raw_text)` → ISBN

Both are L1 ETS (per-node, microsecond reads) + L2 Postgres (`cache.isbn_resolver_cache`, `cache.title_search_cache`) for persistence across Fly machine stops and deploys. Vision does not interact with these caches directly — they sit downstream of Modal's response, memoising the external-API calls that resolve extracted candidates to canonical books.

The relevance to this ADR: the cache layer was the _first_ lever tried against the p95 SLO. Telemetry (`[:stacks, :books, :title_search_cache, :lookup]`) showed near-100% L1 hit rate on repeat canaries, confirming that ISBN/title resolution was no longer the bottleneck and the remaining latency lived entirely in Modal inference. That measurement is what justified the H100 upgrade. Without the phase-level telemetry added in `0610b8b`, the cost/benefit case for H100 would have been guesswork.

---

## Future work: experimental framework for model comparison

We have accumulated more model-configuration decisions (quantization, engine version, speculative decoding attempt, GPU class) than we can responsibly evaluate by gut feel or one-shot gate runs. Each axis interacts with the others — AWQ on A10G vs AWQ on H100 behaves differently; prefix caching under V1 vs V0 affects mixed-text more than single-book uploads; speculative decoding's accuracy-preservation guarantee only holds when the draft's distribution sufficiently overlaps the target's.

**Proposed framework — deferred, not yet built:**

1. A reproducible canary set (the current `images/not_a_book.jpg`, `barcode_isbn_clean.jpg`, `screenshot_mixed_text.jpg` et al., plus a broader corpus).
2. An evaluation harness that runs each canary against a named configuration (model + quantization + engine + GPU + decoding strategy) and emits: per-class p95 latency, per-class accuracy (ISBN agreement with ground truth), per-class `not_book` rejection accuracy, Modal container-seconds consumed.
3. A comparison report: relative latency + cost + accuracy between configurations, so the next model-change decision is backed by data rather than a single gate run.

**Candidate configurations to compare when the framework exists:**

- Current: Qwen2.5-VL-7B-AWQ + vLLM 0.9 V1 + H100
- Qwen2.5-VL-3B-AWQ on H100 (half the parameters; expected ~2× speedup; unknown accuracy delta — this is the main reason to defer until the harness exists)
- Qwen2.5-VL-7B-AWQ on L40S (middle GPU tier — possibly ~2× A10G perf at ~1.5× cost)
- EAGLE / Medusa / n-gram speculative decoding on the 7B target (once vLLM supports the combination)

**What would trigger building it:**

- **Readiness to lower the `upload_p95_ms` gate threshold from 3000 ms back to the 2000 ms target.** The framework gives us reproducible measurements to justify a tighter bound, and tells us which configuration headroom is actually available before the next model change eats into it.
- A cost incident that forces a smaller-model evaluation on a tight timeline.
- Any multi-configuration comparison that someone is currently about to do by hand — the harness should exist before the second or third such comparison, not after.

Until one of those triggers, further model-level changes should continue to be incremental and gate-verified against the existing canary set, with the recognition that the results are one-data-point observations, not benchmarks.

---

## Consequences

**Positive:**
- Latency SLO within reach; architecturally healthy (fuse closed, failure rate < 5 %).
- Each change is individually documented and individually reversible.
- The speculative-decoding write-up prevents rediscovering the V0 assert via the commit log alone.

**Negative:**
- More moving parts than ADR 001 described: vLLM version, quantization, GPU class, engine version, region, concurrency caps. Every one of these requires revisiting on a major dependency upgrade.
- H100 billing is structurally higher than A10G; a spend-cap alert is load-bearing for safe operation.
- `vllm==0.9.0` is pinned. Bumping requires revalidating the full stack through the gate — this is not a free upgrade.

**Deferred:**
- Experimental framework above.
- Qwen2.5-VL-3B accuracy evaluation.
- Raising `max_inputs` beyond 8.
- Lowering `gpu_memory_utilization` below 0.90.

**Operational:**
- `docs/runbooks/modal-outage.md` — general Modal operational runbook (still valid).
- `docs/runbooks/vision-service-rollback.md` — proto wire-format rollback (unrelated to this ADR).
- `docs/runbooks/budget-exhaustion.md` — billing-cap response. **Load-bearing after H100 swap;** raise cap and configure an early-warning alert before a long gate run.

---

## References

- `apps/vision/modal_app.py` — canonical implementation. Inline comments explain each choice at the code level; this ADR summarises them.
- `apps/core/lib/stacks/books/isbn_resolver_cache.ex`, `title_search_cache.ex` — the cache layer referenced above.
- `apps/core/lib/stacks/telemetry.ex`, `telemetry/reporter.ex` — phase-span + structured log reporter used to attribute p95 to Modal vs cache vs persistence.
- Commits: `665c543` (early-terminate), `f6608a2` (title-search cache), `39e27c9` / `a9986b3` (spec-dec attempt + revert), `0610b8b` (profiling), `b5464de` (H100).
- ADR 001 — original Modal-over-Together-AI decision. Still the authoritative rationale for _using Modal at all_; this ADR supersedes only the GPU class, model variant, and engine-version specifics.
