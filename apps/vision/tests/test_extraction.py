import base64
import hashlib
import hmac
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


def test_extract_returns_books_list() -> None:
    """Happy path: single book returned inside books list."""
    mock_output = {
        "books": [
            {
                "title": "The Name of the Rose",
                "author": "Umberto Eco",
                "potential_isbns": ["9780156001311"],
                "raw_text": "The Name of the Rose Umberto Eco ISBN 9780156001311",
            }
        ]
    }
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
    mock_output = {
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
    mock_output: dict[str, object] = {"books": []}
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
    """Model returning a dict with no 'books' key should not raise.

    Books falls back to empty list.
    """
    mock_output: dict[str, object] = {}
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
    mock_output = {"books": [{"title": "Only a Title", "raw_text": "Some text only"}]}
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
    mock_output: dict[str, object] = {"books": "not a list"}
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


# ---------------------------------------------------------------------------
# Integration tests: local OCR pre-pass in /extract endpoint
# ---------------------------------------------------------------------------


class TestExtractLocalOCRPrePass:
    """Integration tests for the local OCR pre-pass that short-circuits VLM.

    These tests use ``create=True`` on patches so they run before the
    production import / config field exists, producing assertion failures
    (not AttributeError during setup).
    """

    def test_prepass_hit_returns_local_ocr_model_and_confidence_1(self) -> None:
        """When local_isbn_scan finds an ISBN, /extract returns immediately.

        - model_used should be "local_ocr"
        - confidence should be 1.0
        - VLM should NOT be called
        """
        with (
            patch(
                "app.main.local_isbn_scan",
                create=True,
                return_value="9780156001311",
            ) as mock_scan,
            patch(
                "app.services.vision_client.VisionClient.extract",
                new_callable=AsyncMock,
            ) as mock_vlm,
            TestClient(app) as client,
        ):
            response = client.post(
                "/extract",
                json={"images": [_VALID_IMAGE]},
                headers=_make_header(),
            )

        assert response.status_code == 200
        data = response.json()
        assert data["model_used"] == "local_ocr"
        assert len(data["books"]) == 1
        assert data["books"][0]["confidence"] == 1.0
        assert "9780156001311" in data["books"][0]["potential_isbns"]
        mock_scan.assert_called()
        mock_vlm.assert_not_called()

    def test_prepass_miss_falls_through_to_vlm(self) -> None:
        """When local_isbn_scan returns None, /extract falls through to VLM."""
        mock_vlm_output = {
            "books": [
                {
                    "title": "The Name of the Rose",
                    "author": "Umberto Eco",
                    "potential_isbns": ["9780156001311"],
                    "raw_text": "The Name of the Rose",
                }
            ]
        }
        with (
            patch(
                "app.main.local_isbn_scan",
                create=True,
                return_value=None,
            ) as mock_scan,
            patch(
                "app.services.vision_client.VisionClient.extract",
                new_callable=AsyncMock,
                return_value=mock_vlm_output,
            ) as mock_vlm,
            TestClient(app) as client,
        ):
            response = client.post(
                "/extract",
                json={"images": [_VALID_IMAGE]},
                headers=_make_header(),
            )

        assert response.status_code == 200
        data = response.json()
        assert data["model_used"] == settings.model_name
        assert len(data["books"]) == 1
        assert data["books"][0]["title"] == "The Name of the Rose"
        mock_scan.assert_called()
        mock_vlm.assert_called_once()

    def test_prepass_disabled_skips_scan_and_calls_vlm(self) -> None:
        """When local_ocr_enabled=False, pre-pass is skipped entirely."""
        mock_vlm_output = {
            "books": [
                {
                    "title": "Foucault's Pendulum",
                    "author": "Umberto Eco",
                    "potential_isbns": ["9780156032971"],
                    "raw_text": "Foucault's Pendulum",
                }
            ]
        }
        # Pydantic Settings objects don't support patch.object with create=True
        # (delattr fails on teardown). Instead, temporarily set the attribute
        # via object.__setattr__ and restore it manually.
        _had_attr = hasattr(settings, "local_ocr_enabled")
        object.__setattr__(settings, "local_ocr_enabled", False)
        try:
            with (
                patch(
                    "app.main.local_isbn_scan",
                    create=True,
                    return_value="9780156032971",
                ) as mock_scan,
                patch(
                    "app.services.vision_client.VisionClient.extract",
                    new_callable=AsyncMock,
                    return_value=mock_vlm_output,
                ) as mock_vlm,
                TestClient(app) as client,
            ):
                response = client.post(
                    "/extract",
                    json={"images": [_VALID_IMAGE]},
                    headers=_make_header(),
                )
        finally:
            if _had_attr:
                object.__setattr__(settings, "local_ocr_enabled", True)
            else:
                object.__delattr__(settings, "local_ocr_enabled")

        assert response.status_code == 200
        data = response.json()
        assert data["model_used"] == settings.model_name
        mock_scan.assert_not_called()
        mock_vlm.assert_called_once()


# ---------------------------------------------------------------------------
# image_url path
# ---------------------------------------------------------------------------


def test_extract_image_url_happy_path() -> None:
    """image_url is downloaded and extraction runs successfully."""
    fake_bytes = b"fake-image-bytes"
    mock_vlm_output = {"books": [{"potential_isbns": ["9780679410232"], "confidence": 0.9}]}
    with (
        patch("app.main._download_image", new_callable=AsyncMock, return_value=fake_bytes),
        patch(
            "app.services.vision_client.VisionClient.extract",
            new_callable=AsyncMock,
            return_value=mock_vlm_output,
        ),
        patch("app.main.settings.local_ocr_enabled", False),
        TestClient(app) as client,
    ):
        response = client.post(
            "/extract",
            json={"image_url": "https://example.com/cover.jpg"},
            headers=_make_header(),
        )
    assert response.status_code == 200
    data = response.json()
    assert len(data["books"]) == 1


def test_extract_both_images_and_url_returns_422() -> None:
    """Providing both images and image_url is rejected."""
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": [_VALID_IMAGE], "image_url": "https://example.com/cover.jpg"},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_neither_images_nor_url_returns_422() -> None:
    """Providing neither images nor image_url is rejected."""
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_image_url_size_exceeded_returns_422() -> None:
    """image_url that exceeds the size limit is rejected with 422."""
    from fastapi import HTTPException

    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            side_effect=HTTPException(status_code=422, detail="Image URL exceeds max size"),
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/extract",
            json={"image_url": "https://example.com/huge.jpg"},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_image_url_download_timeout_returns_422() -> None:
    """image_url that times out is rejected with 422."""
    from fastapi import HTTPException

    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            side_effect=HTTPException(status_code=422, detail="Failed to download image"),
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/extract",
            json={"image_url": "https://example.com/slow.jpg"},
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_extract_image_url_requires_auth() -> None:
    """image_url path without auth token is rejected with 401."""
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"image_url": "https://example.com/cover.jpg"},
        )
    assert response.status_code == 401
