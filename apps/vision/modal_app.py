"""
Modal app: Qwen2.5-VL-7B-Instruct vision inference for The Stacks.

This file defines two Modal functions:

  1. VisionModel  — GPU class (A10G) for running Qwen2.5-VL inference.
  2. vision_api   — CPU function hosting the FastAPI app via @modal.asgi_app().
                    HTTPS endpoint: https://erinversfeldcodes--thestacks-vision-vision-api.modal.run

Deploy with:
    modal deploy apps/vision/modal_app.py

The model is baked into the container image at build time, so cold starts
only pay the cost of loading weights into GPU memory (~30s on A10G) rather
than downloading ~15GB from HuggingFace on every container start.
"""

import json
import re
from pathlib import Path

import modal

MODAL_APP_NAME = "thestacks-vision"
MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct"


def _download_model() -> None:
    """Pre-download model weights into the container image during build.

    Runs once at `modal deploy` time (or when the image is invalidated).
    The downloaded weights are cached in the image layer — every subsequent
    container start loads from local disk rather than re-downloading.
    """
    from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

    AutoProcessor.from_pretrained(MODEL_NAME)
    Qwen2_5_VLForConditionalGeneration.from_pretrained(MODEL_NAME, torch_dtype="bfloat16")


image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "transformers>=4.50.0",
        "qwen-vl-utils>=0.0.10",
        "torch>=2.4.0",
        "torchvision",
        "accelerate>=0.34.0",
        "Pillow>=10.0.0",
    )
    .run_function(_download_model)
)

app = modal.App(MODAL_APP_NAME)

_CLASSIFY_PROMPT = (
    "Does this image contain enough information to identify a book?\n\n"
    'Answer "book" if: the image shows a physical book (cover, spine, back, or barcode), '
    "OR the image is a screenshot or photo of text that mentions a specific book title or author.\n\n"
    'Answer "not_book" if: the image has no book-related content whatsoever '
    "(a pet, food, a landscape, a selfie with no book context).\n\n"
    'Answer "ambiguous" if: there is some possible book-related content but not enough '
    "to attempt identification.\n\n"
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    '{"classification": "book", "confidence": 0.95}'
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


@app.cls(
    gpu="A10G",
    image=image,
    # 300s allows for cold-start (~30s) + queue wait (up to 120s when concurrent
    # jobs are serialised on a single A10G) + inference (~60s for long inputs).
    timeout=300,
    # Keep the container alive for 5 minutes after the last request.
    # This amortises cold-start cost across batches of images (e.g. processing
    # a backlog) while letting the container shut down during idle periods.
    scaledown_window=300,
)
class VisionModel:
    @modal.enter()
    def load(self) -> None:
        import torch
        from transformers import AutoProcessor, Qwen2_5_VLForConditionalGeneration

        self.processor = AutoProcessor.from_pretrained(MODEL_NAME)
        self.model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
            MODEL_NAME,
            torch_dtype=torch.bfloat16,
            device_map="auto",
        )

    @modal.method()
    def classify(self, image_b64: str) -> dict:
        return self._infer(image_b64, _CLASSIFY_PROMPT)

    @modal.method()
    def extract(self, images_b64: list[str]) -> dict:
        if not images_b64:
            return {"books": []}
        return self._infer(images_b64[0], _EXTRACT_PROMPT)

    def _infer(self, image_b64: str, prompt: str) -> dict:
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

        output_ids = [out[len(inp) :] for out, inp in zip(generated_ids, inputs.input_ids)]
        response = self.processor.batch_decode(output_ids, skip_special_tokens=True)[0].strip()
        return _parse_json(response)


def _parse_json(text: str) -> dict:
    """Extract a JSON object from model output, handling code fence wrapping."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    stripped = re.sub(r"^```(?:json)?\s*|\s*```$", "", text, flags=re.DOTALL).strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
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
    .pip_install(
        "fastapi==0.135.1",
        "starlette==0.52.1",
        "uvicorn[standard]==0.41.0",
        "httpx==0.28.1",
        "pydantic==2.10.4",
        "pydantic-settings==2.7.1",
        "structlog==24.4.0",
        "modal>=0.73.0",
    )
    .add_local_dir(str(_VISION_DIR / "app"), remote_path="/app/app")
)


@app.function(
    image=_fastapi_image,
    secrets=[modal.Secret.from_name("thestacks-vision")],
    # Keep the ASGI container alive long enough for all E2E tests to complete.
    # ASGI apps handle concurrency natively — no @modal.concurrent needed.
    scaledown_window=300,
)
@modal.asgi_app()
def vision_api():
    import sys

    sys.path.insert(0, "/app")
    from app.main import app as fastapi_app  # noqa: PLC0415

    return fastapi_app
