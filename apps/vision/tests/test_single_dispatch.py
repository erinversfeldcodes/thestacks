"""R0 — the single-dispatch (one Modal round-trip) path and its guard.

The two-call path keeps its coverage in test_analyze.py. This covers what R0
adds: the sidecar-side book-decision (the bunny-screenshot guard, now a pure
function) and the front door's handling of the collapsed `analyze` result.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import time
from typing import Any
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()


def _header(path: str = "/analyze") -> dict[str, str]:
    ts = str(int(time.time()))
    token = hmac.new(
        settings.hmac_secret.encode(), f"{ts}.POST.{path}".encode(), hashlib.sha256
    ).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token}"}


class TestBookDecisionGuard:
    """⛔ THE BUNNY-SCREENSHOT GUARD, unit-tested where it now lives. `analyze`
    extracts ONLY when this is true, so a non-book never reaches the extract
    prompt. It must agree with main.py's `_ML_TO_CLASSIFICATION` ({"book": ...})."""

    def test_only_book_triggers_extract(self) -> None:
        from modal_app import _classification_is_book

        assert _classification_is_book({"classification": "book"}) is True
        # Everything else — the non-book cases — must NOT extract.
        for raw in ("not_book", "ambiguous", "", "BOOKISH", "a book"):
            assert _classification_is_book({"classification": raw}) is False, raw

    def test_agrees_with_the_front_door_mapping(self) -> None:
        # The one raw value the front door maps to a book must be the one the
        # guard extracts on — or the two sides drift (extract a non-book, or
        # skip a book).
        from app.main import _CLF_BOOK, _ML_TO_CLASSIFICATION
        from modal_app import _classification_is_book

        book_raws = [r for r, v in _ML_TO_CLASSIFICATION.items() if v == _CLF_BOOK]
        assert book_raws == ["book"]
        assert _classification_is_book({"classification": book_raws[0]}) is True

    def test_missing_key_is_not_a_book(self) -> None:
        from modal_app import _classification_is_book

        assert _classification_is_book({}) is False


def _run(analyze_return: dict[str, object]) -> Any:
    with (
        patch.object(settings, "single_dispatch", True),
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=analyze_return,
        ) as mock_analyze,
        # the two-call methods must NOT be used on this path
        patch(
            "app.services.vision_client.VisionClient.classify", new_callable=AsyncMock
        ) as mock_classify,
        patch(
            "app.services.vision_client.VisionClient.extract", new_callable=AsyncMock
        ) as mock_extract,
        TestClient(app) as client,
    ):
        resp = client.post("/analyze", json={"image": _VALID_IMAGE}, headers=_header())
        assert mock_analyze.await_count == 1, "single dispatch must call analyze once"
        mock_classify.assert_not_called()
        mock_extract.assert_not_called()
    assert resp.status_code == 200
    return resp.json()


class TestSingleDispatchHandler:
    def test_book_surfaces_the_extracted_books(self) -> None:
        data = _run(
            {
                "classify": {"classification": "book", "confidence": 0.95},
                "extract": {
                    "books": [
                        {
                            "title": "The Great Gatsby",
                            "author": "F. Scott Fitzgerald",
                            "potential_isbns": ["9780743273565"],
                            "raw_text": None,
                            "confidence": 0.9,
                        }
                    ]
                },
            }
        )
        assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
        assert data["books"][0]["potential_isbns"] == ["9780743273565"]

    def test_not_book_short_circuits_with_no_books(self) -> None:
        # The sidecar returns extract=None for a non-book; the front door must
        # short-circuit to BOOKs=[] and NOT_BOOK, not crash on the None.
        data = _run(
            {"classify": {"classification": "not_book", "confidence": 0.92}, "extract": None}
        )
        assert data["classification"] == "CLASSIFICATION_RESULT_NOT_BOOK"
        assert data["books"] == []

    def test_book_with_empty_extraction(self) -> None:
        data = _run(
            {"classify": {"classification": "book", "confidence": 0.85}, "extract": {"books": []}}
        )
        assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
        assert data["books"] == []
        assert data["model_used"] == settings.model_name
