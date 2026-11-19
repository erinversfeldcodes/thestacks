"""The cpu_only contract of /analyze: the CPU tiers answer with what they
read and the GPU is NEVER dispatched — core owns resolution and escalation.

The response makes no classification claim (classify is a GPU step), so
these tests also pin what a consumer may rely on: UNSPECIFIED classification
and tier on a miss, tier BARCODE with a checksum'd ISBN on a barcode hit.
"""

import base64
import hashlib
import hmac
import time
from collections.abc import Iterator
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.services.cover_text import CoverText

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()


def _make_header(path: str = "/analyze") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


@pytest.fixture(autouse=True)
def _cover_text_on() -> Iterator[None]:
    with patch.object(settings, "cover_text_enabled", True):
        yield


def test_cpu_only_never_dispatches_the_gpu() -> None:
    cover = CoverText(
        title="The Dispossessed",
        author=None,
        raw_text="THE DISPOSSESSED URSULA K LE GUIN",
        confidence=0.9,
        engine="tesseract",
    )
    with (
        patch("app.main.local_isbn_scan", return_value=None),
        patch("app.main.read_cover_text", return_value=cover),
        patch(
            "app.services.vision_client.VisionClient.analyze", new_callable=AsyncMock
        ) as gpu_analyze,
        patch(
            "app.services.vision_client.VisionClient.classify", new_callable=AsyncMock
        ) as gpu_classify,
        TestClient(app) as client,
    ):
        data = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE, "cpu_only": True},
            headers=_make_header(),
        ).json()

    # ⬛ THE CONTRACT: no GPU method was touched, on either dispatch shape.
    gpu_analyze.assert_not_called()
    gpu_classify.assert_not_called()

    # No classification claim, no tier claim — core must not route this
    # through the book/not-book branch.
    assert data["classification"] == "CLASSIFICATION_RESULT_UNSPECIFIED"
    assert data["tier"] == "ANALYSIS_TIER_UNSPECIFIED"
    assert data["books"] == []

    # But the read IS reported, unanswered, for core to resolve.
    assert data["ocr_attempt"]["raw_text"] == "THE DISPOSSESSED URSULA K LE GUIN"
    assert data["ocr_attempt"]["answered"] is False
    assert data["timings_ms"]["ocr"] is not None
    assert data["timings_ms"]["classify"] is None
    assert data["timings_ms"]["extract"] is None


def test_cpu_only_barcode_hit_still_answers_as_the_barcode_tier() -> None:
    with (
        patch("app.main.local_isbn_scan", return_value="9780156001311"),
        patch(
            "app.services.vision_client.VisionClient.analyze", new_callable=AsyncMock
        ) as gpu_analyze,
        TestClient(app) as client,
    ):
        data = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE, "cpu_only": True},
            headers=_make_header(),
        ).json()

    gpu_analyze.assert_not_called()
    # A checksum'd barcode is self-verifying: same final answer as every mode.
    assert data["tier"] == "ANALYSIS_TIER_BARCODE"
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["books"][0]["potential_isbns"] == ["9780156001311"]


def test_cpu_only_with_cover_text_disabled_reports_an_empty_pass() -> None:
    with (
        patch.object(settings, "cover_text_enabled", False),
        patch("app.main.local_isbn_scan", return_value=None),
        patch(
            "app.services.vision_client.VisionClient.analyze", new_callable=AsyncMock
        ) as gpu_analyze,
        TestClient(app) as client,
    ):
        data = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE, "cpu_only": True},
            headers=_make_header(),
        ).json()

    gpu_analyze.assert_not_called()
    assert data["ocr_attempt"] is None
    assert data["model_used"] == "cpu_only"


def test_a_request_without_the_flag_still_reaches_the_gpu() -> None:
    """ANTI-VACUITY for the suite: the same request minus cpu_only dispatches —
    so the three assertions above cannot be satisfied by a sidecar that lost
    its GPU path entirely."""
    analyzed = {
        "classify": {"classification": "book", "confidence": 0.9},
        "extract": {"books": []},
    }
    with (
        patch.object(settings, "single_dispatch", True),
        patch("app.main.local_isbn_scan", return_value=None),
        patch("app.main.read_cover_text", side_effect=AssertionError("unused")),
        patch.object(settings, "cover_text_enabled", False),
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyzed,
        ) as gpu_analyze,
        TestClient(app) as client,
    ):
        data = client.post("/analyze", json={"image": _VALID_IMAGE}, headers=_make_header()).json()

    gpu_analyze.assert_called_once()
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
