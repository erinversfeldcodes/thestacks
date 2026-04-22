"""
Modal app: Qwen2.5-VL-7B-Instruct vision inference for The Stacks.

This file defines two Modal functions:

  1. VisionModel  — GPU class (A10G) for running Qwen2.5-VL inference.
  2. vision_api   — CPU function hosting the FastAPI app via @modal.asgi_app().
                    HTTPS endpoint: https://erinversfeldcodes--{MODAL_APP_NAME}-vision-api.modal.run

Deploy with:
    modal deploy apps/vision/modal_app.py

The model is baked into the container image at build time, so cold starts
only pay the cost of loading weights into GPU memory (~30s on A10G) rather
than downloading ~15GB from HuggingFace on every container start.
"""

import json
import os
import re
from pathlib import Path
from typing import Any

import modal

# Per-PR deploys override this via the MODAL_APP_NAME env var.
# Local / production deploys use the default.
MODAL_APP_NAME = os.environ.get("MODAL_APP_NAME", "thestacks-vision")

# AWQ-quantized 4-bit Qwen2.5-VL. Weights ~4 GB vs ~15 GB for the
# bfloat16 original, ~2x faster token generation with <1% quality loss
# on vision benchmarks. The freed VRAM (24 GB A10G - ~5 GB weights -
# overhead) supports higher concurrent batching without OOM.
#
# Override via MODEL_NAME env var if the official Qwen AWQ release is
# ever deprecated or a faster community quant emerges.
MODEL_NAME = os.environ.get("MODEL_NAME", "Qwen/Qwen2.5-VL-7B-Instruct-AWQ")


def _download_model() -> None:
    """Pre-download model weights into the container image.

    Runs once at `modal deploy` time (or when the image is invalidated).
    vLLM loads from the local HuggingFace cache directory, so
    `snapshot_download` is sufficient — no need to construct the model
    object at build time (which would also require GPU).
    """
    from huggingface_hub import snapshot_download
    from transformers import AutoProcessor

    snapshot_download(MODEL_NAME)
    AutoProcessor.from_pretrained(MODEL_NAME)  # type: ignore[no-untyped-call]


image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("libzbar0")
    .pip_install(
        # vLLM v1 engine (default in 0.9.x+). Upgraded from 0.7.3 to
        # unlock prefix caching for multimodal prompts — the v0 engine
        # (used by 0.7.3) silently disabled prefix caching for VLMs,
        # forcing a full prefill on the ~250-token `_ANALYZE_PROMPT`
        # instruction prefix on every request. v1 caches that prefix
        # across requests.
        #
        # Draft-model speculative decoding was also attempted here; it
        # is unsupported for VLMs on vLLM 0.9 (V0 asserts on init when
        # combining spec-dec + multimodal; V1 doesn't support draft-
        # model spec-dec yet). Keep this in mind before re-enabling.
        #
        # Pinned to a tested 0.9.x release. Bump only after revalidating
        # the AsyncLLMEngine API surface + Qwen2.5-VL + AWQ combination.
        # All three have been in flux across minor versions.
        "vllm==0.9.0",
        # AWQ kernel backend. `autoawq` ships the optimised CUDA kernels
        # vLLM dispatches to when `quantization="awq_marlin"` is set.
        "autoawq>=0.2.0",
        # Transformers pinned to the compatibility window for vLLM 0.9.x.
        # Historical pitfalls that forced earlier narrow ranges:
        #   * 4.48.x and earlier: no `qwen2_5_vl` architecture (added 4.49.0).
        #   * 4.50.0 (only): removed `Qwen2Tokenizer.all_special_tokens_extended`
        #     which older vLLM versions called directly.
        # vLLM 0.9.x tolerates a wider range; 4.52 is a safe middle.
        # Re-pin in lockstep with vllm when bumping either.
        "transformers==4.52.0",
        "qwen-vl-utils>=0.0.10",
        "huggingface_hub>=0.26.0",
        "Pillow>=10.0.0",
        "pyzbar>=0.1.9",
    )
    .run_function(_download_model)
)

app = modal.App(MODAL_APP_NAME)

_CLASSIFY_PROMPT = (
    "Does this image contain enough information to identify a specific book?\n\n"
    'Answer "book" if ANY of the following are true:\n'
    "  - The image shows a physical book: cover with readable title/author, spine, or barcode.\n"
    "  - The image is a screenshot or photo of text (message, post, article, reading list)\n"
    "    that explicitly names a specific book title or author.\n\n"
    'Answer "not_book" if the image does NOT meet the above criteria. Examples:\n'
    "  - A photo or illustration of an animal, food, a person, or a landscape.\n"
    "  - Artwork, geometric shapes, patterns, logos, or abstract designs without book text.\n"
    "  - A screenshot of text that does not name a specific title or author.\n"
    "  - An image resembling a book cover in composition (rectangle, colours, shapes) but\n"
    "    with no readable title, author name, or ISBN — this is NOT a book.\n\n"
    'Answer "ambiguous" only when the image might show book content but you genuinely\n'
    "cannot tell — e.g. a blurred or cropped image where something rectangular is\n"
    "partially visible but no text is legible.\n\n"
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    '{"classification": "book", "confidence": 0.95,'
    ' "reasoning": "one sentence explaining your decision"}'
)

_EXTRACT_PROMPT = (
    "Extract all books visible or mentioned in this image. For each book, return its title, "
    "author name, and any ISBN numbers visible. If the image is a screenshot of text "
    "(social media post, article, reading list), extract all books mentioned in the text. "
    "For physical book covers, use both the visible text and the cover artwork — illustration "
    "style, subject matter, period, and imagery — as complementary signals to identify the "
    "correct title and author accurately.\n\n"
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    '{"books": [{"title": "...", "author": "...", "potential_isbns": [], "raw_text": "..."}]}\n'
    'If no books can be identified: {"books": []}'
)

# Single-pass prompt: one `model.generate()` yields both the classification
# signal and the extracted book list. The caller (`app.main:/analyze`)
# previously issued classify + extract back-to-back — two container
# invocations, two round-trips. On real book uploads the second call runs
# against a cold container more often than the first because the first
# warmed the class but the Modal scheduler load-balances independently.
# Consolidating halves inference count and removes the inter-call gap
# (~2-4s observed at upload p95=7.7s).
#
# Prompt engineering notes:
#   - The two sub-prompts were added sequentially so the model never sees
#     them together in fine-tuning data. The combined prompt re-asserts
#     the classification criteria FIRST so the model doesn't leak
#     extraction detail into the `classification` branch.
#   - Extraction is conditional on `"book"` classification, but we ask
#     the model to emit `"books": []` for every non-book so the caller
#     never needs a second call. Non-book inputs still return a well-
#     formed payload — `main.py` treats it as a non-book and discards
#     `books` regardless of content (defensive parse — the prompt is a
#     guideline, not a wire contract).
#   - Single JSON object, no nested code fences. `_parse_json` already
#     handles the "model wrapped the response in ```json" case.
_ANALYZE_PROMPT = (
    "Examine this image and determine whether it shows or mentions a book, then "
    "extract every book you can identify.\n\n"
    "CLASSIFICATION — set `classification` to one of:\n"
    '  - "book"       — the image shows a physical book (cover with readable\n'
    "                   title/author, spine, or barcode) OR is a screenshot/photo\n"
    "                   of text that explicitly names a specific book title or author.\n"
    '  - "not_book"   — no book is present and no book is named in legible text.\n'
    "                   Examples: animals, food, landscapes, logos, abstract art,\n"
    "                   a rectangle resembling a cover but with no legible title/author.\n"
    '  - "ambiguous"  — you genuinely cannot tell (blurred/cropped image where\n'
    "                   something book-like is partially visible).\n\n"
    "EXTRACTION — populate `books` with every book identifiable from the image:\n"
    "  - Physical books: use visible text + cover artwork (illustration style,\n"
    "    subject matter, period, imagery) as complementary identification signals.\n"
    "  - Text screenshots: extract every book title/author mentioned in the text.\n"
    '  - If classification is "not_book" or "ambiguous": return `books`: [].\n\n'
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    "{\n"
    '  "classification": "book" | "not_book" | "ambiguous",\n'
    '  "confidence": 0.95,\n'
    '  "reasoning": "one sentence explaining the classification",\n'
    '  "books": [{"title": "...", "author": "...", "potential_isbns": [], "raw_text": "..."}]\n'
    "}"
)


@app.cls(
    gpu="H100",
    image=image,
    # Pin to us-east so the Modal GPU lives in the same region as Fly IAD
    # (core) and Neon us-east-1 (DB). Without pinning, Modal's scheduler
    # places containers wherever H100 capacity exists — a us-west placement
    # adds ~60ms Fly→Modal RTT per /analyze call, compounding with cold
    # starts. Tradeoff: H100 availability in us-east is tighter than A10G;
    # if the pool is exhausted, scheduling blocks rather than falling back.
    # Watch `[:stacks, :vision, :request, :stop]` tail latency after
    # cutover — capacity-bound bursts can push single calls to 30 s+.
    region="us-east",
    # Swapped from A10G (24 GB, Ampere bf16) to H100 (80 GB, Hopper w/ FP8
    # tensor cores). Telemetry showed vision inference was the only
    # remaining lever on `upload_p95_ms` - cache was already hitting at
    # near-100% on repeat canaries, so single-book warm inference at
    # 800-2200 ms and mixed_text at ~4 s is the ceiling. awq_marlin
    # targets Hopper's FP8 path on H100 where A10G could only use bf16,
    # giving ~3-4x throughput on Qwen2.5-VL-7B-AWQ. Expected p95 impact:
    # ~300-700 ms single-book, ~1.2-1.5 s mixed_text.
    # Cap autoscaled containers at 10. With max_inputs=8 each, that's up
    # to 80 concurrent inferences - well above the Oban :vision queue
    # ceiling of 60. At peak ~$40-50/hr (10 * ~$4-5/hr H100); amortises
    # well below that at real utilisation because Modal charges per
    # active container-second and `scaledown_window=1200` lets idle
    # containers release. Re-evaluate `max_containers` if monthly bill
    # runs hotter than expected - H100 is ~4x A10G's per-second cost.
    max_containers=10,
    # 300s allows for cold-start (~30s) + queue wait (up to 120s when concurrent
    # jobs are serialised on a single H100) + inference (~60s for long inputs).
    timeout=300,
    # Keep the container alive for 20 minutes after the last request.
    # Warmup runs at deploy time; E2E upload tests run ~15 minutes later (after
    # all chromium tests complete). 20 min window ensures the GPU is still warm
    # when upload tests start, avoiding a cold-start that would exceed the test timeout.
    scaledown_window=1200,
)
# Accept up to 8 in-flight calls per container. Qwen2.5-VL-7B at bfloat16
# on an A10G uses ~15 GB VRAM for weights; the 24 GB A10G has ~9 GB left
# for activations + KV cache. At 672-px inputs + short prompts, each
# concurrent request's KV cache is <1 GB, so 8 concurrent fits
# comfortably without OOM risk.
#
# Was 4 originally — the probe now fires 6 canaries in parallel per
# iteration, so 4 forced two to queue and pushed iterations to ~27s as
# Modal also occasionally autoscaled cold containers under the burst.
# 8 absorbs the full burst on a single warm container, keeping iteration
# time bounded by the slowest canary's inference rather than Modal-side
# queueing.
@modal.concurrent(max_inputs=8)
class VisionModel:
    @modal.enter()
    async def load(self) -> None:
        """Load the vLLM AsyncLLMEngine + tokenizer.

        AsyncLLMEngine (not the sync `LLM` wrapper) is required here: it
        schedules concurrent `generate()` coroutines through a single
        continuous-batching loop. `LLM.chat()` from multiple threads
        would serialise behind the engine's internal lock — defeating
        the whole point of Modal's `max_inputs=8`.

        `load` is `async` so `AsyncLLMEngine.from_engine_args` runs with
        an active event loop — the engine spawns an internal background
        coroutine for the scheduler, which raises
        `RuntimeError: no running event loop` if constructed from a sync
        context. Modal supports async `@modal.enter`.

        vLLM config choices:
          * quantization="awq_marlin"     — 4-bit AWQ weights served
                                            through the Marlin kernel,
                                            ~1.5-2x faster than plain
                                            "awq".
          * enable_prefix_caching=True    — v1 engine supports prefix
                                            caching for multimodal
                                            models (v0 silently disabled
                                            this for VLMs). Our
                                            `_ANALYZE_PROMPT` is ~250
                                            tokens, identical on every
                                            call, so the prefix KV state
                                            is cached after the first
                                            request and reused for all
                                            subsequent prefills.
          * max_model_len=4096            — image tokens (~1500 at 672px)
                                            + prompt (~250) + output
                                            (~512) = ~2300. 4096 leaves
                                            headroom without wasting KV
                                            VRAM on the full 32k context
                                            window Qwen advertises.
          * gpu_memory_utilization=0.90   — leaves ~2 GB of A10G headroom
                                            for activations + CUDA graph
                                            workspace, everything else
                                            goes to the KV cache pool.
          * limit_mm_per_prompt={"image": 1}
                                          — our prompts always carry
                                            exactly one image; tells vLLM
                                            not to reserve space for
                                            multi-image batches.

        PagedAttention is vLLM's default attention impl and requires no
        flag — it's what makes the KV cache pool work block-by-block
        and lets concurrent requests share VRAM efficiently.
        """
        from transformers import AutoProcessor
        from vllm import AsyncEngineArgs, AsyncLLMEngine

        self.processor = AutoProcessor.from_pretrained(MODEL_NAME)  # type: ignore[no-untyped-call]

        engine_args = AsyncEngineArgs(
            model=MODEL_NAME,
            quantization="awq_marlin",
            enable_prefix_caching=True,
            max_model_len=4096,
            gpu_memory_utilization=0.90,
            limit_mm_per_prompt={"image": 1},
            trust_remote_code=True,
        )
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)

    @modal.method()
    async def classify(self, image_b64: str) -> dict[str, Any]:
        return await self._infer(image_b64, _CLASSIFY_PROMPT)

    @modal.method()
    async def extract(self, images_b64: list[str]) -> dict[str, Any]:
        if not images_b64:
            return {"books": []}
        return await self._infer(images_b64[0], _EXTRACT_PROMPT)

    @modal.method()
    async def analyze(self, image_b64: str) -> dict[str, Any]:
        return await self._infer(image_b64, _ANALYZE_PROMPT)

    async def _infer(self, image_b64: str, prompt: str) -> dict[str, Any]:
        import base64
        import io
        import uuid

        from PIL import Image as PILImage
        from vllm import SamplingParams

        raw = base64.b64decode(image_b64, validate=True)
        pil_image = PILImage.open(io.BytesIO(raw)).convert("RGB")

        # Qwen2.5-VL chat template inserts <|vision_start|><|image_pad|>
        # <|vision_end|> placeholders in the right spots; vLLM fills the
        # image_pad positions with the actual visual embeddings derived
        # from `multi_modal_data`.
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image"},
                    {"type": "text", "text": prompt},
                ],
            }
        ]
        text_prompt = self.processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )

        sampling_params = SamplingParams(
            max_tokens=512,
            temperature=0.0,
        )

        request_id = str(uuid.uuid4())
        final_output = None

        # Stream the response. As soon as we detect a `not_book`
        # classification (the model emits `classification` as the
        # first JSON field), abort the remaining generation — the
        # rejection branch in Moderation doesn't use `reasoning` for
        # not_book (it surfaces a fixed "not a book" message to the
        # user), and `books` is always `[]` for not_book anyway, so
        # truncating after we've seen `confidence` is safe.
        #
        # For `book` / `ambiguous` classifications we keep streaming
        # to EOS — the full structured response is needed downstream
        # for reasoning, book extraction, etc.
        async for output in self.engine.generate(
            {
                "prompt": text_prompt,
                "multi_modal_data": {"image": pil_image},
            },
            sampling_params=sampling_params,
            request_id=request_id,
        ):
            final_output = output
            if output.outputs and _can_early_terminate(output.outputs[0].text):
                await self.engine.abort(request_id)
                break

        if final_output is None or not final_output.outputs:
            return {}

        response = final_output.outputs[0].text.strip()
        return _parse_json_with_not_book_fallback(response)


def _parse_json(text: str) -> dict[str, Any]:
    """Extract a JSON object from model output, handling code fence wrapping."""
    try:
        return json.loads(text)  # type: ignore[no-any-return]
    except json.JSONDecodeError:
        pass

    stripped = re.sub(r"^```(?:json)?\s*|\s*```$", "", text, flags=re.DOTALL).strip()
    try:
        return json.loads(stripped)  # type: ignore[no-any-return]
    except json.JSONDecodeError:
        pass

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())  # type: ignore[no-any-return]
        except json.JSONDecodeError:
            pass

    return {}


# Matches the model's `not_book` classification in a streaming JSON
# prefix. We wait until `confidence` has started so the partial output
# carries a usable confidence score for downstream logging; without
# this check we might abort on `{"classification": "not_book"` before
# the confidence token is emitted.
_EARLY_TERMINATE_PATTERN = re.compile(
    r'"classification"\s*:\s*"not_book"\s*,\s*"confidence"\s*:\s*[0-9.]+',
    re.IGNORECASE,
)


def _can_early_terminate(partial_text: str) -> bool:
    """True if the streaming output has emitted enough JSON to know the
    classification is `not_book` AND carry a confidence score. Once we
    know that, the rest of the generation is redundant — `books` is `[]`
    for not_book by prompt contract, and `reasoning` on a rejection
    isn't surfaced in the user-facing UX.
    """
    return bool(_EARLY_TERMINATE_PATTERN.search(partial_text))


def _parse_json_with_not_book_fallback(text: str) -> dict[str, Any]:
    """Parse the model output. If the JSON is complete, delegate to
    `_parse_json`. If it was truncated by `_can_early_terminate` (we
    aborted mid-generation), reconstruct a minimal valid payload:

        {"classification": "not_book", "confidence": <parsed>, "books": []}

    This keeps the caller's contract stable — it always sees a
    well-formed `{"classification": ..., "books": [...]}` shape
    regardless of whether we bailed early.
    """
    parsed = _parse_json(text)
    if parsed.get("classification") == "not_book":
        # Full parse worked even if we truncated, or the model completed
        # normally on a not_book input. Ensure `books` is present.
        parsed.setdefault("books", [])
        return parsed

    # Parse failed — likely because we aborted mid-JSON. Try to recover
    # the classification+confidence from the partial buffer.
    match = _EARLY_TERMINATE_PATTERN.search(text)
    if match:
        # Extract the confidence value out of the matched fragment.
        conf_match = re.search(r"([0-9.]+)\s*$", match.group(0))
        confidence = float(conf_match.group(1)) if conf_match else 0.0
        return {
            "classification": "not_book",
            "confidence": confidence,
            "books": [],
        }

    # Otherwise fall back to whatever `_parse_json` managed (possibly {}).
    return parsed


# ── FastAPI vision service (ASGI) ─────────────────────────────────────────────
# Hosts the FastAPI app on Modal's serverless infrastructure.
# Elixir core calls this endpoint via HMAC-authenticated HTTPS. In local dev
# the service runs at localhost:8000 via uvicorn.
#
# The Modal secret "thestacks-vision" must contain VISION_HMAC_SECRET.
# Create or update with:
#   modal secret create thestacks-vision VISION_HMAC_SECRET=<secret> [--force]

_VISION_DIR = Path(__file__).parent

_fastapi_image = (
    modal.Image.debian_slim(python_version="3.12")
    # libzbar0 is required by pyzbar for barcode decoding (local OCR pre-pass).
    .apt_install("libzbar0")
    .pip_install(
        "fastapi==0.135.1",
        "starlette==0.52.1",
        "uvicorn[standard]==0.41.0",
        "httpx==0.28.1",
        "pydantic==2.10.4",
        "pydantic-settings==2.7.1",
        "structlog==24.4.0",
        "modal>=0.73.0",
        # Pillow + pyzbar enable the local OCR barcode pre-pass in app/services/local_ocr.py.
        # Without these, barcode images fall through to the GPU model, which cannot
        # reliably decode machine-readable barcodes and causes E2E test timeouts.
        "Pillow>=10.0.0",
        "pyzbar>=0.1.9",
    )
    .add_local_dir(str(_VISION_DIR / "app"), remote_path="/app/app")
)


@app.function(
    image=_fastapi_image,
    # Pin the ASGI entry point to us-east too. Otherwise the
    # FastAPI→VisionModel call becomes a cross-region RPC inside Modal,
    # adding ~60ms to every /analyze even when the GPU is warm.
    region="us-east",
    secrets=[
        modal.Secret.from_name("thestacks-vision"),
        # Bake the app name into the ASGI container so VisionClient can look up
        # the correct GPU class. For ephemeral preview deploys the app name differs
        # from the default "thestacks-vision", so we cannot hardcode it in the app.
        modal.Secret.from_dict({"MODAL_APP_NAME": MODAL_APP_NAME}),
    ],
    # Keep the ASGI container alive long enough for all E2E tests to complete.
    # ASGI apps handle concurrency natively — no @modal.concurrent needed.
    scaledown_window=1200,
)
@modal.asgi_app()
def vision_api() -> Any:
    import sys

    sys.path.insert(0, "/app")
    from app.main import app as fastapi_app

    return fastapi_app
