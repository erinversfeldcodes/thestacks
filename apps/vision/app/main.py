import asyncio
import base64
import io
import logging
import time
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import httpx
import structlog
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from PIL import Image
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import settings
from app.proto.gen.vision import (
    AnalyzeRequest,
    AnalyzeResponse,
    EmbeddingVector,
    EmbedRequest,
    EmbedResponse,
    ExtractDocumentRequest,
    ExtractDocumentResponse,
    ExtractedBook,
    GpuDispatch,
    OcrAttempt,
    StageTimings,
)
from app.services.cover_text import CoverText, read_cover_text
from app.services.document_extract import UnsupportedFormatError
from app.services.document_extract import extract as extract_document
from app.services.hmac_auth import verify_hmac
from app.services.local_ocr import local_isbn_scan
from app.services.text_embed import embed_texts
from app.services.url_validator import validate_image_url
from app.services.vision_client import VisionClient

structlog.configure(
    wrapper_class=structlog.make_filtering_bound_logger(
        logging.getLevelName(settings.log_level.upper())
    ),
)

logger = structlog.get_logger()

_MAX_DOWNLOAD_BYTES = 10 * 1024 * 1024  # 10 MB
_DOWNLOAD_TIMEOUT = 10.0  # seconds

_VLM_MAX_SIDE = 672
_VLM_JPEG_QUALITY = 85


def _resize_for_vlm(image_b64: str, raw: bytes) -> str:
    """Downsize an image to max side `_VLM_MAX_SIDE` before sending to the
    VLM. Takes BOTH forms the caller already holds — the base64 string (the
    no-resize fallback, returned untouched so nothing is re-encoded) and the
    decoded bytes (so the one decode in `_load_image_b64` stays the only
    decode on the request path). Preserves aspect ratio, re-encodes as JPEG
    to guarantee a known format for the model. If the image is already
    smaller than the target, re-encode anyway to normalise format —
    the model accepts JPEG most reliably and the re-encode is ~5ms.

    On any Pillow error (truncated bytes, format we can't decode), fall
    back to returning the original base64 — resize is a perf optim, not
    a correctness requirement, and we'd rather send full-res to Modal
    than fail the upload.
    """
    try:
        opened = Image.open(io.BytesIO(raw))
        opened.load()
        img: Image.Image = opened if opened.mode in ("RGB", "L") else opened.convert("RGB")
        img.thumbnail((_VLM_MAX_SIDE, _VLM_MAX_SIDE), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=_VLM_JPEG_QUALITY, optimize=True)
        return base64.b64encode(buf.getvalue()).decode()
    except Exception as exc:
        logger.warning("vlm resize failed; sending original", error=str(exc))
        return image_b64


_CLF_BOOK = "CLASSIFICATION_RESULT_BOOK"

# The cascade tiers, as the contract names them.
#
# ⛔ These are IDENTITY, NOT SEQUENCE. The cascade runs barcode → embedding →
# OCR → VLM, and it is tempting to let the enum's numbers carry that order.
# They must not: a consumer comparing them numerically breaks the moment a tier
# is inserted out of order, and `buf` would never flag it because the numbers
# stayed valid. The order lives in the code below, not in these values.
_TIER_BARCODE = "ANALYSIS_TIER_BARCODE"
_TIER_VLM_CLASSIFY = "ANALYSIS_TIER_VLM_CLASSIFY"
_TIER_VLM_EXTRACT = "ANALYSIS_TIER_VLM_EXTRACT"
_TIER_OCR = "ANALYSIS_TIER_OCR"
# A cpu_only response that no tier answered: the request was served but makes
# no identification or classification claim of its own.
_TIER_UNSPECIFIED = "ANALYSIS_TIER_UNSPECIFIED"


def _gpu_dispatch(parsed: dict[str, object]) -> GpuDispatch | None:
    """One GPU dispatch's container reading, or None if it reported none.

    ⚠️ Tolerant by design: a GPU image deployed before these fields existed
    sends no `_container`, and the honest answer is "no reading" rather than a
    fabricated one.

    ⛔ Each value is type-checked individually rather than the dict cast
    wholesale. This crosses a process boundary from a separately deployed
    image, so "it is a dict" says nothing about what is inside it.
    """
    container = parsed.get("_container")
    if not isinstance(container, dict):
        return None

    cold = container.get("cold")
    cid = container.get("container_id")

    if not isinstance(cold, bool) or not isinstance(cid, str) or cid == "":
        return None

    return GpuDispatch(cold=cold, container_id=cid)


def _elapsed_ms(started: float) -> int:
    """Whole milliseconds since `started`, measured on the monotonic clock.

    ⚖️ `time.monotonic` rather than wall-clock: these figures feed a cost and
    latency decision, and a wall-clock step (NTP, a leap second) would show up
    as a negative or absurd duration in exactly the data the redesign argues
    from.
    """
    return int((time.monotonic() - started) * 1000)


_CLF_NOT_BOOK = "CLASSIFICATION_RESULT_NOT_BOOK"
_CLF_AMBIGUOUS = "CLASSIFICATION_RESULT_AMBIGUOUS"
_CLF_UNSPECIFIED = "CLASSIFICATION_RESULT_UNSPECIFIED"

_ML_TO_CLASSIFICATION: dict[str, str] = {
    "book": _CLF_BOOK,
    "not_book": _CLF_NOT_BOOK,
    "ambiguous": _CLF_AMBIGUOUS,
}


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    app.state.vision_client = VisionClient()

    # ⚖️ The FIRST request after a process starts is the cold one. `lifespan`
    # runs once per container, so a flag set here and cleared by the first
    # handler is exactly "was this container cold when the request arrived" —
    # which is the question, rather than how long the container has lived.
    #
    # ⛔ A boolean, not an age: the decision it feeds is binary, and an age
    # would invite a threshold nobody agreed on.
    app.state.container_cold = True

    yield
    await app.state.vision_client.close()


app = FastAPI(title="The Stacks Vision Service", version="0.1.0", lifespan=lifespan, debug=False)

_ERR_UNDECODABLE_IMAGE = "VISION_ERROR_CODE_UNDECODABLE_IMAGE"
_ERR_IMAGE_TOO_LARGE = "VISION_ERROR_CODE_IMAGE_TOO_LARGE"
_ERR_IMAGE_UNREACHABLE = "VISION_ERROR_CODE_IMAGE_UNREACHABLE"
#   ⚠️ NO_IMAGE_SUPPLIED has no reachable raiser as of 2026-10-15, and is kept
#   deliberately. `AnalyzeRequest` declares `image`/`image_url` as a protobuf
#   `oneof`, so Pydantic rejects "neither field set" before any handler body
#   runs and the caller gets MALFORMED_REQUEST instead. The one raise site below
#   is therefore defensive only. It stays because
#   `test_error_constants_are_exactly_the_proto_enums_non_zero_values` pins this
#   module's constant set to the proto enum, and the enum value must not be
#   deleted: that is a wire-contract change, and `Stacks.AI.VisionError` maps
#   every value to a cancel. `/extract` was its only live path.
_ERR_NO_IMAGE_SUPPLIED = "VISION_ERROR_CODE_NO_IMAGE_SUPPLIED"
_ERR_MALFORMED_REQUEST = "VISION_ERROR_CODE_MALFORMED_REQUEST"


def _vision_error(code: str, message: str, status_code: int = 422) -> HTTPException:
    """Build a deterministic-failure response carrying a `VisionError` body.

    The structured detail is unwrapped to the top level by the handler below, so
    the body on the wire is exactly `{"code": ..., "message": ...}` — the JSON
    encoding of the proto message. Callers branch on `code`; `message` is for
    logs and human eyes and is never parsed.
    """
    return HTTPException(status_code=status_code, detail={"code": code, "message": message})


@app.exception_handler(StarletteHTTPException)
async def _http_exception_handler(_request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """Render `_vision_error` details as a bare `VisionError`, everything else as
    FastAPI would.

    Auth failures, validation errors raised elsewhere, and anything else with a
    string detail keep the default `{"detail": "..."}` shape — they are not
    determinations about an image, and giving them a code would tell the caller
    to stop retrying something it should retry.
    """
    if isinstance(exc.detail, dict) and "code" in exc.detail:
        return JSONResponse(status_code=exc.status_code, content=exc.detail)
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


@app.exception_handler(RequestValidationError)
async def _validation_exception_handler(
    _request: Request, exc: RequestValidationError
) -> JSONResponse:
    """Label schema-validation failures as deterministically malformed.

    Pydantic validates the request model before a handler body runs, so the
    mutual-exclusion and required-field checks declared on the generated proto
    models reject here — never reaching the endpoint's own `_vision_error`
    calls. Without this handler that whole class of failure went back as
    FastAPI's default envelope, and core retried a request that could not
    become valid by being sent again.

    The summary deliberately drops Pydantic's `input` key. That field echoes the
    offending request body, which for this endpoint is base64 image bytes —
    which does not belong in an error body the caller logs.
    """
    problems = "; ".join(
        f"{'.'.join(str(part) for part in error.get('loc', []))}: {error.get('msg', '')}"
        for error in exc.errors()
    )

    return JSONResponse(
        status_code=422,
        content={
            "code": _ERR_MALFORMED_REQUEST,
            "message": f"Request failed schema validation — {problems}",
        },
    )


@app.get("/health", status_code=200)
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "vision", "environment": settings.environment}


async def _download_image(image_url: str) -> bytes:
    """Download an image from a URL, enforcing size and timeout limits."""
    await validate_image_url(image_url)
    async with (
        httpx.AsyncClient(timeout=_DOWNLOAD_TIMEOUT, follow_redirects=False) as client,
        client.stream("GET", image_url) as resp,
    ):
        if resp.status_code in (301, 302, 303, 307, 308):
            raise _vision_error(
                _ERR_IMAGE_UNREACHABLE,
                f"Image URL redirected (HTTP {resp.status_code}); redirects not permitted",
            )
        if resp.status_code != 200:
            raise _vision_error(
                _ERR_IMAGE_UNREACHABLE,
                f"Failed to download image from URL: HTTP {resp.status_code}",
            )
        chunks: list[bytes] = []
        total = 0
        async for chunk in resp.aiter_bytes(chunk_size=65536):
            total += len(chunk)
            if total > _MAX_DOWNLOAD_BYTES:
                raise _vision_error(
                    _ERR_IMAGE_TOO_LARGE,
                    f"Image URL exceeds max size of {_MAX_DOWNLOAD_BYTES} bytes",
                )
            chunks.append(chunk)
    return b"".join(chunks)


async def _load_image_b64(
    image: str | None,
    image_url: str | None,
) -> tuple[str, bytes]:
    """Resolve `image` (already base64) OR `image_url` (downloaded and re-encoded)
    into a (base64 string, decoded bytes) pair. Raises HTTPException(422) for
    invalid input — carrying forward the validation semantics the removed
    /classify endpoint applied inline, factored out so /analyze can reuse them
    without duplication.

    The bytes ride along because this function already decoded them to validate:
    returning both makes this the ONE base64 decode on the request path — every
    downstream tier (barcode, cover text, resize) takes the bytes.
    """
    if image_url is not None:
        image_bytes = await _download_image(image_url)
        return base64.b64encode(image_bytes).decode(), image_bytes
    if image is None:
        raise _vision_error(
            _ERR_NO_IMAGE_SUPPLIED, "Either 'image' or 'image_url' must be provided"
        )
    try:
        decoded = base64.b64decode(image, validate=True)
    except Exception as exc:
        raise _vision_error(_ERR_UNDECODABLE_IMAGE, "Image is not valid base64") from exc
    if len(decoded) > settings.max_image_size_bytes:
        raise _vision_error(
            _ERR_IMAGE_TOO_LARGE,
            f"Image exceeds max size of {settings.max_image_size_bytes} bytes",
        )
    return image, decoded


async def _timed_cover_read(image_bytes: bytes) -> tuple[CoverText, int]:
    """The shadow cover read, timed from inside its own coroutine so `ocr_ms`
    reports the read's duration, not how long it overlapped the GPU call it
    runs concurrently with. Thread-offloaded: Tesseract-class work must not
    block the event loop. `read_cover_text` never raises by contract, so a
    task over this is harvest-safe."""
    started = time.monotonic()
    cover = await asyncio.to_thread(read_cover_text, image_bytes)
    return cover, _elapsed_ms(started)


def _parse_classification(parsed: dict[str, object]) -> tuple[str, float]:
    """Normalise the ML model's classify payload into a (proto-enum, confidence)
    pair. Carried over from the removed /classify endpoint's inline parsing."""
    raw_ml = str(parsed.get("classification", "ambiguous"))
    classification = _ML_TO_CLASSIFICATION.get(raw_ml, _CLF_AMBIGUOUS)
    raw_confidence = parsed.get("confidence", 0.0)
    confidence = float(raw_confidence) if isinstance(raw_confidence, int | float) else 0.0
    confidence = max(0.0, min(1.0, confidence))
    return classification, confidence


def _parse_extracted_books(parsed: dict[str, object]) -> list[ExtractedBook]:
    """Normalise the ML model's extract payload into a list of ExtractedBook.
    Carried over from the removed /extract endpoint's inline parsing."""
    books: list[ExtractedBook] = []
    raw_books = parsed.get("books")
    if not isinstance(raw_books, list):
        return books
    for item in raw_books:
        if not isinstance(item, dict):
            continue
        title = item.get("title")
        author = item.get("author")
        isbns = item.get("potential_isbns")
        raw_text = item.get("raw_text")
        conf = item.get("confidence")
        books.append(
            ExtractedBook(
                title=title if isinstance(title, str) else None,
                author=author if isinstance(author, str) else None,
                potential_isbns=isbns if isinstance(isbns, list) else [],
                raw_text=raw_text if isinstance(raw_text, str) else None,
                confidence=float(conf) if isinstance(conf, int | float) else None,
            )
        )
    return books


@app.post(
    "/analyze",
    response_model=AnalyzeResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def analyze(request: Request, body: AnalyzeRequest) -> AnalyzeResponse:
    """Two-call classification + extraction in the FastAPI layer:
    1. local OCR pre-pass — a clean barcode decode implies BOOK (ISBN
       checksums make false positives ~zero) and skips the classify call;
    2. classify — on confident NOT_BOOK or AMBIGUOUS, short-circuit with
       empty books; ``extract`` is NEVER invoked (the load-bearing contract
       for the bunny-screenshot regression, and half the Modal cost on
       non-books);
    3. extract — only for BOOK.
    Returns the combined AnalyzeResponse shape core expects.
    """
    log = logger.bind(endpoint="/analyze")

    # ⚖️ Read and clear in one step, so concurrent requests on a cold container
    # cannot all claim to be the cold one. The first request that gets here owns
    # the flag; every later request on this container reports warm.
    cold = getattr(request.app.state, "container_cold", False)
    request.app.state.container_cold = False

    download_started = time.monotonic()
    image_b64, decoded_bytes = await _load_image_b64(body.image, body.image_url)
    download_ms = _elapsed_ms(download_started)

    if body.image_url is not None:
        log = log.bind(image_url=body.image_url)

    if settings.local_ocr_enabled:
        barcode_started = time.monotonic()
        # Thread-offloaded: six pyzbar decode attempts at full resolution would
        # otherwise sit on the event loop under `:vision` concurrency.
        isbn = await asyncio.to_thread(local_isbn_scan, decoded_bytes)
        barcode_ms = _elapsed_ms(barcode_started)

        if isbn is not None:
            log.info("local OCR pre-pass hit", isbn=isbn)
            return AnalyzeResponse(
                classification=_CLF_BOOK,
                confidence=1.0,
                books=[ExtractedBook(potential_isbns=[isbn], confidence=1.0)],
                model_used="local_ocr",
                tier=_TIER_BARCODE,
                timings_ms=StageTimings(download=download_ms, barcode=barcode_ms),
                sidecar_cold=cold,
            )
    else:
        barcode_ms = None

    if body.cpu_only:
        # ⬛ THE CPU-FIRST PASS: report what the CPU tiers read and STOP — the
        # GPU is NEVER dispatched on this request. Core owns catalogue
        # resolution of the read and the decision to escalate to a full
        # analyze on a miss. No classification claim is made here (the
        # classify guard is a GPU step), so classification is UNSPECIFIED and
        # the contract tells consumers not to route it through the
        # book/not-book branch. A barcode hit never reaches this point — it
        # already returned above, tier BARCODE, same as every other mode.
        cpu_ocr_attempt = None
        cpu_ocr_ms = None

        if settings.cover_text_enabled:
            ocr_started = time.monotonic()
            cover = await asyncio.to_thread(read_cover_text, decoded_bytes)
            cpu_ocr_ms = _elapsed_ms(ocr_started)
            cpu_ocr_attempt = OcrAttempt(
                title=cover.title,
                author=cover.author,
                raw_text=cover.raw_text,
                confidence=cover.confidence,
                answered=False,
                engine=cover.engine,
            )

        return AnalyzeResponse(
            classification=_CLF_UNSPECIFIED,
            confidence=0.0,
            books=[],
            model_used=cpu_ocr_attempt.engine if cpu_ocr_attempt else "cpu_only",
            tier=_TIER_UNSPECIFIED,
            ocr_attempt=cpu_ocr_attempt,
            timings_ms=StageTimings(download=download_ms, barcode=barcode_ms, ocr=cpu_ocr_ms),
            sidecar_cold=cold,
        )

    # ⬛ THE CPU TEXT PASS, BETWEEN BARCODE AND THE GPU. This container is the
    # ASGI front door every request already passes through, with a 1200s
    # scaledown, so it is warm by construction: text read here opens no new
    # billable lifetime and owes no idle tail. That is the whole economic case
    # — measurement put a lone GPU identification at ~9.8c against 0.18c of
    # actual compute, nearly all of it a 300s window on a container that woke
    # to answer one request.
    #
    # ⚠️ SHADOW BY DEFAULT. The read is recorded and the VLM still answers,
    # unless `ocr_short_circuit` is on AND the read clears its confidence bar.
    # Measuring a tier with the thing it would replace still running is the
    # only way to get a hit rate without first trusting it.
    ocr_attempt = None
    ocr_ms = None
    ocr_task: asyncio.Task[tuple[CoverText, int]] | None = None

    if settings.cover_text_enabled and not settings.ocr_short_circuit:
        # Pure shadow: the VLM answers regardless, so the read must not sit on
        # the serial path adding latency it then discards. It overlaps the GPU
        # call and is harvested after the dispatch returns. If the dispatch
        # raises, the task finishes quietly in its thread — `read_cover_text`
        # never raises, and an unretrieved RESULT (unlike an exception) emits
        # no warning — so no try/finally ceremony is owed here.
        ocr_task = asyncio.create_task(_timed_cover_read(decoded_bytes))
    elif settings.cover_text_enabled:
        # Short-circuit mode: serial by necessity — a confident read answers
        # without waking the GPU at all. Thread-offloaded like every CPU tier.
        ocr_started = time.monotonic()
        cover = await asyncio.to_thread(read_cover_text, decoded_bytes)
        ocr_ms = _elapsed_ms(ocr_started)

        confident = (
            cover.title is not None
            and cover.confidence >= settings.ocr_short_circuit_min_confidence
        )
        answered = bool(confident)

        ocr_attempt = OcrAttempt(
            title=cover.title,
            author=cover.author,
            raw_text=cover.raw_text,
            confidence=cover.confidence,
            answered=answered,
            engine=cover.engine,
        )

        if answered:
            # ⛔ A TITLE IS NOT AN IDENTIFICATION. No `potential_isbns` here,
            # deliberately: core resolves the title against Open Library /
            # Google Books and the ISBN hard gate is satisfied there. Emitting
            # a fabricated ISBN to make this look like the barcode tier would
            # turn a guess into a verified edition.
            log.info("cover text answered", title=cover.title, confidence=cover.confidence)
            return AnalyzeResponse(
                classification=_CLF_BOOK,
                confidence=cover.confidence,
                books=[
                    ExtractedBook(
                        title=cover.title,
                        author=cover.author,
                        raw_text=cover.raw_text,
                        potential_isbns=[],
                        confidence=cover.confidence,
                    )
                ],
                model_used=cover.engine,
                tier=_TIER_OCR,
                ocr_attempt=ocr_attempt,
                timings_ms=StageTimings(download=download_ms, barcode=barcode_ms, ocr=ocr_ms),
                sidecar_cold=cold,
            )

    client: VisionClient = request.app.state.vision_client

    vlm_b64 = _resize_for_vlm(image_b64, decoded_bytes)

    # ⬛ R0, BEHIND settings.single_dispatch. ON: classify + conditional extract
    # run as ONE Modal dispatch on one container (`analyze`), eliminating the
    # second-cold-start tail two separate `.remote()` calls risked (~52s p95 on
    # a cold book). OFF (default): the measured two-call baseline, unchanged.
    # Either way the front door re-parses the classification authoritatively and
    # uses the extract only for a book, so the shared logic below is identical.
    extract_parsed_opt: dict[str, object] | None = None
    if settings.single_dispatch:
        log.info("calling vision model for analyze (single dispatch)")
        analyze_started = time.monotonic()
        analyzed = await client.analyze(vlm_b64, excluded_books=list(body.excluded_books))
        classify_ms = _elapsed_ms(analyze_started)
        _c = analyzed.get("classify")
        classify_parsed: dict[str, object] = _c if isinstance(_c, dict) else {}
        _e = analyzed.get("extract")
        extract_parsed_opt = _e if isinstance(_e, dict) else None
        # The GPU container names its own model in the analyze payload; prefer
        # that claim over this front door's configured default — the two
        # diverged once and a recorded baseline inherited the wrong name.
        _m = analyzed.get("model")
        gpu_model = _m if isinstance(_m, str) and _m else settings.model_name
    else:
        log.info("calling vision model for classify")
        classify_started = time.monotonic()
        classify_parsed = await client.classify(vlm_b64)
        classify_ms = _elapsed_ms(classify_started)
        # The two-call methods carry no model claim; the configured name is
        # the only available answer on this fallback path.
        gpu_model = settings.model_name

    # Harvest the shadow read that overlapped the GPU call. `ocr_ms` is the
    # read's own duration (timed inside the task), so the timings stay honest.
    if ocr_task is not None:
        cover, ocr_ms = await ocr_task
        ocr_attempt = OcrAttempt(
            title=cover.title,
            author=cover.author,
            raw_text=cover.raw_text,
            confidence=cover.confidence,
            answered=False,
            engine=cover.engine,
        )

    gpu_dispatches: list[GpuDispatch] = []
    if (d := _gpu_dispatch(classify_parsed)) is not None:
        gpu_dispatches.append(d)
    classification, confidence = _parse_classification(classify_parsed)

    if classification != _CLF_BOOK:
        log.info(
            "analyze short-circuited at classify",
            classification=classification,
            confidence=confidence,
        )
        return AnalyzeResponse(
            classification=classification,
            confidence=confidence,
            books=[],
            model_used=gpu_model,
            tier=_TIER_VLM_CLASSIFY,
            gpu_dispatches=gpu_dispatches,
            ocr_attempt=ocr_attempt,
            timings_ms=StageTimings(
                download=download_ms, barcode=barcode_ms, ocr=ocr_ms, classify=classify_ms
            ),
            sidecar_cold=cold,
        )

    # Book path. Single-dispatch: extract already ran inside `analyze` on the
    # same container (no second cold start). Two-call: dispatch extract now.
    if settings.single_dispatch:
        extract_parsed = extract_parsed_opt or {"books": []}
        extract_ms: int | None = None
    else:
        log.info(
            "calling vision model for extract",
            excluded_books_count=len(body.excluded_books),
        )
        extract_started = time.monotonic()
        extract_parsed = await client.extract(
            [vlm_b64],
            excluded_books=list(body.excluded_books),
        )
        extract_ms = _elapsed_ms(extract_started)
    if (d := _gpu_dispatch(extract_parsed)) is not None:
        gpu_dispatches.append(d)
    books = _parse_extracted_books(extract_parsed)
    log.info(
        "analyze complete",
        classification=classification,
        confidence=confidence,
        book_count=len(books),
    )

    return AnalyzeResponse(
        classification=classification,
        confidence=confidence,
        books=books,
        model_used=gpu_model,
        tier=_TIER_VLM_EXTRACT,
        gpu_dispatches=gpu_dispatches,
        ocr_attempt=ocr_attempt,
        timings_ms=StageTimings(
            download=download_ms,
            barcode=barcode_ms,
            ocr=ocr_ms,
            # Two-call path: classify and extract are separately timed. Single
            # dispatch: `classify_ms` covers the whole analyze round-trip and
            # `extract_ms` is None (not separately observable) rather than a
            # fabricated split.
            classify=classify_ms,
            extract=extract_ms,
        ),
        sidecar_cold=cold,
    )


@app.post(
    "/embed",
    response_model=EmbedResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def embed(body: EmbedRequest) -> EmbedResponse:
    """Text-embedding backend for the writing-assistant corpus, on the CPU
    front door — NO GPU dispatch, ever.

    Produces one bge-m3 vector per input text, in request order, on the warm
    FastAPI container every request already passes through. HMAC-gated
    identically to /analyze.

    ⛔ THE RESPONSE STAMPS THE MODEL THAT RAN, not `body.model`. The request's
    model is advisory (the caller may ask for `bge-m3`; an older container may
    serve something else); `embed_texts` reports what ACTUALLY produced the
    vectors and the caller persists THAT. Echoing the request here would record
    a model the row was never embedded with.

    ⚖️ CPU-heavy work off the event loop. The first call also loads the ~2.3GB
    model; both the load and the encode run in a worker thread so the ASGI loop
    stays free for the barcode / cover-text / analyze paths — the same offload
    `read_cover_text` and `local_isbn_scan` get.
    """
    if not body.texts:
        # Deterministic failure: resending an empty batch cannot make it valid,
        # so it is MALFORMED_REQUEST and the caller must not retry it. (The
        # proto declares no oneof here, so Pydantic admits `texts: []` and this
        # is the only place it is rejected.)
        raise _vision_error(_ERR_MALFORMED_REQUEST, "'texts' must contain at least one string")

    log = logger.bind(endpoint="/embed", text_count=len(body.texts), requested_model=body.model)

    embed_started = time.monotonic()
    vectors, model, dim = await asyncio.to_thread(embed_texts, list(body.texts))
    log.info("embed complete", model=model, dim=dim, embed_ms=_elapsed_ms(embed_started))

    return EmbedResponse(
        vectors=[EmbeddingVector(values=values) for values in vectors],
        model=model,
        dim=dim,
    )


@app.post(
    "/extract-document",
    response_model=ExtractDocumentResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def extract_document_endpoint(body: ExtractDocumentRequest) -> ExtractDocumentResponse:
    """Parse an uploaded document to plain text on the CPU front door — NO GPU
    dispatch, ever, and the bytes are never persisted past this call.

    Backs writing-assistant ingestion of the author's OWN unpublished writing
    (PDF / ePub / DOCX / Markdown / plain text): base64-decode `content`, parse
    it by `format`, return the text with its character count. HMAC-gated
    identically to /analyze and /embed.

    ⚖️ THREE DETERMINISTIC REJECTIONS, each MALFORMED_REQUEST — resending the
    same request cannot make any of them valid: an empty `content`, a `content`
    that is not valid base64, and a `format` outside the supported set. A known
    format whose bytes carry no extractable text is NOT one of these — it
    returns text="" / char_count=0, and the caller catches the zero count (per
    the contract) as a parse failure, so it is a 200, not an error.

    ⚖️ The parse runs in a worker thread (`asyncio.to_thread`), off the ASGI
    event loop — PDF and epub parsing is CPU-bound, the same offload the
    barcode / cover-text / embed paths take.
    """
    if not body.content:
        raise _vision_error(_ERR_MALFORMED_REQUEST, "'content' must not be empty")

    try:
        content_bytes = base64.b64decode(body.content, validate=True)
    except Exception as exc:
        raise _vision_error(_ERR_MALFORMED_REQUEST, "'content' is not valid base64") from exc

    if not content_bytes:
        raise _vision_error(_ERR_MALFORMED_REQUEST, "'content' decoded to empty bytes")

    log = logger.bind(endpoint="/extract-document", format=body.format, bytes=len(content_bytes))

    extract_started = time.monotonic()
    try:
        text, char_count = await asyncio.to_thread(extract_document, content_bytes, body.format)
    except UnsupportedFormatError as exc:
        raise _vision_error(_ERR_MALFORMED_REQUEST, str(exc)) from exc

    log.info(
        "extract-document complete",
        char_count=char_count,
        extract_ms=_elapsed_ms(extract_started),
    )

    return ExtractDocumentResponse(text=text, char_count=char_count)
