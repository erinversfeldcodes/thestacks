import base64
import hashlib
import hmac
import json
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


def _mock_together_response(content: dict[str, object]) -> dict[str, object]:
    return {"choices": [{"message": {"content": json.dumps(content)}}]}


def test_classify_returns_book_classification() -> None:
    mock_output = _mock_together_response({"classification": "book", "confidence": 0.95})
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
    assert data["classification"] == "book"
    assert data["model_used"] == settings.model_name


def test_classify_returns_not_book_classification() -> None:
    mock_output = _mock_together_response({"classification": "not_book", "confidence": 0.88})
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
    assert data["classification"] == "not_book"


def test_classify_confidence_is_between_0_and_1() -> None:
    mock_output = _mock_together_response({"classification": "ambiguous", "confidence": 0.5})
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


def test_classify_unknown_classification_falls_back_to_ambiguous() -> None:
    """Unknown classification string from model should default to ambiguous."""
    mock_output = _mock_together_response({"classification": "unknown_value", "confidence": 0.3})
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
    assert data["classification"] == "ambiguous"
