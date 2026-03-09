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


def _mock_together_response(content: dict[str, object]) -> dict[str, object]:
    return {"choices": [{"message": {"content": json.dumps(content)}}]}


def test_extract_returns_books_list() -> None:
    """Happy path: single book returned inside books list."""
    mock_output = _mock_together_response(
        {
            "books": [
                {
                    "title": "The Name of the Rose",
                    "author": "Umberto Eco",
                    "potential_isbns": ["9780156001311"],
                    "raw_text": "The Name of the Rose Umberto Eco ISBN 9780156001311",
                }
            ]
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
    assert "books" in data
    assert len(data["books"]) == 1
    book = data["books"][0]
    assert book["title"] == "The Name of the Rose"
    assert book["author"] == "Umberto Eco"
    assert "9780156001311" in book["potential_isbns"]
    assert data["model_used"] == settings.model_name


def test_extract_returns_multiple_books() -> None:
    """Multi-book response: model identifies 2+ books, all appear in books list."""
    mock_output = _mock_together_response(
        {
            "books": [
                {
                    "title": "The Name of the Rose",
                    "author": "Umberto Eco",
                    "potential_isbns": ["9780156001311"],
                    "raw_text": "The Name of the Rose",
                },
                {
                    "title": "Foucault's Pendulum",
                    "author": "Umberto Eco",
                    "potential_isbns": ["9780156032971"],
                    "raw_text": "Foucault's Pendulum",
                },
            ]
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
    assert len(data["books"]) == 2
    titles = [b["title"] for b in data["books"]]
    assert "The Name of the Rose" in titles
    assert "Foucault's Pendulum" in titles


def test_extract_returns_empty_books_list_when_nothing_extractable() -> None:
    """Empty books list (not an error) when model finds nothing."""
    mock_output = _mock_together_response({"books": []})
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
    assert data["books"] == []


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


def test_extract_with_oversized_image_returns_422() -> None:
    """Image whose decoded size exceeds max_image_size_bytes should be rejected with 422."""
    with patch("app.main.settings.max_image_size_bytes", 1), TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": [_VALID_IMAGE]},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_with_non_json_model_output_returns_empty_books() -> None:
    """Non-JSON model output should not raise — books falls back to empty list."""
    mock_output = {"choices": [{"message": {"content": "not valid json at all"}}]}
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
    assert data["books"] == []


def test_extract_partial_book_fields_are_returned() -> None:
    """Book entries missing optional fields should use None/[] defaults, not error."""
    mock_output = _mock_together_response(
        {"books": [{"title": "Only a Title", "raw_text": "Some text only"}]}
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
    assert len(data["books"]) == 1
    book = data["books"][0]
    assert book["title"] == "Only a Title"
    assert book["author"] is None
    assert book["potential_isbns"] == []


def test_extract_model_returns_non_list_books_field_gives_empty() -> None:
    """If the model returns books as a non-list (malformed), fall back to empty list."""
    mock_output = _mock_together_response({"books": "not a list"})
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
    assert data["books"] == []
