import base64
import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import structlog
from fastapi import Depends, FastAPI, HTTPException, Request

from app.config import settings
from app.models.classification import Classification, ClassificationRequest, ClassificationResponse
from app.models.extraction import ExtractedBook, ExtractionRequest, ExtractionResponse
from app.services.hmac_auth import verify_hmac
from app.services.local_ocr import local_isbn_scan
from app.services.vision_client import VisionClient

structlog.configure(
    wrapper_class=structlog.make_filtering_bound_logger(
        logging.getLevelName(settings.log_level.upper())
    ),
)

logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    app.state.vision_client = VisionClient()
    yield
    await app.state.vision_client.close()


app = FastAPI(title="The Stacks Vision Service", version="0.1.0", lifespan=lifespan, debug=False)


@app.get("/health", status_code=200)
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "vision", "environment": settings.environment}


@app.post(
    "/extract",
    response_model=ExtractionResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def extract(request: Request, body: ExtractionRequest) -> ExtractionResponse:
    log = logger.bind(endpoint="/extract", image_count=len(body.images))

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

    # Local OCR pre-pass: attempt barcode decode before calling VLM.
    if settings.local_ocr_enabled:
        first_decoded = base64.b64decode(body.images[0], validate=True)
        isbn = local_isbn_scan(first_decoded)
        if isbn is not None:
            log.info("local OCR pre-pass hit", isbn=isbn)
            return ExtractionResponse(
                books=[
                    ExtractedBook(
                        potential_isbns=[isbn],
                        confidence=1.0,
                    )
                ],
                model_used="local_ocr",
            )

    client: VisionClient = request.app.state.vision_client
    log.info("calling vision model for extraction")
    parsed: dict[str, object] = await client.extract(body.images)

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
                    # confidence is 0.0 for the VLM path — the model does not return an
                    # extraction confidence. Phase 1D.2 (local OCR pre-pass) will populate
                    # this field when a barcode is detected with high confidence, allowing
                    # Phoenix to skip ISBN verification for clean scans.
                    confidence=0.0,
                )
            )

    log.info("extraction complete", book_count=len(books))
    return ExtractionResponse(
        books=books,
        model_used=settings.model_name,
    )


@app.post(
    "/classify",
    response_model=ClassificationResponse,
    status_code=200,
    dependencies=[Depends(verify_hmac)],
)
async def classify(request: Request, body: ClassificationRequest) -> ClassificationResponse:
    log = logger.bind(endpoint="/classify")

    try:
        decoded = base64.b64decode(body.image, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=422, detail="Image is not valid base64") from exc
    if len(decoded) > settings.max_image_size_bytes:
        raise HTTPException(
            status_code=422,
            detail=f"Image exceeds max size of {settings.max_image_size_bytes} bytes",
        )

    client: VisionClient = request.app.state.vision_client
    log.info("calling vision model for classification")
    parsed: dict[str, object] = await client.classify(body.image)

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
