"""/analyze two-call flow tests: BOOK -> extract invoked, books surface;
NOT_BOOK and AMBIGUOUS -> short-circuit, extract NEVER called, books []
(deliberately unlike the old single-pass behaviour, which preserved
partial-signal books on ambiguity). Also covers the OCR pre-pass
skipping classify on a clean barcode.
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
    """Happy path: classify=book → extract is called and books surface."""
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
    assert mock_classify.await_count == 1
    assert mock_extract.await_count == 1


def test_analyze_short_circuits_on_not_book() -> None:
    """NOT_BOOK classification → extract is NEVER called; books is [].

    Load-bearing contract for the screenshot_bunny.jpg regression — the
    single-pass merge previously returned BOOK with empty books on this
    fixture, surfacing the wrong error message to the user. The strict
    classify gate restores the dfef1333 behaviour.
    """
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
    assert mock_classify.await_count == 1
    mock_extract.assert_not_called()


def test_analyze_short_circuits_on_ambiguous() -> None:
    """AMBIGUOUS classification → extract is NEVER called; books is [].

    Decision (2026-05): treat AMBIGUOUS as a short-circuit rather than
    extracting partial-signal candidates. The intermediate single-pass
    behaviour preserved ambiguous extractions, which empirically led to
    confident wrong identifications (e.g. rotated covers). When classify
    can't tell, the cost of a confident-wrong extract outweighs the value
    of a low-confidence partial hit.
    """
    classify_output = {"classification": "ambiguous", "confidence": 0.45}
    with (
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
            return_value=classify_output,
        ) as mock_classify,
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
    assert mock_classify.await_count == 1
    mock_extract.assert_not_called()


def test_analyze_with_empty_extraction_returns_empty_books() -> None:
    """BOOK classification + zero extractable candidates → empty books list.

    The pipeline's "we think it's a book but couldn't read it" case. Core
    maps this to :isbn_not_found. ``model_used`` must remain the VLM model
    name — only the local OCR short-circuit reports ``local_ocr``.
    """
    classify_output = {"classification": "book", "confidence": 0.85}
    extract_output: dict[str, object] = {"books": []}
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
    assert data["books"] == []
    assert data["model_used"] == settings.model_name
    assert mock_extract.await_count == 1


def test_analyze_local_ocr_short_circuit_skips_vlm() -> None:
    """A clean barcode decode short-circuits the VLM entirely.

    Neither classify nor extract should be invoked. ``model_used`` is
    ``local_ocr`` and confidence is pinned to 1.0 (ISBN barcodes carry a
    checksum, so a successful decode is effectively zero-false-positive).
    """
    with (
        patch(
            "app.main.local_isbn_scan",
            create=True,
            return_value="9780156001311",
        ) as mock_scan,
        patch(
            "app.services.vision_client.VisionClient.classify",
            new_callable=AsyncMock,
        ) as mock_classify,
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
    assert data["classification"] == "CLASSIFICATION_RESULT_BOOK"
    assert data["model_used"] == "local_ocr"
    assert data["confidence"] == 1.0
    assert len(data["books"]) == 1
    assert data["books"][0]["potential_isbns"] == ["9780156001311"]
    assert data["books"][0]["confidence"] == 1.0
    mock_scan.assert_called()
    mock_classify.assert_not_called()
    mock_extract.assert_not_called()


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


def test_analyze_with_excluded_books_appends_constraint() -> None:
    """`excluded_books` is forwarded to VisionClient.extract as a kwarg.

    The Modal-side VisionModel.extract is responsible for appending the
    constraint clause to the prompt — at the FastAPI layer we verify that
    the list arrives intact on the underlying client call. This guards the
    rejection-retry wiring without coupling the assertion to the exact
    Modal-side prompt template.
    """
    classify_output = {"classification": "book", "confidence": 0.95}
    extract_output: dict[str, object] = {"books": []}
    excluded = ["Foo by Bar", "Baz by Qux"]
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
        ) as mock_extract,
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE, "excluded_books": excluded},
            headers=_make_header(),
        )

    assert response.status_code == 200
    assert mock_extract.await_count == 1
    call = mock_extract.await_args
    assert call is not None
    assert call.kwargs.get("excluded_books") == excluded


def test_analyze_empty_excluded_books_passes_empty_list() -> None:
    """When `excluded_books` is omitted, the request reaches VisionClient.extract
    with an empty list (the baseline / unconstrained prompt path).

    The proto default for the repeated field is an empty list, so the
    request body without the key arrives as ``excluded_books=[]`` at the
    handler. We verify the empty list is forwarded so the Modal-side
    branch that appends the constraint is NOT taken.
    """
    classify_output = {"classification": "book", "confidence": 0.85}
    extract_output: dict[str, object] = {"books": []}
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
        ) as mock_extract,
        TestClient(app) as client,
    ):
        response = client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )

    assert response.status_code == 200
    assert mock_extract.await_count == 1
    call = mock_extract.await_args
    assert call is not None
    assert call.kwargs.get("excluded_books") == []
