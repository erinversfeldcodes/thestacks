"""Tests for the /analyze endpoint — consolidated classify + extract.

/analyze composes the classify and extract steps in a single HTTP round-trip,
short-circuiting the extract step when the classifier says NOT_BOOK. These
tests verify:

- BOOK classification → both classify + extract run, response includes books
- NOT_BOOK classification → extract is NOT called, books is []
- AMBIGUOUS classification → extract is NOT called, books is []
- Image URL and base64 input shapes both work
- Input validation: missing image/image_url → 422
- HMAC auth is enforced (delegated to the same verify_hmac plug)
"""

import base64
import hashlib
import hmac
import time
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()


def _make_header(path: str = "/analyze") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def test_analyze_returns_books_for_book_classification() -> None:
    """Happy path: classifier says BOOK → extract runs → response has both."""
    classify_output = {"classification": "book", "confidence": 0.95}
    extract_output = {
        "books": [
            {
                "title": "The Great Gatsby",
                "author": "F. Scott Fitzgerald",
                "potential_isbns": ["9780743273565"],
                "raw_text": None,
                "confidence": 0.9,
            }
        ]
    }
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=classify_output,
        ) as mock_classify,
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value=extract_output,
        ) as mock_extract,
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["confidence"] == 0.95
    assert len(data["books"]) == 1
    assert data["books"][0]["potential_isbns"] == ["9780743273565"]
    # Both underlying calls fired exactly once.
    assert mock_classify.await_count == 1
    assert mock_extract.await_count == 1


def test_analyze_short_circuits_on_not_book() -> None:
    """NOT_BOOK classification → extract is NOT called, books is empty."""
    classify_output = {"classification": "not_book", "confidence": 0.92}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=classify_output,
        ) as mock_classify,
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value={"books": []},
        ) as mock_extract,
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_NOT_BOOK"
    assert data["books"] == []
    # Crucial invariant: extract MUST NOT be invoked when classification != BOOK.
    # Compromising this defeats the whole cost optimisation of /analyze vs
    # running classify and extract in parallel.
    assert mock_classify.await_count == 1
    assert mock_extract.await_count == 0


def test_analyze_short_circuits_on_ambiguous() -> None:
    """AMBIGUOUS classification also skips extract — only BOOK triggers it."""
    classify_output = {"classification": "ambiguous", "confidence": 0.45}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=classify_output,
        ),
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
        ) as mock_extract,
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_AMBIGUOUS"
    assert data["books"] == []
    assert mock_extract.await_count == 0


def test_analyze_with_empty_extraction_returns_empty_books() -> None:
    """BOOK classification + zero extractable candidates → empty books list.

    This is the pipeline's "we think it's a book but couldn't read it" case.
    The core Moderation code maps this to :isbn_not_found.
    """
    classify_output = {"classification": "book", "confidence": 0.85}
    extract_output: dict[str, list[dict[str, object]]] = {"books": []}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=classify_output,
        ),
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value=extract_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["books"] == []


def test_analyze_missing_input_returns_422() -> None:
    """Neither image nor image_url provided — proto oneof validator rejects."""
    with TestClient(app) as client:
        response = client.post(
            "/analyze",
            json={},
            headers=_make_header(),
        )
    # Pydantic's oneof validator runs before our handler, returning 422.
    assert response.status_code == 422


def test_analyze_invalid_base64_returns_422() -> None:
    """`image` field must be valid base64."""
    with TestClient(app) as client:
        response = client.post(
            "/analyze",
            json={"image": "not-valid-base64!!!"},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_analyze_rejects_missing_hmac() -> None:
    """/analyze must be HMAC-gated — same as /classify and /extract."""
    with TestClient(app) as client:
        response = client.post("/analyze", json={"image": _VALID_IMAGE})
    assert response.status_code in (401, 403)
