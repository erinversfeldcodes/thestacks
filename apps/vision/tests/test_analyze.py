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
    """/analyze must be HMAC-gated — it is the only authenticated endpoint left."""
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


# ─────────────────────────────────────────────────────────────────────────────
# The normalisation the deletion kept and the deletion's tests took with them.
#
# `_parse_classification` and `_parse_extracted_books` say in their own
# docstrings that they are "carried over from the removed endpoint's inline
# parsing". The CODE survived; its tests went with `test_classification.py` and
# `test_extraction.py`. What was lost: the enum fallback, the confidence clamp,
# a non-list `books`, a non-dict item, partially-populated books, and more than
# one book.
#
# ⚠️ Coverage cannot see this gap. The clamp and the fallback are branchless
# single statements, so they are reported EXECUTED by every happy-path test
# while nothing asserts what they produce. And `/analyze` is now their only
# caller, so this is the response-shaping path for every upload in the product.
# ─────────────────────────────────────────────────────────────────────────────


def _analyze(classify_output: dict[str, object], extract_output: dict[str, object]):
    """POST /analyze with both model calls stubbed. Returns the response."""
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
        ),
        TestClient(app) as client,
    ):
        return client.post(
            "/analyze",
            json={"image": _VALID_IMAGE},
            headers=_make_header(),
        )


def test_unknown_classification_falls_back_to_ambiguous() -> None:
    """A label the model invents must not reach the response verbatim.

    Every surviving test passes "book", "not_book" or "ambiguous" — all direct
    hits in `_ML_TO_CLASSIFICATION`, so the `.get(raw_ml, _CLF_AMBIGUOUS)`
    default was asserted by nothing.
    """
    response = _analyze({"classification": "banana", "confidence": 0.5}, {"books": []})

    assert response.status_code == 200
    assert response.json()["classification"] == "CLASSIFICATION_RESULT_AMBIGUOUS"


def test_out_of_range_confidence_is_clamped() -> None:
    """Confidence is a 0-1 probability in the contract; the model is not bound by that.

    Surviving values were 0.95, 0.92, 0.45 and 0.85 — all already in range, so
    the clamp was executed on every run and asserted on none.
    """
    high = _analyze({"classification": "book", "confidence": 7}, {"books": []})
    assert high.status_code == 200
    assert high.json()["confidence"] == 1.0

    low = _analyze({"classification": "book", "confidence": -3}, {"books": []})
    assert low.status_code == 200
    assert low.json()["confidence"] == 0.0


def test_non_numeric_confidence_becomes_zero_rather_than_raising() -> None:
    """A string where a float belongs must not 500 the upload path."""
    response = _analyze({"classification": "book", "confidence": "very"}, {"books": []})

    assert response.status_code == 200
    assert response.json()["confidence"] == 0.0


def test_missing_classification_key_is_ambiguous() -> None:
    """An envelope with no `classification` at all — the shape a wrong mock produces."""
    response = _analyze({}, {"books": []})

    assert response.status_code == 200
    assert response.json()["classification"] == "CLASSIFICATION_RESULT_AMBIGUOUS"


def test_non_list_books_field_yields_no_books() -> None:
    """`books` as a string: the guard at the top of `_parse_extracted_books`."""
    response = _analyze({"classification": "book", "confidence": 0.9}, {"books": "not a list"})

    assert response.status_code == 200
    assert response.json()["books"] == []


def test_absent_books_key_yields_no_books() -> None:
    response = _analyze({"classification": "book", "confidence": 0.9}, {})

    assert response.status_code == 200
    assert response.json()["books"] == []


def test_non_dict_book_item_is_skipped_not_fatal() -> None:
    """One bad element must not lose the good ones beside it.

    This is the failure mode that has already cost this project an import page:
    a strict parse dropping a whole list over one malformed member.
    """
    response = _analyze(
        {"classification": "book", "confidence": 0.9},
        {"books": [None, {"title": "Survivor"}, "also not a dict"]},
    )

    assert response.status_code == 200
    books = response.json()["books"]
    assert [b["title"] for b in books] == ["Survivor"]


def test_partial_book_fields_are_coerced_rather_than_dropped() -> None:
    """Five `isinstance` coercions that no surviving test exercised.

    Every remaining test fed a fully-populated book dict, so a wrong type or a
    missing key never reached them.
    """
    response = _analyze(
        {"classification": "book", "confidence": 0.9},
        {
            "books": [
                {
                    "title": "Only a Title",
                    "author": 42,
                    "potential_isbns": "9780743273565",
                    "confidence": "high",
                }
            ]
        },
    )

    assert response.status_code == 200
    book = response.json()["books"][0]
    assert book["title"] == "Only a Title"
    assert book["author"] is None, "a non-string author must become None, not 42"
    assert book["potential_isbns"] == [], "a bare string is not a list of ISBNs"
    assert book["raw_text"] is None
    assert book["confidence"] is None, "a non-numeric confidence must become None"


def test_multiple_books_all_surface() -> None:
    """The loop never ran with more than one item in any surviving test, so a
    `List.head`-shaped bug would have looked entirely correct."""
    response = _analyze(
        {"classification": "book", "confidence": 0.9},
        {
            "books": [
                {"title": "First"},
                {"title": "Second"},
                {"title": "Third"},
            ]
        },
    )

    assert response.status_code == 200
    assert [b["title"] for b in response.json()["books"]] == ["First", "Second", "Third"]
