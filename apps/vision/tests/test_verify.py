"""Tests for the /verify endpoint — selective same-book verification.

Issue #169: when /analyze returns a low-confidence book candidate, core
calls /verify with the user's uploaded image plus a candidate cover URL
fetched from Open Library / Google Books. The endpoint downloads both,
runs orientation correction on the uploaded image only (the candidate is
assumed upright from its canonical source), and asks the VLM whether
both images depict the same book.

These tests verify:

- Happy path: positive judgement → is_same_book=True, expected confidence.
- Negative path: negative judgement → is_same_book=False.
- HMAC enforcement (same plug as the other endpoints).
- Defensive parsing of malformed model output → well-formed VerifyResponse.
- Confidence clamping to [0.0, 1.0].
- Reasoning truncation to 500 chars.
- Orientation correction runs on the UPLOADED image only.
- SSRF / image-download rejections surface as 422.
"""

import hashlib
import hmac
import time
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

_UPLOADED_URL = "https://example.com/uploaded.jpg"
_CANDIDATE_URL = "https://covers.openlibrary.org/b/isbn/9780743273565-L.jpg"
_CANDIDATE_ISBN = "9780743273565"
_FAKE_IMAGE_BYTES = b"\x89PNG\r\n\x1a\nfake-image-data"


def _make_header(path: str = "/verify") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _body(**overrides: str) -> dict[str, str]:
    base = {
        "uploaded_image_url": _UPLOADED_URL,
        "candidate_cover_url": _CANDIDATE_URL,
        "candidate_isbn": _CANDIDATE_ISBN,
    }
    base.update(overrides)
    return base


def test_verify_positive_judgement_returns_is_same_book_true() -> None:
    """Happy path: VLM says it's the same book → is_same_book=True."""
    verify_output = {
        "is_same_book": True,
        "confidence": 0.92,
        "reasoning": "Title and author text match on both covers.",
    }
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ) as mock_verify,
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["is_same_book"] is True
    assert data["confidence"] == 0.92
    assert "Title and author" in data["reasoning"]
    assert mock_verify.await_count == 1


def test_verify_negative_judgement_returns_is_same_book_false() -> None:
    """Negative path: VLM says different books → is_same_book=False."""
    verify_output = {
        "is_same_book": False,
        "confidence": 0.95,
        "reasoning": "Titles differ and cover art is unrelated.",
    }
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["is_same_book"] is False
    assert data["confidence"] == 0.95


def test_verify_rejects_missing_hmac() -> None:
    """/verify must be HMAC-gated identically to /analyze."""
    with TestClient(app) as client:
        response = client.post("/verify", json=_body())
    assert response.status_code in (401, 403)


def test_verify_malformed_model_output_yields_safe_defaults() -> None:
    """An empty dict from the VLM must still produce a well-formed VerifyResponse.

    Defensive parse: model misbehaviour must NOT break the wire contract.
    Expected: is_same_book=False, confidence=0.0, reasoning="".
    """
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value={},
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    data = response.json()
    assert data["is_same_book"] is False
    assert data["confidence"] == 0.0
    assert data["reasoning"] == ""


def test_verify_clamps_confidence_above_one() -> None:
    """Confidence values >1.0 from the model must be clamped to 1.0."""
    verify_output = {
        "is_same_book": True,
        "confidence": 1.5,  # impossible — clamp expected
        "reasoning": "ok",
    }
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    assert response.json()["confidence"] == 1.0


def test_verify_clamps_confidence_below_zero() -> None:
    """Negative confidence values must be clamped to 0.0."""
    verify_output = {
        "is_same_book": False,
        "confidence": -0.4,
        "reasoning": "ok",
    }
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    assert response.json()["confidence"] == 0.0


def test_verify_truncates_long_reasoning_to_500_chars() -> None:
    """Reasoning longer than 500 chars must be truncated to 500."""
    long_reasoning = "x" * 1000
    verify_output = {
        "is_same_book": True,
        "confidence": 0.8,
        "reasoning": long_reasoning,
    }
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    assert len(response.json()["reasoning"]) == 500


def test_verify_orientation_correction_runs_on_uploaded_image_only() -> None:
    """orientation.correct must be called with the uploaded image bytes,
    and only once — the candidate cover from OL/GB is assumed upright."""
    uploaded_bytes = b"UPLOADED-BYTES"
    candidate_bytes = b"CANDIDATE-BYTES"

    async def fake_download(url: str) -> bytes:
        if url == _UPLOADED_URL:
            return uploaded_bytes
        return candidate_bytes

    verify_output = {"is_same_book": True, "confidence": 0.9, "reasoning": "ok"}

    with (
        patch(
            "app.main._download_image",
            new=AsyncMock(side_effect=fake_download),
        ),
        patch(
            "app.main.orientation.correct",
            return_value=uploaded_bytes,
        ) as mock_correct,
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value=verify_output,
        ),
        TestClient(app) as client,
    ):
        response = client.post(
            "/verify",
            json=_body(),
            headers=_make_header(),
        )

    assert response.status_code == 200
    # Single call, with uploaded bytes only.
    assert mock_correct.call_count == 1
    args, _ = mock_correct.call_args
    assert args[0] == uploaded_bytes
    # And NEVER called with the candidate cover bytes.
    for call in mock_correct.call_args_list:
        assert call.args[0] != candidate_bytes


def test_verify_bad_uploaded_url_returns_422() -> None:
    """SSRF/scheme/size rejections on uploaded_image_url surface as 422."""
    with TestClient(app) as client:
        response = client.post(
            "/verify",
            json=_body(uploaded_image_url="ftp://nope.example.com/x.jpg"),
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_verify_bad_candidate_url_returns_422() -> None:
    """SSRF/scheme/size rejections on candidate_cover_url surface as 422."""
    with TestClient(app) as client:
        response = client.post(
            "/verify",
            json=_body(candidate_cover_url="ftp://nope.example.com/x.jpg"),
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_verify_does_not_leak_isbn_to_model() -> None:
    """The candidate_isbn must never reach the VLM — it's logging only.

    The VisionClient.verify call signature must NOT include the isbn.
    """
    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.main.orientation.correct",
            return_value=_FAKE_IMAGE_BYTES,
        ),
        patch(
            "app.services.vision_client.VisionClient.verify",
            new_callable=AsyncMock,
            return_value={"is_same_book": True, "confidence": 0.9, "reasoning": "ok"},
        ) as mock_verify,
        TestClient(app) as client,
    ):
        client.post("/verify", json=_body(), headers=_make_header())

    args, kwargs = mock_verify.call_args
    flattened = list(args) + list(kwargs.values())
    for value in flattened:
        assert _CANDIDATE_ISBN not in str(value)
