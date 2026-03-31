import base64
import hashlib
import hmac
import logging
import time
import uuid
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import httpx
import structlog
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from app.config import settings
from app.proto.gen.vision import (
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

# In-memory idempotency set: edition_id → job_id.
# Cleared on restart; acceptable for async best-effort semantics.
_associate_jobs: dict[str, str] = {}

_ASSOCIATE_CALLBACK_PATH = "/api/internal/vision/associate"

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
            detail = f"Image URL redirected (HTTP {resp.status_code}); redirects not permitted"
            raise HTTPException(status_code=422, detail=detail)
        if resp.status_code != 200:
            raise HTTPException(
                status_code=422,
                detail=f"Failed to download image from URL: HTTP {resp.status_code}",
            )
        chunks: list[bytes] = []
        total = 0
        async for chunk in resp.aiter_bytes(chunk_size=65536):
            total += len(chunk)
            if total > _MAX_DOWNLOAD_BYTES:
                raise HTTPException(
                    status_code=422,
                    detail=f"Image URL exceeds max size of {_MAX_DOWNLOAD_BYTES} bytes",
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
        raise HTTPException(
            status_code=422, detail="Provide either 'images' or 'image_url', not both"
        )
    if len(body.images) > 3:
        raise HTTPException(status_code=422, detail="'images' must contain at most 3 items")

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
            raise HTTPException(
                status_code=422, detail="Either 'images' or 'image_url' must be provided"
            )
        log = log.bind(image_count=len(body.images))

        for idx, img in enumerate(body.images):
            try:
                decoded = base64.b64decode(img, validate=True)
            except Exception as exc:
                raise HTTPException(
                    status_code=422, detail=f"Image at index {idx} is not valid base64"
                ) from exc
            if len(decoded) > settings.max_image_size_bytes:
                raise HTTPException(
                    status_code=422,
                    detail=f"Image at index {idx} exceeds max size of {settings.max_image_size_bytes} bytes",  # noqa: E501
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
        raise HTTPException(
            status_code=422,
            detail="isbn, book_id, edition_id, and cover_image_url are required",
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
            raise HTTPException(
                status_code=422, detail="Either 'image' or 'image_url' must be provided"
            )
        try:
            decoded = base64.b64decode(body.image, validate=True)
        except Exception as exc:
            raise HTTPException(status_code=422, detail="Image is not valid base64") from exc
        if len(decoded) > settings.max_image_size_bytes:
            raise HTTPException(
                status_code=422,
                detail=f"Image exceeds max size of {settings.max_image_size_bytes} bytes",
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
