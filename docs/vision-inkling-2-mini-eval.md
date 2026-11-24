# Vision model experiment: Inkling 2 Mini vs Qwen3-VL-4B

> **Verdict: do NOT swap. Keep `Qwen/Qwen3-VL-4B-Instruct`.**
> Inkling 2 Mini is an accuracy *trade* (not an upgrade) and a serving *non-starter*
> on the T4 target. Dated 2026-11-24, against the 122-image corpus in
> `apps/core/priv/eval/vision_corpus.exs`, baseline `apps/core/priv/eval/vision_baseline.json`.

## The question

The deployed vision models are comparatively large; the recurring hope was that a
small, open-weights multimodal model could do the identification job **cheaper** (on
our deliberately-cheap Modal **T4 / 16 GB** target) and/or **better**. Inkling 2 Mini
(Thinking Machines Lab, released 2026-11-20, Apache-2.0; a 26.4B-total / ~3.4B-active
looped-MoE, multimodal, 1M context) was the candidate — "Mini", open weights, and
reputed to "run locally with ease".

## What "runs locally with ease" actually means

A quant's output is bit-identical on any GPU, so "local" is about *where it runs*, not
*how small it is*. Inkling's local story is **quantized GGUF/MLX on a 32 GB+
Apple-Silicon unified-memory Mac** — a different regime from a 16 GB dedicated-VRAM
datacenter GPU. A MoE must hold **all** experts resident, so its 26B total params drive
memory even though only ~3.4B compute per token. Unsloth's quant sizes:
`UD-Q2_K_XL` 9.14 GB, `UD-Q3_K_XL` 13.63 GB, `UD-Q4_K_XL` 17.63 GB, full ~22.9 GB.

## How it was served and measured

- **Serving:** llama.cpp (mainline HEAD — it carries the `INKLING2`/`INKLING2_LOOP`
  arch) built with CUDA on Modal, loading the Unsloth GGUF + `mmproj-F16.gguf` (the
  vision projector) via `llama-server`. Q3 ran on an **L4 (24 GB)**; Q2 on the actual
  **T4 (16 GB)**.
- **Fair comparison:** a thin `/analyze` shim replicated the production FastAPI contract
  exactly — the byte-identical classify/extract prompts (`apps/vision/modal_app.py`),
  the `CLASSIFICATION_RESULT_*` enum mapping and book-list parse (`apps/vision/app/main.py`),
  and the 672px `_resize_for_vlm`. So `mix eval.vision` scored Inkling the same way it
  scores the Qwen service, pointed at the Modal URL via `VISION_SERVICE_URL`.
- **VLM isolation:** `/analyze` is a full cascade (barcode → CPU-OCR → cover-embedding →
  VLM). The shim is **VLM-only** by construction, which isolates the model under test.
  Consequence: the **`clean_barcode` stratum is decided by the cascade's barcode tier,
  not the VLM** — those numbers are *not* a VLM comparison and must be read as n/a here.

## Results — per stratum (VLM-decided strata)

`*` on an Inkling-Q2 cell = **unscored because the call timed out**, not model-wrong
(the eval records a timeout as "unscored", not a miss).

| stratum | Qwen3-VL-4B (baseline, full cascade) | Inkling-Q3 (L4) | Inkling-Q2 (T4) |
|---|---|---|---|
| illegible | 1/10 | **8/10** | **7/8\*** |
| book_adjacent | 5/12 | **9/12** | **9/11\*** |
| clear_cover | 22/22 | 22/22 | 22/22 |
| hostile_typography | 2/4 | 3/4 | 3/4 |
| negative (rejection — safety metric) | 20/20 | 19/19 | 20/20 |
| hostile_barcode | 2/20 | 1/20 | 1/14\* |
| hostile_orientation | **12/12** | **0/10** | **1/7\*** |
| clean_barcode *(barcode tier — n/a)* | 18/19 | 0/18 | 1/10\* |
| **overall** | **84/122** | 63/122 | 65/122 (≈25 timed out) |
| **latency** median / slowest | T4, normal | 31 s / 8.1 min | **44 s / 8.5 min** |

## Findings

1. **Accuracy is a trade, not an upgrade.** Inkling's reasoning makes it *markedly
   better* at degraded and contextual text — `illegible` 1→8, `book_adjacent` 5→9 — and
   it ties on clean covers (22/22) and on rejection (perfect, the safety metric). But it
   has a **genuine orientation blind spot**: rotated / mirrored / upside-down covers go
   from Qwen's 12/12 to ~0. This was confirmed *not* a truncation artifact — raising the
   extract token cap from 1024 to 4096 recovered other strata (clear_cover 20→22,
   typography 2→3) but left orientation at ~0. Net on the VLM-decided strata ≈ a wash
   with a completely different shape. (Likely Qwen3-VL was trained with orientation
   augmentation and Inkling was not.)

2. **Serving is a non-starter on the T4.** `UD-Q3_K_XL` (13.63 GB) **OOMs** a 16 GB T4
   outright during inference (`failed to fit params to free device memory … abort`;
   needs an L4/A10G or CPU offload). `UD-Q2_K_XL` (9 GB) fits a T4 but has **catastrophic
   tail latency** — median ~44 s, slowest ~8.5 min, and **~25 of 122 images timed out
   entirely** (no answer within 330 s × 3 retries) because the model over-reasons on
   hard/rotated images. A production T4 vision path cannot do this; the current
   Qwen3-VL-4B serves the T4 reliably.

3. **The tooling is immature** (the model was 3 days old at eval time). Pitfalls, all
   load-bearing, captured for a future revisit:
   - Mainline llama.cpp HEAD loads it, but you must **let it reason** — do NOT pass
     `--reasoning-budget 0`, which forces an empty `<|content_thinking|>` loop and emits
     no JSON. With reasoning on, llama.cpp puts thinking in `reasoning_content` and the
     clean JSON answer in `content` (which the shim reads).
   - The Unsloth llama.cpp fork **will not build in a clean container** — its server has
     an unconditional web-UI asset download that 404s on a shallow clone.
   - Apple **Metal has no optimized kernels** for the Unsloth UD quant (~3 tok/s on an
     M4 Pro — unusable). CUDA only.
   - A T4-fitting quant must stay in ~16 GB with its KV cache and the vision tower's
     activations — Q2, not Q3.

## Verdict and the one thing worth keeping

**Keep `Qwen/Qwen3-VL-4B-Instruct`.** Inkling 2 Mini is not cheaper (Q3 exceeds the T4;
Q2-on-T4 is too slow) and not a clear accuracy win (a profile trade with a real
orientation regression).

The single durable signal: **a reasoning VLM is materially better on hard-to-read /
degraded text** (`illegible` 1→8). The productive direction for the current stack is
therefore *not* a model swap but improving its weak tail — `illegible` (1/10),
`hostile_barcode` (2/20) — via targeted work on the CPU barcode-decode and OCR tiers and
on the VLM prompt, with the ISBN hard gate keeping any weaker read fail-safe. Revisit a
reasoning VLM only if the degraded-text strata become a priority **and** its serving
tooling, latency, and orientation handling have matured.

## Reproduction

The Modal app (`scratchpad/modal_inkling.py`, app name `inkling-eval`) is stopped; the
GGUF volume `inkling-gguf` is retained. To re-run: redeploy, point
`VISION_SERVICE_URL` at the Modal endpoint, and run
`EVAL_VISION_REQUIRED=1 mix eval.vision`. It exits non-zero by design ("a new
architecture earns its own baseline") — read the per-stratum table from stdout rather
than the gate's exit code; compare against `vision_baseline.json` by hand.
