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
MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct"


def _download_model() -> None:
    """Pre-download model weights into the container image during build.

    Runs once at `modal deploy` time (or when the image is invalidated).
    The downloaded weights are cached in the image layer — every subsequent
    container start loads from local disk rather than re-downloading.
    """
    from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

    AutoProcessor.from_pretrained(MODEL_NAME)  # type: ignore[no-untyped-call]
    Qwen2_5_VLForConditionalGeneration.from_pretrained(MODEL_NAME, torch_dtype="bfloat16")


image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("libzbar0")
    .pip_install(
        "transformers>=4.50.0",
        "qwen-vl-utils>=0.0.10",
        "torch>=2.4.0",
        "torchvision",
        "accelerate>=0.34.0",
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
    gpu="A10G",
    image=image,
    # Pin to us-east so the Modal GPU lives in the same region as Fly IAD
    # (core) and Neon us-east-1 (DB). Without pinning, Modal's scheduler
    # places containers wherever A10G capacity exists — a us-west placement
    # adds ~60ms Fly→Modal RTT per /analyze call, compounding with cold
    # starts. Tradeoff: if us-east runs out of A10G, scheduling blocks
    # rather than falling back. In practice us-east has ample A10G.
    region="us-east",
    # 300s allows for cold-start (~30s) + queue wait (up to 120s when concurrent
    # jobs are serialised on a single A10G) + inference (~60s for long inputs).
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
    def load(self) -> None:
        import torch
        from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

        self.processor = AutoProcessor.from_pretrained(MODEL_NAME)  # type: ignore[no-untyped-call]
        self.model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
            MODEL_NAME,
            torch_dtype=torch.bfloat16,
            device_map="auto",
        )

    @modal.method()
    def classify(self, image_b64: str) -> dict[str, Any]:
        return self._infer(image_b64, _CLASSIFY_PROMPT)

    @modal.method()
    def extract(self, images_b64: list[str]) -> dict[str, Any]:
        if not images_b64:
            return {"books": []}
        return self._infer(images_b64[0], _EXTRACT_PROMPT)

    @modal.method()
    def analyze(self, image_b64: str) -> dict[str, Any]:
        return self._infer(image_b64, _ANALYZE_PROMPT)

    def _infer(self, image_b64: str, prompt: str) -> dict[str, Any]:
        import torch
        from qwen_vl_utils import process_vision_info

        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "image": f"data:image/jpeg;base64,{image_b64}"},
                    {"type": "text", "text": prompt},
                ],
            }
        ]

        text = self.processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        image_inputs, video_inputs = process_vision_info(messages)
        inputs = self.processor(
            text=[text],
            images=image_inputs,
            videos=video_inputs,
            padding=True,
            return_tensors="pt",
        ).to(self.model.device)

        with torch.no_grad():
            generated_ids = self.model.generate(
                **inputs,
                max_new_tokens=512,
                do_sample=False,
                temperature=None,
                top_p=None,
            )

        output_ids = [
            out[len(inp) :] for out, inp in zip(generated_ids, inputs.input_ids, strict=False)
        ]
        response = self.processor.batch_decode(output_ids, skip_special_tokens=True)[0].strip()
        return _parse_json(response)


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
