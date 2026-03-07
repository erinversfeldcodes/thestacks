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


def _make_header(path: str = "/extract") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _mock_together_response(content: dict) -> dict:  # type: ignore[type-arg]
    return {"choices": [{"message": {"content": json.dumps(content)}}]}


def test_extract_returns_structured_response() -> None:
    mock_output = _mock_together_response(
        {
            "title": "The Name of the Rose",
            "author": "Umberto Eco",
            "potential_isbns": ["9780156001311"],
            "raw_text": "The Name of the Rose Umberto Eco ISBN 9780156001311",
        }
    )
    with (
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/extract",
            json={"images": [_VALID_IMAGE]},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["title"] == "The Name of the Rose"
    assert data["author"] == "Umberto Eco"
    assert "9780156001311" in data["potential_isbns"]
    assert data["model_used"] == settings.model_name
    assert 0.0 <= data["confidence"] <= 1.0


def test_extract_with_invalid_base64_returns_422() -> None:
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": ["not!!valid!!base64!!!"]},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_with_too_many_images_returns_422() -> None:
    """More than 3 images should fail Pydantic validation."""
    images = [_VALID_IMAGE] * 4
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": images},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_with_empty_images_returns_422() -> None:
    """Empty images list should fail Pydantic validation."""
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": []},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_partial_model_output_is_returned() -> None:
    """Model output missing fields should result in None values, not an error."""
    mock_output = _mock_together_response({"raw_text": "Some text only"})
    with (
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value=mock_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/extract",
            json={"images": [_VALID_IMAGE]},
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["title"] is None
    assert data["author"] is None
    assert data["potential_isbns"] == []
