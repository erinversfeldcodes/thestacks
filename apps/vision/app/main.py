import base64
import io
import logging
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
    ExtractedBook,
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

_VLM_MAX_SIDE = 672
_VLM_JPEG_QUALITY = 85


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


_CLF_BOOK = "CLASSIFICATION_RESULT_BOOK"
_CLF_NOT_BOOK = "CLASSIFICATION_RESULT_NOT_BOOK"
_CLF_AMBIGUOUS = "CLASSIFICATION_RESULT_AMBIGUOUS"

_ML_TO_CLASSIFICATION: dict[str, str] = {
    "book": _CLF_BOOK,
    "not_book": _CLF_NOT_BOOK,
    "ambiguous": _CLF_AMBIGUOUS,
}


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    app.state.vision_client = VisionClient()
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
) -> str:
    """Resolve `image` (already base64) OR `image_url` (downloaded and re-encoded)
    into a single base64-encoded string. Raises HTTPException(422) for invalid
    input — carrying forward the validation semantics the removed /classify
    endpoint applied inline, factored out so /analyze can reuse them without
    duplication.
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

    vlm_b64 = _resize_for_vlm(image_b64)

    log.info("calling vision model for classify")
    classify_parsed = await client.classify(vlm_b64)
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
            model_used=settings.model_name,
        )

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
