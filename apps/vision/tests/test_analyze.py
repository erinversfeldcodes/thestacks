"""Tests for the /analyze endpoint — consolidated classify + extract.

/analyze now runs classification + extraction in a SINGLE Modal inference
via `VisionClient.analyze`. These tests verify:

- BOOK classification → response includes books extracted in the same call
- NOT_BOOK classification → books is forced to [] regardless of model output
- AMBIGUOUS classification → books is forced to []
- Input validation: missing image/image_url → 422
- HMAC auth is enforced (delegated to the same verify_hmac plug)

Local OCR pre-pass is disabled by pointing `local_ocr_enabled` at False
within each test (when needed). The default test settings already have
local OCR disabled in conftest.
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
    """Happy path: single analyze call yields classification + books."""
    analyze_output = {
        "classification": "book",
        "confidence": 0.95,
        "books": [
            {
                "title": "The Great Gatsby",
                "author": "F. Scott Fitzgerald",
                "potential_isbns": ["9780743273565"],
                "raw_text": None,
                "confidence": 0.9,
            }
        ],
    }
    with (
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyze_output,
        ) as mock_analyze,
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
    # Exactly ONE Modal invocation — the whole point of the consolidation.
    assert mock_analyze.await_count == 1


def test_analyze_forces_empty_books_on_not_book() -> None:
    """NOT_BOOK classification → books is [] even if model returned data.

    The prompt asks the model for `books: []` on non-books, but we enforce
    it defensively on the server side — model output is a guideline, not a
    wire contract.
    """
    analyze_output = {
        "classification": "not_book",
        "confidence": 0.92,
        # Model misbehaves and returns data anyway — we must discard it.
        "books": [{"title": "hallucinated", "author": "x", "potential_isbns": []}],
    }
    with (
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyze_output,
        ) as mock_analyze,
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
    assert mock_analyze.await_count == 1


def test_analyze_preserves_books_on_ambiguous() -> None:
    """AMBIGUOUS classification → books are preserved.

    The prompt instructs the model to extract partial signal (a half-visible
    ISBN, one legible word of a title) on ambiguous covers so enrichment
    downstream can still attempt resolution. Only confident `not_book` forces
    `books: []` on the wire.
    """
    analyze_output = {
        "classification": "ambiguous",
        "confidence": 0.45,
        "books": [
            {
                "title": "partial title",
                "author": "",
                "confidence": 0.3,
                "potential_isbns": ["9780000000000"],
                "raw_text": "partial title",
            }
        ],
    }
    with (
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyze_output,
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
    assert data["classification"] == "CLASSIFICATION_RESULT_AMBIGUOUS"
    assert len(data["books"]) == 1
    assert data["books"][0]["title"] == "partial title"
    assert data["books"][0]["potential_isbns"] == ["9780000000000"]


def test_analyze_with_empty_extraction_returns_empty_books() -> None:
    """BOOK classification + zero extractable candidates → empty books list.

    The pipeline's "we think it's a book but couldn't read it" case. Core
    maps this to :isbn_not_found.
    """
    analyze_output: dict[str, object] = {
        "classification": "book",
        "confidence": 0.85,
        "books": [],
    }
    with (
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyze_output,
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
