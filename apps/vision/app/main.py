import base64
import json
import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

import structlog
from fastapi import Depends, FastAPI, HTTPException, Request

from app.config import settings
from app.models.classification import Classification, ClassificationRequest, ClassificationResponse
from app.models.extraction import ExtractionRequest, ExtractionResponse
from app.services.hmac_auth import verify_hmac
from app.services.vision_client import TogetherResponse, VisionClient

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


app = FastAPI(title="The Stacks Vision Sidecar", version="0.1.0", lifespan=lifespan, debug=False)


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

    client: VisionClient = request.app.state.vision_client
    log.info("calling vision model for extraction")
    raw_output: TogetherResponse = await client.extract(body.images)

    try:
        content = raw_output["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        content = ""
    parsed: dict[str, object] = {}
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        parsed = {}

    log.info("extraction complete")
    return ExtractionResponse(
        title=parsed.get("title") if isinstance(parsed.get("title"), str) else None,  # type: ignore[arg-type]
        author=parsed.get("author") if isinstance(parsed.get("author"), str) else None,  # type: ignore[arg-type]
        potential_isbns=parsed.get("potential_isbns")  # type: ignore[arg-type]
        if isinstance(parsed.get("potential_isbns"), list)
        else [],
        raw_text=content or None,
        model_used=settings.model_name,
        # confidence is 0.0 for the VLM path — the model does not return an extraction confidence.
        # Phase 1D.2 (local OCR pre-pass) will populate this field when a barcode is detected
        # with high confidence, allowing Phoenix to skip ISBN verification for clean scans.
        # Only /classify produces a meaningful confidence from the current model.
        confidence=0.0,
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
    raw_output: TogetherResponse = await client.classify(body.image)

    try:
        content = raw_output["choices"][0]["message"]["content"]
    except (KeyError, IndexError):
        content = ""
    parsed: dict[str, object] = {}
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        parsed = {}

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
