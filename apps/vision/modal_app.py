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
# ⚖️ THE FOUR KNOBS AN EXPERIMENT VARIES, READ FROM THE ENVIRONMENT SO THAT A
# VARIANT IS A DEPLOY RATHER THAN A SOURCE EDIT. Every default below is the
# value that was deployed and measured before this block existed, so an
# unparameterised deploy is byte-identical in behaviour — which is the only way
# the baseline stays a baseline while variants are being tried against it.
#
# ⚠️ Modal evaluates the decorators at DEPLOY time, so these are fixed when the
# app is pushed, not per request. That is what makes a run attributable: one
# deployment, one configuration, one artefact.
MODEL_NAME = os.environ.get("VISION_MODEL_NAME", "Qwen/Qwen2.5-VL-7B-Instruct")
VISION_GPU = os.environ.get("VISION_GPU", "A10G")
VISION_DTYPE = os.environ.get("VISION_DTYPE", "bfloat16")

# `None` means "whatever the processor's own config says", which is what ran
# before this knob existed. An explicit value caps the image tokens the vision
# encoder emits, and so both the latency and the GPU seconds a photograph costs.
_max_px = os.environ.get("VISION_MAX_PIXELS")
VISION_MAX_PIXELS = int(_max_px) if _max_px else None

# ⛔ DECORATOR ARGUMENTS BIND AT DEPLOY TIME; FUNCTION BODIES DO NOT. Modal
# re-imports this module inside the build and runtime containers, where the
# VISION_* variables above re-resolve against a container environment that
# never had them — so `gpu=VISION_GPU` honoured the experiment while
# MODEL_NAME, VISION_DTYPE and VISION_MAX_PIXELS silently fell back to their
# defaults in the container. A max_pixels experiment deployed this way runs a
# byte-identical copy of the baseline and reports it as a variant. The
# overrides are therefore baked into the image env — but ONLY when set, so an
# unparameterised deploy keeps the exact image hash the baseline was measured
# on.
_ENV_OVERRIDES = {
    k: v
    for k, v in (
        ("VISION_MODEL_NAME", os.environ.get("VISION_MODEL_NAME")),
        ("VISION_DTYPE", os.environ.get("VISION_DTYPE")),
        ("VISION_MAX_PIXELS", os.environ.get("VISION_MAX_PIXELS")),
        # ⛔ VISION_GPU IS BAKED TOO, FOR THE LOAD LINE'S HONESTY. It drives the
        # `gpu=` decorator at deploy time (correct hardware either way), but the
        # runtime print reads it from the container env — unbaked, that printed
        # `gpu=A10G` for a container actually on a T4, which is precisely the
        # lying-instrument failure the print exists to prevent.
        ("VISION_GPU", os.environ.get("VISION_GPU")),
    )
    if v
}

# Extra packages a variant needs that the baseline must not carry: an AWQ
# checkpoint needs `autoawq`, Qwen3-VL needs a newer transformers than the
# baseline pin. Comma-separated pip specs; empty by default, and an empty list
# adds no layer, so the default image hash is again untouched.
_EXTRA_PIPS = [s.strip() for s in os.environ.get("VISION_EXTRA_PIPS", "").split(",") if s.strip()]


def _model_class_name(model_name: str) -> str:
    """Which transformers class loads this checkpoint.

    ⚖️ Returns the NAME, not the class, so the mapping is testable in an
    environment without transformers installed. Qwen3-VL shipped a new model
    class; an -AWQ checkpoint of 2.5-VL is still a 2.5-VL — its quantisation
    rides in the checkpoint's own config, not in the loader.
    """
    if "qwen3-vl" in model_name.lower():
        return "Qwen3VLForConditionalGeneration"
    return "Qwen2_5_VLForConditionalGeneration"


def _download_model() -> None:
    """Pre-download model weights into the container image during build.

    Runs once at `modal deploy` time (or when the image is invalidated).
    The downloaded weights are cached in the image layer — every subsequent
    container start loads from local disk rather than re-downloading.
    """
    import transformers

    cls = getattr(transformers, _model_class_name(MODEL_NAME))
    transformers.AutoProcessor.from_pretrained(MODEL_NAME)
    cls.from_pretrained(MODEL_NAME, torch_dtype="auto")


image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("libzbar0", "tesseract-ocr", "tesseract-ocr-eng")
    .pip_install(
        "transformers>=4.50.0",
        "qwen-vl-utils>=0.0.10",
        "torch>=2.4.0",
        "torchvision",
        "accelerate>=0.34.0",
        "Pillow>=10.0.0",
        "pyzbar>=0.1.9",
        "pytesseract>=0.3.13",
    )
)


def _image_plan() -> list[tuple[str, object]]:
    """The variant layers this deploy adds, as data.

    ⬛ AS DATA BECAUSE THE WIRING IS WHAT FAILED A PROBE. A first version
    tested that the overrides dict was *captured* and inlined the `image.env`
    call — deleting that call left every test green, which is a guard that
    cannot fire. The conditional and ordering logic now lives here where a
    test can red on it; the loop below that consumes it is deliberately too
    dumb to get wrong.

    Layer order is load-bearing: the env must exist BEFORE the weight bake,
    or _download_model resolves MODEL_NAME to the default inside the build
    container and bakes the wrong weights into a variant's image. And with
    no overrides and no extra pips the plan holds only the bake, so the
    default image hashes identically to the one the baseline was measured on.
    """
    steps: list[tuple[str, object]] = []
    if _EXTRA_PIPS:
        steps.append(("pip_install", tuple(_EXTRA_PIPS)))
    if _ENV_OVERRIDES:
        steps.append(("env", dict(_ENV_OVERRIDES)))
    steps.append(("run_function", "_download_model"))
    return steps


for _step, _arg in _image_plan():
    if _step == "pip_install" and isinstance(_arg, tuple):
        image = image.pip_install(*_arg)
    elif _step == "env" and isinstance(_arg, dict):
        image = image.env(_arg)
    else:
        image = image.run_function(_download_model)

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
    # ⚠️ THE ISBN IS DELIBERATELY NOT ASKED FOR HERE, AND THAT WAS MEASURED.
    #
    # Measurement showed the VLM returning `is_book=true, isbns=[]` on 6 of 6
    # hostile-barcode photographs — it had never been asked. Adding an
    # instruction to read the printed digits, plus a hard prohibition on
    # inferring them, was tried on 2026-11-13 and reverted the same day:
    #
    #   * `clear_cover` collapsed from 20/22 to 2/22. The model stopped
    #     returning titles AT ALL — `[]` where it had read "A Cageful of
    #     Butterflies" and "DREAMING THE KAROO" correctly. The caution
    #     generalised from the ISBN field to the whole response.
    #   * `hostile_barcode` moved only 3/20 to 4/20, and the template's own
    #     example ISBN was copied verbatim onto 10 of 16 unrelated books.
    #
    # ⛔ A PROMPT IS GLOBAL STATE. The change was measured on the stratum it
    # was meant to help, which showed a small gain and was structurally blind
    # to a 91%-to-9% regression elsewhere. Any future attempt must be scored
    # on the WHOLE corpus before it is believed.
    #
    # ⚖️ The two seam guards that change bought are kept, because they are
    # right whatever produces an ISBN: `Moderation` validates the check digit
    # before trusting a model-read ISBN, and cross-checks it against the title
    # the cover reads — a well-formed ISBN for the wrong book defeats both the
    # checksum and the hard gate, and only disagreement catches it.
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


def container_dispatch(inferences_since_load: int, container_id: str) -> dict[str, object]:
    """The `_container` reading a dispatch is built from — extracted so it is testable.

    ⛔ THIS LIVED INSIDE THE @app.cls-DECORATED METHOD AND THEREFORE HAD NO TEST
    THAT COULD FAIL. `VisionModel` is wrapped by Modal into a `Cls` object, not
    a plain type, so a test cannot instantiate it; every sidecar test mocks
    `classify`/`extract` wholesale and receives `_container` ready-made. A probe
    that hard-coded `cold = False` left the suite at 119 passed — the reading
    the entire idle-GPU cost is derived from was unguarded.

    ⚖️ A module-level function rather than a method, because the rule is
    arithmetic about container lifetime and needs none of the model: cold means
    this container has not yet ANSWERED, so the caller increments only after a
    successful inference. Read-then-increment at the top of `_infer` let a
    raised first inference consume the cold start, under-counting billed
    lifetimes in the direction that flatters the GPU.
    """
    return {"cold": inferences_since_load == 0, "container_id": container_id}


@app.cls(
    gpu=VISION_GPU,
    image=image,
    max_containers=10,
    timeout=300,
    # ⛔ 60s, CUT FROM 300s AGAINST A MEASURED COST DECOMPOSITION. This is how
    # long an idle A10G keeps billing after its last request, and measurement
    # put it at **98.1% of what a lone identification costs**: 9.18c of idle
    # against 0.198c of inference. Halving the model's speed would save 1% of
    # that bill; this literal saves 73%.
    #
    # ⚖️ WHAT THE WINDOW IS ACTUALLY PROTECTING, now that it has been measured.
    # Not a batch: the `vision` Oban queue runs at concurrency 20 against
    # `max_containers=10` below, deliberately, so uploads in one session arrive
    # back-to-back and the gap between them is effectively zero. The window
    # only ever rescues a reader who uploads, leaves, and RETURNS — and a
    # simulated month at 12 uploads/day puts the cold-start rate at 95% with a
    # 300s window and 99% with 60s. Four points of rescue, for four times the
    # idle bill.
    #
    # ⚠️ The latency cost is therefore near zero where the product actually
    # sits today, and real only above ~10 uploads/hour, where p50 drops from
    # 30s to 9.7s because containers stay warm between readers. At that traffic
    # the A10G is already several times over the $50/month budget on ANY
    # window, so the window is not the knob that gets there — a cheaper GPU is,
    # and the two compound.
    #
    # ⬛ Why 60 and not 30: 30s saves a further ~35% but stops spanning a human
    # cadence. If the queue is drained and a reader is framing books by hand at
    # ~45s apart, a 30s window leaves 37% of them cold against 22% at 60s. The
    # queue makes that the uncommon path, not the impossible one.
    #
    # The arithmetic is `scripts/characterise/scaledown-frontier.py`, validated
    # against both measured extremes — 0.378c simulated vs 0.429c measured
    # back-to-back, and 9.97c vs 9.34c for a lone cold identification.
    scaledown_window=60,
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
        import uuid

        # ⛔ THE GPU'S OWN COLD START, WHICH IS THE ONE THAT COSTS MONEY.
        #
        # `@modal.enter` runs once per GPU container, so the first inference
        # after it is the cold one. The sidecar cannot know this: its FastAPI
        # `lifespan` tracks a different container whose warmth is, by this
        # file's own reckoning, independent of the GPU's — and an idle A10G is
        # roughly two orders of magnitude more expensive per second than an
        # idle CPU container.
        #
        # ⛔ NO TIMESTAMP ANY MORE. This recorded `_loaded_at` so `_infer`
        # could report a container AGE, and a reviewer showed that age's only
        # possible consumer would have double-counted a term the inference cost
        # line already bills — so the field had no reader and is gone, here and
        # on the wire. What remains is the one fact that is load-bearing: this
        # container has not inferred yet, so the next inference pays the load.
        self._inferences_since_load = 0

        # ⛔ AN IDENTITY FOR THE BILLED WINDOW, which the age alone cannot give.
        #
        # `gpu_container_age_s` is sampled only when an inference runs, so a
        # container that wakes, serves one request and then idles out the rest
        # of its scaledown window reports `age ~ 0` and nothing afterwards —
        # and the idle seconds are precisely the ones with no request attached.
        # Summing observed ages therefore UNDER-counts, in the direction that
        # makes the GPU look cheap, which is the direction that would wrongly
        # settle the architecture question.
        #
        # ⚖️ With an id, a reader can take the MAXIMUM age seen per container
        # and add the scaledown window — the tail Modal bills after the last
        # request. That is derivable from what already crosses the wire, needs
        # no `modal.Dict` and no second channel out of the GPU, and does not
        # depend on `@modal.exit` firing (a container killed by the platform
        # may never run it).
        self._container_id = uuid.uuid4().hex

        import torch
        import transformers

        # ⚖️ `max_pixels` caps what the vision encoder emits per image, and so
        # both the latency and the GPU seconds a photograph costs. Left unset it
        # is the processor's own default, which is what ran before this was a
        # knob — passing `None` would OVERRIDE that default with nothing, so the
        # argument is omitted entirely rather than passed as None.
        proc_kwargs = {}
        if VISION_MAX_PIXELS:
            proc_kwargs["max_pixels"] = VISION_MAX_PIXELS

        self.processor = transformers.AutoProcessor.from_pretrained(MODEL_NAME, **proc_kwargs)

        # ⛔ T4 IS TURING AND HAS NO BF16. Loading bf16 weights there either
        # fails outright or silently upcasts, and a silent upcast would double
        # the memory of a model that already barely fits 16GB — so the dtype is
        # part of the experiment, not an invariant. int8 is a different shape
        # again: it is a quantisation config rather than a dtype, which is why
        # it branches here rather than being another `torch.<name>` lookup.
        load_kwargs: dict[str, Any] = {"device_map": "auto"}

        if VISION_DTYPE == "int8":
            from transformers import BitsAndBytesConfig

            load_kwargs["quantization_config"] = BitsAndBytesConfig(load_in_8bit=True)
        else:
            load_kwargs["torch_dtype"] = getattr(torch, VISION_DTYPE)

        model_cls = getattr(transformers, _model_class_name(MODEL_NAME))
        self.model = model_cls.from_pretrained(MODEL_NAME, **load_kwargs)

        # ⬛ REPORTED, NOT ASSUMED — AND PRINTED, NOT LOGGED. The first version
        # of this line used `logger.info` with no handler configured in the
        # container, so it never emitted anywhere: the one observability line
        # the series depended on was dead on arrival, and the CPU offload was
        # only discovered because transformers prints its own warning
        # directly. A measurement line must not depend on logging
        # configuration to exist.
        #
        # ⛔ `devices` is the most load-bearing field. On a 16GB card,
        # `device_map="auto"` does not fail when the model is too big — it
        # silently offloads layers to CPU and shuttles weights every forward
        # pass, which "works" at a latency that breaks every caller timeout.
        # A result whose devices include `cpu` measures the offload, not the
        # GPU.
        if hasattr(self.model, "hf_device_map"):
            devices = sorted({str(d) for d in self.model.hf_device_map.values()})
        else:
            devices = ["unknown"]
        print(
            f"vision model loaded: name={MODEL_NAME} gpu={VISION_GPU} "
            f"requested_dtype={VISION_DTYPE} "
            f"actual_dtype={getattr(self.model, 'dtype', 'unknown')} "
            f"max_pixels={VISION_MAX_PIXELS or 'processor default'} "
            f"devices={devices}",
            flush=True,
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

        # ⛔ NO getattr DEFAULTS HERE ANY MORE. These read
        # `getattr(self, "_loaded_at", 0.0)`, and a reviewer measured what that
        # fabricates when it fires: `monotonic()`'s epoch is arbitrary, so the
        # "age" came out as 281,885s — a plausible-looking number in the
        # OVER-counting direction, against a cost model whose own docs say a
        # figure above the invoice means the model is wrong.
        #
        # ⚖️ `@modal.enter` runs before any input is served, so if these are
        # missing the container is in a state this code cannot describe. An
        # AttributeError says so; a default invents a measurement.
        # ⛔ CAPTURE THE COUNT, DO NOT DECIDE HERE. This line used to be
        # `gpu_cold = self._inferences_since_load == 0`, and the dispatch below
        # was then called with `0 if gpu_cold else …` — which made
        # `container_dispatch` a TAUTOLOGY: its answer was derived from the
        # predicate it was supposed to encode, so it could never disagree.
        # Extracting the function had moved the rule, not tested it: hard-coding
        # this flag left 123 tests green and lint clean, exactly as the
        # untestable original did. One holder of the rule, not two.
        #
        # ⚠️ RESIDUAL, STATED RATHER THAN IMPLIED: what is left here is still
        # undrivable — VisionModel is wrapped by @app.cls() into a Modal Cls, so
        # no test can instantiate it. Replacing this line with a literal still
        # passes 123 tests. The RULE is tested (tests/test_container_cold_counter.py
        # probes container_dispatch directly and reds 2 when defeated), but a wrong
        # CAPTURE here would not be caught. Two lines with no branching is a far
        # smaller unguarded surface than a predicate was; shrinking it further
        # means making the method drivable via a plain base class the @app.cls
        # inherits, which is a larger change than this correction.
        inferences_before = self._inferences_since_load

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
        parsed = _parse_json(response)

        # ⚖️ Under a reserved key rather than merged flat, so a model that ever
        # emits a field called `gpu_cold` cannot overwrite the measurement —
        # and so a reader can tell the model's answer from the container's
        # telemetry at a glance.
        #
        # ⛔ This is the cold start that costs money. The sidecar's own flag
        # tracks a CPU container whose warmth is independent of this one's; an
        # idle A10G is roughly two orders of magnitude more expensive per
        # second. Without this the expensive cold start was unmeasured.
        # ⛔ INCREMENTED HERE, AFTER THE INFERENCE SUCCEEDED, NOT BEFORE IT.
        # Read-then-increment at the top of this method meant a first inference
        # that RAISED — OOM, a generation error, a decode failure — still moved
        # the counter to 1, so no dispatch on that container ever reported its
        # cold start. That under-counts billed container lifetimes, in the same
        # flattering direction as the defect this measurement was built to
        # correct.
        #
        # ⚖️ Safe to defer: this class serves one input at a time (no
        # `@modal.concurrent`), which is the same invariant `GpuDispatch.cold`
        # already relies on to mean "this container's first answer".
        self._inferences_since_load += 1

        parsed["_container"] = container_dispatch(inferences_before, self._container_id)
        return parsed


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
    .apt_install("libzbar0", "tesseract-ocr", "tesseract-ocr-eng")
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
        "pytesseract>=0.3.13",
    )
    .add_local_dir(str(_VISION_DIR / "app"), remote_path="/app/app")
)


@app.function(
    image=_fastapi_image,
    secrets=[
        modal.Secret.from_name("thestacks-vision"),
        modal.Secret.from_dict({"MODAL_APP_NAME": MODAL_APP_NAME}),
    ],
    # Deliberately LONGER than the GPU class above, not matched to it.
    #
    # An earlier version of this comment argued that a longer window here would
    # mean "answering requests whose GPU has already scaled down, a slower first
    # response". That does not follow: this container's warmth is independent of
    # the GPU's. A cold front door costs an ASGI cold start ON TOP OF whatever
    # the GPU is doing, so keeping it warm strictly removes a term.
    #
    # The cost runs the other way too. An idle A10G is roughly two orders of
    # magnitude more expensive per second than an idle CPU container, so cutting
    # this one to 300s would capture a couple of percent of the saving while
    # giving away the cheap latency win. Each cold start here also re-runs
    # `lifespan`, rebuilding the client and re-hydrating `modal.Cls.from_name`
    # on some reader's first request.
    #
    # The money is in the GPU window; this one buys latency for almost nothing.
    scaledown_window=1200,
)
@modal.asgi_app()
def vision_api() -> Any:
    import sys

    sys.path.insert(0, "/app")
    from app.main import app as fastapi_app

    return fastapi_app
