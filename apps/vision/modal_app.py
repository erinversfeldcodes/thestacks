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

# AWQ-quantized 4-bit Qwen2.5-VL-72B. Weights ~38 GB vs ~145 GB for the
# bfloat16 original. Selected over the 7B variant for substantially better
# handling of geometrically degraded inputs — mirrored, rotated, and
# partially-cropped book covers. The 7B variant could not reliably read
# mirrored text even with explicit re-orientation prompting; the 72B has
# meaningfully better rotation/mirror invariance from training scale alone.
#
# Fits on a single H100 (80 GB): ~38 GB weights + ~5 GB activations/CUDA
# workspace + ~35 GB KV cache pool at gpu_memory_utilization=0.90. KV cache
# headroom is materially smaller than at 7B, so `@modal.concurrent` below
# is reduced from 8 → 2.
#
# Override via MODEL_NAME env var if a faster community quant emerges or
# if we need to roll back to 7B for cost.
MODEL_NAME = os.environ.get("MODEL_NAME", "Qwen/Qwen2.5-VL-72B-Instruct-AWQ")


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
#   - STEP 1 (orient) is the load-bearing line for reversed / rotated /
#     mirrored covers — Qwen2.5-VL will read upside-down text when asked
#     and often won't when not.
#   - Extraction is permitted on "ambiguous" so partial signal (a half-
#     visible ISBN, one legible word of a title) survives the pipeline.
#     The caller filters books only for confident "not_book".
#   - Per-book `confidence` lets enrichment deprioritise weak guesses
#     before hitting Google Books / Open Library (Issue #167).
#   - `reasoning` is retained as a soft chain-of-thought scratchpad. On
#     hard cases (rotated, partially-cropped covers) the model performs
#     better when it can emit a short justification before committing to
#     the structured answer. Logged on the /classify callback path; not
#     yet wired into /analyze logging but cheap to add.
#   - The JSON field order — classification, confidence, reasoning, books —
#     is fixed so `_can_early_terminate` can abort streaming once it sees
#     `"classification": "not_book"` followed by a confidence value.
#   - Single JSON object, no nested code fences. `_parse_json` already
#     handles the "model wrapped the response in ```json" case.
_ANALYZE_PROMPT = (
    "You are inspecting an image to identify any books it contains. Work through "
    "these steps:\n\n"
    "STEP 1 — Orient the image.\n"
    "If text or imagery appears upside-down, mirrored, sideways, or rotated, "
    "mentally re-orient before reading. Cropped or partially-visible covers still "
    "count; read whatever portion is legible.\n\n"
    "STEP 2 — Classify the image. Set `classification` to one of:\n"
    '  - "book"      — A physical book (cover, spine, or barcode visible) OR a\n'
    "                  screenshot/photo of text that names a specific book title or\n"
    "                  author. Marginal or partial covers with ANY legible title,\n"
    '                  author, or ISBN are still "book".\n'
    '  - "not_book"  — No book present and no book named in legible text. Examples:\n'
    "                  animals, food, landscapes, logos, abstract art, a rectangle\n"
    "                  resembling a cover with nothing readable on it.\n"
    '  - "ambiguous" — You cannot tell because the image is unreadable (heavy blur,\n'
    "                  total occlusion, lighting too poor to make out anything\n"
    "                  book-like).\n\n"
    "STEP 3 — Extract books. Populate `books` with every book you can partially or\n"
    'fully identify. INCLUDE entries even when classification is "ambiguous" if ANY\n'
    "signal is recoverable (a partial ISBN, one legible word of a title, etc.).\n"
    'Only return `books: []` for a confident "not_book".\n\n'
    "For each book provide:\n"
    '  - `title`           — best reading of the title, or "" if unreadable.\n'
    '  - `author`          — best reading of the author, or "" if unreadable.\n'
    "  - `confidence`      — your confidence in this specific book identification,\n"
    "                        0.0-1.0. Use 0.9+ only when title AND author are\n"
    "                        clearly legible.\n"
    "  - `potential_isbns` — every 10- or 13-digit numeric string visible on the\n"
    "                        cover, spine, or barcode that could plausibly be an\n"
    "                        ISBN. Include both ISBN-10 and ISBN-13 if both are\n"
    "                        printed. Do NOT filter by checksum — the caller\n"
    "                        validates. Strip hyphens and spaces.\n"
    "  - `raw_text`        — verbatim transcription of the most identifying text\n"
    "                        you read (title block, author line, or screenshot\n"
    "                        quote). One short string, not a full page dump.\n\n"
    "If the cover artwork is more legible than the text (e.g. recognisable\n"
    "illustration style, period setting), use it as a corroborating signal — but\n"
    "only commit to a title/author combination you can actually read or strongly\n"
    "recognise. Do not invent.\n\n"
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    "{\n"
    '  "classification": "book" | "not_book" | "ambiguous",\n'
    '  "confidence": 0.95,\n'
    '  "reasoning": "one sentence explaining the classification",\n'
    '  "books": [\n'
    '    {"title": "...", "author": "...", "confidence": 0.9,'
    ' "potential_isbns": ["..."], "raw_text": "..."}\n'
    "  ]\n"
    "}"
)


@app.cls(
    gpu="H100",
    image=image,
    # Region pinning was removed 2026-04-23 after gate observations showed
    # `upload_p95_ms` regressing to 3556 ms (vs 2074 ms during local warm
    # testing) with 0% vision failure rate and fuse closed — i.e., not a
    # correctness issue, just Modal taking longer to schedule. The
    # leading-order suspect was us-east H100 capacity pressure, where the
    # scheduler blocks rather than falling back when the regional pool is
    # exhausted.
    #
    # Trade-off accepted: cross-region placement (e.g. us-west) adds ~60 ms
    # Fly→Modal RTT per /analyze call. At a 2000-3000 ms p95 budget, 60 ms
    # is rounding error; multi-second scheduling wait was not.
    #
    # Neon us-east-1 is unaffected — vision doesn't talk to Neon. Fly IAD
    # (core) is still the sole upstream, so cross-region placement only
    # affects the single Modal HTTPS round-trip per upload. If the p95
    # worsens after unpinning (evidence: a `[:stacks, :vision, :request,
    # :stop]` p95 > ~200 ms higher than the historical us-east median),
    # reconsider: pin back with a min_containers=1 keep-warm, or move to
    # L40S which has broader availability.
    # H100 (80 GB, Hopper w/ FP8 tensor cores) is required for the 72B AWQ
    # model — the weights alone are ~38 GB, so the 24 GB A10G is no longer
    # viable. awq_marlin targets Hopper's FP8 path, giving meaningfully
    # better throughput than the bf16 fallback would on the same hardware.
    # Expected per-call latency at 72B AWQ on warm H100: ~2-4 s for single
    # book covers, ~6-10 s for text-heavy screenshots. Cold-start adds
    # ~60-90 s (weights load from local image cache, not HF).
    #
    # Cap autoscaled containers at 10. With max_inputs=2 each, that's up
    # to 20 concurrent inferences — below the Oban :vision queue ceiling
    # of 60, so the queue absorbs bursts that the GPU pool cannot. At
    # peak ~$40-50/hr (10 * ~$4-5/hr H100); amortises well below that at
    # real utilisation because Modal charges per active container-second
    # and `scaledown_window=1200` lets idle containers release.
    # Re-evaluate `max_containers` if monthly bill runs hotter than
    # expected. The 72B is the same H100 hourly rate as 7B was — cost
    # delta vs the prior 7B setup comes from longer per-call execution
    # time and from the lower max_inputs forcing more containers under
    # the same offered load.
    max_containers=10,
    # 600s allows for cold-start (~60-90 s for 72B weights load) + queue
    # wait (up to ~180 s when concurrent jobs are serialised on a single
    # H100 at the new max_inputs=2 cap) + inference (~30 s p95 for long
    # inputs at 72B). Doubled from 300 s at the 7B → 72B swap.
    timeout=600,
    # Keep the container alive for 20 minutes after the last request.
    # Warmup runs at deploy time; E2E upload tests run ~15 minutes later (after
    # all chromium tests complete). 20 min window ensures the GPU is still warm
    # when upload tests start, avoiding a cold-start that would exceed the test timeout.
    scaledown_window=1200,
)
# Accept up to 2 in-flight calls per container. Qwen2.5-VL-72B AWQ takes
# ~38 GB of the 80 GB H100, leaving ~35 GB for the KV cache pool after
# activations/workspace. At 4096 max_model_len each concurrent request
# reserves ~12 GB of KV state at 72B (vs <1 GB at 7B); 2 in-flight is the
# safe ceiling. Bursts above that autoscale into additional containers via
# `max_containers=10` below — slower than warm-batching but bounded.
#
# Was 8 with the 7B model; dropped in lockstep with the 7B → 72B swap. If
# the upload probe shows iteration times growing because of in-container
# queueing rather than cold-start, drop max_model_len to 3072 to claw back
# enough KV headroom for max_inputs=3.
@modal.concurrent(max_inputs=2)
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
          * gpu_memory_utilization=0.90   — at 72B AWQ on H100 80 GB this
                                            leaves ~8 GB headroom for
                                            activations + CUDA graph
                                            workspace after ~38 GB of
                                            weights; everything else
                                            (~35 GB) goes to the KV cache
                                            pool. If load triggers OOM at
                                            startup, drop to 0.85 first
                                            before reducing max_model_len.
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
