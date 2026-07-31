import base64
import hashlib
import hmac
import io
import logging
import time
import uuid
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import httpx
import structlog
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from PIL import Image
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import settings
from app.proto.gen.vision import (
    AnalyzeRequest,
    AnalyzeResponse,
    AssociateCallback,
    AssociateRequest,
    AssociateResponse,
    ClassifyRequest,
    ClassifyResponse,
    ExtractedBook,
    ExtractRequest,
    ExtractResponse,
)
from app.services.hmac_auth import verify_hmac
from app.services.local_ocr import local_isbn_scan
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

# Target max side for images sent to the VLM. Qwen2.5-VL uses dynamic
# resolution tokenisation — token count scales with pixel count, and
# inference time scales roughly linearly with tokens. A phone photo
# (4032x3024) produces ~3000+ visual tokens; 672x672 produces ~144. For
# book-cover classification + ISBN/title extraction, 672 is plenty
# (text remains legible) and cuts Modal inference from ~2.5s to ~1s on
# A10G. Applied AFTER the local OCR pre-pass, which needs full
# resolution to decode barcodes reliably.
_VLM_MAX_SIDE = 672
_VLM_JPEG_QUALITY = 85

# In-memory idempotency set: edition_id → job_id.
# Cleared on restart; acceptable for async best-effort semantics.
_associate_jobs: dict[str, str] = {}

_ASSOCIATE_CALLBACK_PATH = "/api/internal/vision/associate"


def _resize_for_vlm(image_b64: str) -> str:
    """Downsize a base64-encoded image to max side `_VLM_MAX_SIDE` before
    sending to the VLM. Preserves aspect ratio, re-encodes as JPEG to
    guarantee a known format for the model. If the image is already
    smaller than the target, re-encode anyway to normalise format —
    the model accepts JPEG most reliably and the re-encode is ~5ms.

    On any Pillow error (truncated bytes, format we can't decode), fall
    back to returning the original base64 — resize is a perf optim, not
    a correctness requirement, and we'd rather send full-res to Modal
    than fail the upload.
    """
    try:
        raw = base64.b64decode(image_b64, validate=True)
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


# Proto ClassificationResult enum string values (wire format for ClassifyResponse.classification).
_CLF_BOOK = "CLASSIFICATION_RESULT_BOOK"
_CLF_NOT_BOOK = "CLASSIFICATION_RESULT_NOT_BOOK"
_CLF_AMBIGUOUS = "CLASSIFICATION_RESULT_AMBIGUOUS"

# Mapping from raw ML model output → proto ClassificationResult enum string.
# The ML model returns lowercase shorthand; callers receive proto enum names.
_ML_TO_CLASSIFICATION: dict[str, str] = {
    "book": _CLF_BOOK,
    "not_book": _CLF_NOT_BOOK,
    "ambiguous": _CLF_AMBIGUOUS,
}
_VALID_CLASSIFICATIONS = set(_ML_TO_CLASSIFICATION.values())

# Proto AssociationStatus enum string values (wire format for AssociateCallback.status).
_STATUS_CONFIRMED = "ASSOCIATION_STATUS_CONFIRMED"
_STATUS_REJECTED = "ASSOCIATION_STATUS_REJECTED"


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    app.state.vision_client = VisionClient()
    yield
    await app.state.vision_client.close()


app = FastAPI(title="The Stacks Vision Service", version="0.1.0", lifespan=lifespan, debug=False)


# Proto VisionErrorCode enum string values (wire format for VisionError.code).
#
# These name failures that are DETERMINISTIC: the same request repeated produces
# the same answer. The caller (`Stacks.AI.VisionError`) cancels the upload on
# any of them instead of retrying, which is the whole reason they are labelled.
# A transient fault must NOT be given a code here — it is carried by the HTTP
# status alone and stays retryable.
_ERR_UNDECODABLE_IMAGE = "VISION_ERROR_CODE_UNDECODABLE_IMAGE"
_ERR_IMAGE_TOO_LARGE = "VISION_ERROR_CODE_IMAGE_TOO_LARGE"
_ERR_IMAGE_UNREACHABLE = "VISION_ERROR_CODE_IMAGE_UNREACHABLE"
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
    offending request body, which for these endpoints is base64 image bytes and,
    on `/associate`, user-linked identifiers — none of which belongs in an error
    body the caller logs.
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


def _sign_callback() -> str:
    """Compute X-Vision-Signature for a vision → core callback.

    Format: "<unix_ts>.<HMAC-SHA256(secret, ts.POST.path)>" — matches InternalController.
    """
    ts = str(int(time.time()))
    message = f"{ts}.POST.{_ASSOCIATE_CALLBACK_PATH}"
    sig = hmac.new(
        settings.hmac_secret.encode(),
        message.encode(),
        hashlib.sha256,
    ).hexdigest()
    return f"{ts}.{sig}"


async def _run_associate(
    job_id: str,
    body: AssociateRequest,
    client: VisionClient,
) -> None:
    """Background task: classify cover, POST result to core callback."""
    log = logger.bind(job_id=job_id, edition_id=body.edition_id, isbn=body.isbn)

    reason: str | None = None
    try:
        image_bytes = await _download_image(body.cover_image_url)
        image_b64 = base64.b64encode(image_bytes).decode()
        parsed = await client.classify(image_b64)
        raw_ml = str(parsed.get("classification", "ambiguous"))
        clf = _ML_TO_CLASSIFICATION.get(raw_ml, _CLF_AMBIGUOUS)
        is_book = clf == _CLF_BOOK
        status = _STATUS_CONFIRMED if is_book else _STATUS_REJECTED
        # Ambiguous classification is treated as rejection. Core can distinguish
        # this from a definitive non-book by checking reason == "not_a_book_cover"
        # vs a future "ambiguous_classification" reason if needed.
        if is_book:
            reason = None
        elif clf == _CLF_AMBIGUOUS:
            # Ambiguous: model was unsure. Distinct from definitive non-book.
            # Product decision: treat as rejection; caller may retry.
            # See docs/decisions/006-ambiguous-classification-as-rejection.md
            reason = "ambiguous_classification"
        else:
            reason = "not_a_book_cover"
        log.info(
            "associate: classification done",
            classification=clf,
            status=status,
            reasoning=parsed.get("reasoning"),
        )
    except HTTPException as exc:
        log.warning("associate: cover download failed", detail=exc.detail)
        status = _STATUS_REJECTED
        reason = "cover_download_failed"
    except Exception as exc:
        log.error("associate: unexpected error", error=str(exc))
        status = _STATUS_REJECTED
        reason = "internal_error"

    callback = AssociateCallback(
        isbn=body.isbn,
        book_id=body.book_id,
        edition_id=body.edition_id,
        status=status,
        job_id=job_id,
        reason=reason,
        cover_image_url=body.cover_image_url,
    )
    payload_bytes = callback.model_dump_json().encode()
    signature = _sign_callback()

    callback_url = f"{settings.effective_core_api_url}{_ASSOCIATE_CALLBACK_PATH}"
    try:
        async with httpx.AsyncClient(timeout=10.0) as http:
            resp = await http.post(
                callback_url,
                content=payload_bytes,
                headers={
                    "Content-Type": "application/json",
                    "X-Vision-Signature": signature,
                },
            )
        log.info("associate: callback sent", status_code=resp.status_code)
    except Exception as exc:
        log.error("associate: callback failed", error=str(exc))


@app.post(
    "/extract",
    response_model=ExtractResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def extract(request: Request, body: ExtractRequest) -> ExtractResponse:
    log = logger.bind(endpoint="/extract")

    # Mutual exclusion and size guard (proto carries no constraints; enforce here).
    if body.images and body.image_url is not None:
        raise _vision_error(
            _ERR_MALFORMED_REQUEST, "Provide either 'images' or 'image_url', not both"
        )
    if len(body.images) > 3:
        raise _vision_error(_ERR_MALFORMED_REQUEST, "'images' must contain at most 3 items")

    # --- image_url path ---
    if body.image_url is not None:
        log = log.bind(image_url=body.image_url)
        image_bytes = await _download_image(body.image_url)
        image_b64 = base64.b64encode(image_bytes).decode()

        if settings.local_ocr_enabled:
            isbn = local_isbn_scan(image_bytes)
            if isbn is not None:
                log.info("local OCR pre-pass hit (url path)", isbn=isbn)
                return ExtractResponse(
                    books=[ExtractedBook(potential_isbns=[isbn], confidence=1.0)],
                    model_used="local_ocr",
                )

        client: VisionClient = request.app.state.vision_client
        log.info("calling vision model for extraction (url path)")
        parsed = await client.extract([image_b64])
    else:
        # --- base64 images path ---
        if not body.images:
            raise _vision_error(
                _ERR_NO_IMAGE_SUPPLIED, "Either 'images' or 'image_url' must be provided"
            )
        log = log.bind(image_count=len(body.images))

        for idx, img in enumerate(body.images):
            try:
                decoded = base64.b64decode(img, validate=True)
            except Exception as exc:
                raise _vision_error(
                    _ERR_UNDECODABLE_IMAGE, f"Image at index {idx} is not valid base64"
                ) from exc
            if len(decoded) > settings.max_image_size_bytes:
                raise _vision_error(
                    _ERR_IMAGE_TOO_LARGE,
                    f"Image at index {idx} exceeds max size of {settings.max_image_size_bytes} bytes",  # noqa: E501
                )

        if settings.local_ocr_enabled:
            first_decoded = base64.b64decode(body.images[0], validate=True)
            isbn = local_isbn_scan(first_decoded)
            if isbn is not None:
                log.info("local OCR pre-pass hit", isbn=isbn)
                return ExtractResponse(
                    books=[ExtractedBook(potential_isbns=[isbn], confidence=1.0)],
                    model_used="local_ocr",
                )

        client = request.app.state.vision_client
        images_for_model = body.images
        log.info("calling vision model for extraction")
        parsed = await client.extract(images_for_model)

    if not parsed:
        log.warning("extraction: empty result from vision model")

    books: list[ExtractedBook] = []
    raw_books = parsed.get("books")
    if isinstance(raw_books, list):
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

    log.info("extraction complete", book_count=len(books))
    return ExtractResponse(books=books, model_used=settings.model_name)


@app.post(
    "/associate",
    response_model=AssociateResponse,
    status_code=202,
    dependencies=[Depends(verify_hmac)],
)
async def associate(
    request: Request,
    body: AssociateRequest,
    background_tasks: BackgroundTasks,
) -> AssociateResponse:
    """Async: classify a cover image and callback to core with the result.

    Idempotent per edition_id — repeat calls return the same job_id.
    """
    # Proto3 scalar fields default to "" — explicitly reject empty required fields.
    if not body.isbn or not body.book_id or not body.edition_id or not body.cover_image_url:
        raise _vision_error(
            _ERR_MALFORMED_REQUEST,
            "isbn, book_id, edition_id, and cover_image_url are required",
        )
    # Pre-validate URL before queuing background task — provides fast rejection (422)
    # before accepting the job. _download_image also validates on fetch.
    await validate_image_url(body.cover_image_url)

    edition_id = body.edition_id
    if edition_id in _associate_jobs:
        return AssociateResponse(job_id=_associate_jobs[edition_id])

    job_id = str(uuid.uuid4())
    _associate_jobs[edition_id] = job_id

    client: VisionClient = request.app.state.vision_client
    background_tasks.add_task(_run_associate, job_id, body, client)

    logger.bind(job_id=job_id, edition_id=edition_id).info("associate: job queued")
    return AssociateResponse(job_id=job_id)


async def _load_image_b64(
    image: str | None,
    image_url: str | None,
) -> str:
    """Resolve `image` (already base64) OR `image_url` (downloaded and re-encoded)
    into a single base64-encoded string. Raises HTTPException(422) for invalid
    input — identical validation semantics to the /classify endpoint's inline
    logic, factored out so /analyze can reuse it without duplication.
    """
    if image_url is not None:
        image_bytes = await _download_image(image_url)
        return base64.b64encode(image_bytes).decode()
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
    return image


def _parse_classification(parsed: dict[str, object]) -> tuple[str, float]:
    """Normalise the ML model's classify payload into a (proto-enum, confidence)
    pair. Identical to /classify's inline parsing."""
    raw_ml = str(parsed.get("classification", "ambiguous"))
    classification = _ML_TO_CLASSIFICATION.get(raw_ml, _CLF_AMBIGUOUS)
    raw_confidence = parsed.get("confidence", 0.0)
    confidence = float(raw_confidence) if isinstance(raw_confidence, int | float) else 0.0
    confidence = max(0.0, min(1.0, confidence))
    return classification, confidence


def _parse_extracted_books(parsed: dict[str, object]) -> list[ExtractedBook]:
    """Normalise the ML model's extract payload into a list of ExtractedBook.
    Identical to /extract's inline parsing."""
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
    """Two-call classification + extraction in the FastAPI layer.

    Flow:
      1. Local OCR pre-pass — a clean barcode decode implies BOOK without
         needing the vision model. ISBN barcodes have a checksum, so false
         positives on non-books are effectively zero.
      2. Classify (one `client.classify` call, focused prompt). On
         confident NOT_BOOK or AMBIGUOUS we short-circuit and return with
         empty books — `extract` is never invoked. This is the load-bearing
         contract for the bunny-screenshot regression case and also halves
         the Modal cost on non-book inputs.
      3. Extract (one `client.extract` call, focused prompt) — only on
         confirmed BOOK classifications. The per-book `confidence` field
         from the extract prompt feeds Issue #167's enrichment-skip gate
         downstream.

    Previously this endpoint issued a single consolidated `client.analyze`
    call. That collapsed prompt leaked classify reasoning into extract
    reasoning and over-populated `books` on non-book inputs (e.g.
    screenshot_bunny.jpg landed BOOK with empty books rather than
    NOT_BOOK; rotated covers picked up confident wrong identifications).
    The two-call flow restores the strict classification gate from
    git ref dfef1333.
    """
    log = logger.bind(endpoint="/analyze")

    image_b64 = await _load_image_b64(body.image, body.image_url)
    if body.image_url is not None:
        log = log.bind(image_url=body.image_url)

    decoded_bytes = base64.b64decode(image_b64, validate=True)

    if settings.local_ocr_enabled:
        isbn = local_isbn_scan(decoded_bytes)
        if isbn is not None:
            log.info("local OCR pre-pass hit", isbn=isbn)
            return AnalyzeResponse(
                classification=_CLF_BOOK,
                confidence=1.0,
                books=[ExtractedBook(potential_isbns=[isbn], confidence=1.0)],
                model_used="local_ocr",
            )

    client: VisionClient = request.app.state.vision_client

    # Resize for VLM ONCE — the same downsized b64 is reused for the
    # classify and (if needed) extract calls. OCR needs full resolution
    # to decode barcodes; the VLM does not and inference scales with
    # pixel count, so 672px-max cuts Modal time materially.
    vlm_b64 = _resize_for_vlm(image_b64)

    # STEP 1 — Classify (strict gate, no pressure to populate `books`).
    log.info("calling vision model for classify")
    classify_parsed = await client.classify(vlm_b64)
    classification, confidence = _parse_classification(classify_parsed)

    # Short-circuit on anything that isn't a confident BOOK. The earlier
    # `_ANALYZE_PROMPT` consolidation tried to preserve partial-signal
    # extraction on AMBIGUOUS; in practice that surfaced confident wrong
    # identifications because the model reused cover-art cues without a
    # strict gate. AMBIGUOUS now joins NOT_BOOK in returning empty books.
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
            model_used=settings.model_name,
        )

    # STEP 2 — Extract (only on confirmed BOOK).
    # `excluded_books` carries the cumulative list of "Title by Author"
    # identifications the user has already rejected for this image via the
    # frontend's "No, try again" loop. The VisionModel.extract method
    # appends a constraint clause to the extract prompt when the list is
    # non-empty; an empty list leaves the prompt at its baseline.
    log.info(
        "calling vision model for extract",
        excluded_books_count=len(body.excluded_books),
    )
    extract_parsed = await client.extract(
        [vlm_b64],
        excluded_books=list(body.excluded_books),
    )
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
        model_used=settings.model_name,
    )


@app.post(
    "/classify",
    response_model=ClassifyResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def classify(request: Request, body: ClassifyRequest) -> ClassifyResponse:
    log = logger.bind(endpoint="/classify")

    # --- image_url path ---
    if body.image_url is not None:
        log = log.bind(image_url=body.image_url)
        image_bytes = await _download_image(body.image_url)
        image_b64 = base64.b64encode(image_bytes).decode()
    else:
        # --- base64 image path ---
        if body.image is None:
            raise _vision_error(
                _ERR_NO_IMAGE_SUPPLIED, "Either 'image' or 'image_url' must be provided"
            )
        try:
            decoded = base64.b64decode(body.image, validate=True)
        except Exception as exc:
            raise _vision_error(_ERR_UNDECODABLE_IMAGE, "Image is not valid base64") from exc
        if len(decoded) > settings.max_image_size_bytes:
            raise _vision_error(
                _ERR_IMAGE_TOO_LARGE,
                f"Image exceeds max size of {settings.max_image_size_bytes} bytes",
            )
        image_b64 = body.image

    client: VisionClient = request.app.state.vision_client
    log.info("calling vision model for classification")
    parsed: dict[str, object] = await client.classify(image_b64)

    raw_ml = str(parsed.get("classification", "ambiguous"))
    classification = _ML_TO_CLASSIFICATION.get(raw_ml, _CLF_AMBIGUOUS)

    raw_confidence = parsed.get("confidence", 0.0)
    confidence = float(raw_confidence) if isinstance(raw_confidence, int | float) else 0.0
    confidence = max(0.0, min(1.0, confidence))

    reasoning = parsed.get("reasoning")
    log.info(
        "classification complete",
        classification=classification,
        reasoning=reasoning,
    )
    return ClassifyResponse(
        classification=classification,
        confidence=confidence,
        model_used=settings.model_name,
    )
