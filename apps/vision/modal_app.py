"""Modal app: Qwen2.5-VL-7B-Instruct vision inference for The Stacks.

Stack: HF Transformers + accelerate (no vLLM), bf16 on an A10G — the
empirically-clean dfef1333 baseline; no vLLM/H100 without an eval
framework. One inference per container (sync @modal.method calls,
serialised); scale by container count, not in-process concurrency.
300s function timeout — core's client timeout is DERIVED from this
number and must never be below it (350).
"""

import json
import os
import re
from pathlib import Path
from typing import Any

import modal

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
    "    with no readable title, author name, or ISBN — this is NOT a book.\n"
    "  - A still from a TV show, film, news segment, advertisement, video game, or other "
    "video/screen content where a book is NOT the dominant subject (even if a book happens "
    "to be visible in the frame, e.g. on a desk, shelf, or held by a presenter, but the "
    "primary subject of the image is the show / channel / brand / scene around it).\n\n"
    'Answer "ambiguous" only when the image might show book content but you genuinely\n'
    "cannot tell — e.g. a blurred or cropped image where something rectangular is\n"
    "partially visible but no text is legible; OR a screenshot where a book is present "
    "and partially legible but you cannot determine whether it is the primary subject "
    "vs. an incidental prop in a larger scene.\n\n"
    "Respond with ONLY valid JSON — no explanation, no code fences:\n"
    '{"classification": "book", "confidence": 0.95,'
    ' "reasoning": "one sentence explaining your decision"}'
)

_EXTRACT_PROMPT = (
    "You are a book identification assistant with expertise in OCR and cover recognition.\n\n"
    "Extract all books visible or mentioned in this image. For EACH book:\n"
    "- Read all visible text, including text that is mirrored, rotated, partially cropped, "
    "or at an angle. If text appears reversed, mentally un-flip it before transcribing.\n"
    "- Use ALL available signals together: visible text (title, author, subtitle, publisher), "
    "cover artwork (illustration style, colour palette, period, subject matter, typography), "
    "and any partial words or fragments — do NOT discard partial text.\n"
    "- When the title appears cropped at the top or bottom of the cover, include any "
    "visible prefix or suffix words even if only partially legible. Prefer the longest "
    'plausible full title (e.g. "Train to Crystal City" not "Crystal City"; '
    '"The Book Thief" not "Book Thief") over the shortest fragment.\n'
    "- If the image is a screenshot of text (social media, article, reading list), extract "
    "all book titles and authors mentioned in the text content.\n"
    "- ONLY identify ACTUAL BOOKS. If the image is a still from a TV show, film, news "
    "segment, advertisement, video game, or any video/screen content — even if a book "
    "happens to be visible in the frame — return books:[] unless the book is the "
    "dominant subject AND its title is clearly legible. Do NOT identify a TV show or "
    "media-brand as a book, even when the OL/GB catalogue may contain a tie-in book with "
    "the same name. Authors should be people, not production companies "
    '(e.g. "Discovery Communications", "Warner Bros.", "Productions, Inc.") '
    "— if the only plausible author is an organisation/brand, return books:[].\n\n"
    "Reasoning approach:\n"
    "1. Transcribe all readable text verbatim (including fragments), noting any orientation "
    "issues.\n"
    "2. Apply any necessary corrections (mirror, rotation) to produce clean text.\n"
    "3. Cross-reference corrected text + cover art to identify the specific edition.\n"
    "4. If uncertain between multiple books, pick the most likely and reflect that in "
    "confidence.\n\n"
    "Respond with ONLY valid JSON — no explanation, no markdown, no code fences:\n"
    '{"books": [{'
    '  "title": "Full title as it appears on the cover",'
    '  "author": "Author full name or null if not visible",'
    '  "confidence": 0.95,'
    '  "raw_text": "Verbatim text fragments as seen, before any correction",'
    '  "corrected_text": "Text after un-mirroring/rotating/inferring partial words",'
    '  "identification_signals": ["cover text", "subtitle", "cover art", "partial OCR"],'
    '  "potential_isbns": []'
    "}]}\n"
    'If no books can be identified: {"books": []}'
)


def _build_extract_prompt(excluded_books: list[str] | None) -> str:
    """Return the extract prompt, augmented with a rejection-retry constraint
    when ``excluded_books`` is non-empty.

    The frontend's "No, try again" flow re-uploads (logically) the same image
    with the cumulative list of previously-identified books the user has
    rejected. We append an explicit constraint instructing the model to NOT
    return any of those titles, so it picks a different plausible candidate
    or returns books:[] if none exists. When the list is empty, the baseline
    prompt is returned unchanged.
    """
    if not excluded_books:
        return _EXTRACT_PROMPT
    bullets = "\n".join(f"  - {entry}" for entry in excluded_books)
    constraint = (
        "\n\nCONSTRAINT: This image has previously been identified as the "
        "following book(s), and the user has rejected those identifications "
        "as incorrect. Do NOT return any of these as a match. Pick a "
        "different book that fits the image, or return books:[] if no "
        "other plausible match exists.\n"
        "Rejected (do NOT return):\n"
        f"{bullets}\n"
    )
    return _EXTRACT_PROMPT + constraint


@app.cls(
    gpu="A10G",
    image=image,
    max_containers=10,
    timeout=300,
    scaledown_window=1200,
)
class VisionModel:
    @modal.enter()
    def load(self) -> None:
        """Load the Qwen2.5-VL processor + model via HF Transformers.

        ``Qwen2_5_VLForConditionalGeneration.from_pretrained`` loads the
        bfloat16 weights from the local HuggingFace cache (baked into the
        image at build time by ``_download_model``) onto the A10G via
        ``device_map="auto"``. ``AutoProcessor`` loads the matching
        image+text preprocessor. Sync — no async engine, no event-loop
        bootstrap. Inference goes through ``model.generate`` (see
        ``_infer``); concurrency is bounded by ``max_containers`` rather
        than continuous batching.
        """
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
    def extract(
        self,
        images_b64: list[str],
        excluded_books: list[str] | None = None,
    ) -> dict[str, Any]:
        if not images_b64:
            return {"books": []}
        prompt = _build_extract_prompt(excluded_books)
        return self._infer(images_b64[0], prompt)

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


_VISION_DIR = Path(__file__).parent

_fastapi_image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("libzbar0")
    .pip_install(
        "fastapi==0.139.0",
        "starlette==1.3.1",
        "uvicorn[standard]==0.41.0",
        "httpx==0.28.1",
        "pydantic==2.10.4",
        "pydantic-settings==2.7.1",
        "structlog==24.4.0",
        "modal>=0.73.0",
        "Pillow>=10.0.0",
        "pyzbar>=0.1.9",
    )
    .add_local_dir(str(_VISION_DIR / "app"), remote_path="/app/app")
)


@app.function(
    image=_fastapi_image,
    secrets=[
        modal.Secret.from_name("thestacks-vision"),
        modal.Secret.from_dict({"MODAL_APP_NAME": MODAL_APP_NAME}),
    ],
    scaledown_window=1200,
)
@modal.asgi_app()
def vision_api() -> Any:
    import sys

    sys.path.insert(0, "/app")
    from app.main import app as fastapi_app

    return fastapi_app
