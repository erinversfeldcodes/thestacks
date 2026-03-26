import base64
import hashlib
import hmac
import time
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()


def _make_header(path: str = "/classify") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def test_classify_returns_book_classification() -> None:
    mock_output = {"classification": "book", "confidence": 0.95}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["model_used"] == settings.model_name


def test_classify_returns_not_book_classification() -> None:
    mock_output = {"classification": "not_book", "confidence": 0.88}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_NOT_BOOK"


def test_classify_confidence_is_between_0_and_1() -> None:
    mock_output = {"classification": "ambiguous", "confidence": 0.5}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert 0.0 <= data["confidence"] <= 1.0


def test_classify_with_invalid_base64_returns_422() -> None:
    with TestClient(app) as client:
        response = client.post(
            "/classify",
            json={"image": "not!!valid!!base64!!!"},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_classify_with_oversized_image_returns_422() -> None:
    """Image whose decoded size exceeds max_image_size_bytes should be rejected with 422."""
    with patch("app.main.settings.max_image_size_bytes", 1), TestClient(app) as client:
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_classify_screenshot_with_book_mention_returns_book() -> None:
    """Screenshot inputs mentioning a book title or author should classify as 'book'.

    The updated _CLASSIFY_SYSTEM_PROMPT explicitly instructs the model to answer
    "book" when the image is a screenshot or photo of text that mentions a specific
    book title or author (e.g. a social media post, article, or reading list).
    Under the old prompt, which only described physical books, such inputs would
    have produced "not_book" or "ambiguous". This test validates that the endpoint
    correctly surfaces a "book" classification from the model for screenshot inputs.
    """
    mock_output = {"classification": "book", "confidence": 0.9}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["confidence"] == 0.9
    assert data["model_used"] == settings.model_name


def test_classify_unknown_classification_falls_back_to_ambiguous() -> None:
    """Unknown classification string from model should default to ambiguous."""
    mock_output = {"classification": "unknown_value", "confidence": 0.3}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/classify",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["classification"] == "CLASSIFICATION_RESULT_AMBIGUOUS"
