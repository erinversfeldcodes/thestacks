import base64
import hashlib
import hmac
import json
import logging
import uuid
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import httpx
import structlog
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request

from app.config import settings
from app.models.association import AssociateRequest, AssociateResponse
from app.models.classification import Classification, ClassificationRequest, ClassificationResponse
from app.models.extraction import ExtractedBook, ExtractionRequest, ExtractionResponse
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
    validate_image_url(image_url)
    async with (
        httpx.AsyncClient(timeout=_DOWNLOAD_TIMEOUT, follow_redirects=False) as client,
        client.stream("GET", image_url) as resp,
    ):
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


def _sign_callback(payload: bytes) -> str:
    """Compute HMAC-SHA256 signature for a vision → core callback."""
    return hmac.new(
        settings.hmac_secret.encode(),
        payload,
        hashlib.sha256,
    ).hexdigest()


async def _run_associate(
    job_id: str,
    body: AssociateRequest,
    client: VisionClient,
) -> None:
    """Background task: classify cover, POST result to core callback."""
    log = logger.bind(job_id=job_id, edition_id=body.edition_id, isbn=body.isbn)

    reason: str | None
    try:
        image_bytes = await _download_image(str(body.cover_image_url))
    except HTTPException as exc:
        log.warning("associate: cover download failed", detail=exc.detail)
        status = "rejected"
        reason = exc.detail
        image_b64 = None
    else:
        image_b64 = base64.b64encode(image_bytes).decode()
        parsed = await client.classify(image_b64)
        raw = parsed.get("classification", "ambiguous")
        is_book = raw == "book"
        status = "confirmed" if is_book else "rejected"
        reason = None if is_book else "not_a_book_cover"
        log.info("associate: classification done", classification=raw, status=status)

    payload: dict[str, object] = {
        "isbn": body.isbn,
        "book_id": body.book_id,
        "edition_id": body.edition_id,
        "status": status,
        "job_id": job_id,
    }
    if reason:
        payload["reason"] = reason

    payload_bytes = json.dumps(payload, separators=(",", ":")).encode()
    signature = _sign_callback(payload_bytes)

    callback_url = f"{settings.effective_core_api_url}/api/internal/vision/associate"
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
    response_model=ExtractionResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def extract(request: Request, body: ExtractionRequest) -> ExtractionResponse:
    log = logger.bind(endpoint="/extract")

    # --- image_url path ---
    if body.image_url is not None:
        log = log.bind(image_url=str(body.image_url))
        image_bytes = await _download_image(str(body.image_url))
        image_b64 = base64.b64encode(image_bytes).decode()

        if settings.local_ocr_enabled:
            isbn = local_isbn_scan(image_bytes)
            if isbn is not None:
                log.info("local OCR pre-pass hit (url path)", isbn=isbn)
                return ExtractionResponse(
                    books=[ExtractedBook(potential_isbns=[isbn], confidence=1.0)],
                    model_used="local_ocr",
                )

        client: VisionClient = request.app.state.vision_client
        log.info("calling vision model for extraction (url path)")
        parsed = await client.extract([image_b64])
        images_for_model = [image_b64]
    else:
        # --- base64 images path ---
        if body.images is None:
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
                return ExtractionResponse(
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
            books.append(
                ExtractedBook(
                    title=title if isinstance(title, str) else None,
                    author=author if isinstance(author, str) else None,
                    potential_isbns=isbns if isinstance(isbns, list) else [],
                    raw_text=raw_text if isinstance(raw_text, str) else None,
                    confidence=0.0,
                )
            )

    log.info("extraction complete", book_count=len(books))
    return ExtractionResponse(books=books, model_used=settings.model_name)


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
    response_model=ClassificationResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def classify(request: Request, body: ClassificationRequest) -> ClassificationResponse:
    log = logger.bind(endpoint="/classify")

    # --- image_url path ---
    if body.image_url is not None:
        log = log.bind(image_url=str(body.image_url))
        image_bytes = await _download_image(str(body.image_url))
        image_b64 = base64.b64encode(image_bytes).decode()
    else:
        # --- base64 image path ---
        assert body.image is not None  # guaranteed by model_validator
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

    raw_classification = parsed.get("classification", "ambiguous")
    try:
        classification = Classification(raw_classification)
    except ValueError:
        classification = Classification.ambiguous

    raw_confidence = parsed.get("confidence", 0.0)
    confidence = float(raw_confidence) if isinstance(raw_confidence, int | float) else 0.0
    confidence = max(0.0, min(1.0, confidence))

    log.info("classification complete", classification=classification.value)
    return ClassificationResponse(
        classification=classification,
        confidence=confidence,
        model_used=settings.model_name,
    )
