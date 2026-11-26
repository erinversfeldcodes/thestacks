"""The route contract of POST /extract-document — the document-to-text parser
for writing-assistant ingestion, on the CPU front door with NO GPU dispatch.

Unlike the /embed tests (which mock the 2.3GB embedder), these drive the REAL
parsers against the committed public-domain anthology fixtures — the whole
point is to prove each format's bytes actually come out as text. The fixtures
at e2e/fixtures/public-domain-writing/anthology.{txt,md,docx,epub,pdf} are the
same content in five formats; every one must surface the Shakespeare sentinel.
The parser libs (pymupdf / python-docx / ebooklib) must be installed in the
venv for these to run.

What is pinned: each format extracts text containing the sentinel with an
honest char_count; the HMAC gate (401, and the parser is never reached); and
the two deterministic MALFORMED rejections (unknown format, empty content).
"""

import base64
import hashlib
import hmac
import time
from pathlib import Path
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

# The sentence that appears, identically, in every format of the anthology.
_SENTINEL = "Shall I compare thee to a summer's day?"

# Repo root is four parents up: tests -> vision -> apps -> <root>.
_FIXTURE_DIR = Path(__file__).resolve().parents[3] / "e2e" / "fixtures" / "public-domain-writing"

_FORMATS = ["txt", "md", "pdf", "docx", "epub"]


def _make_header(path: str = "/extract-document") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _fixture_b64(fmt: str) -> str:
    raw = (_FIXTURE_DIR / f"anthology.{fmt}").read_bytes()
    return base64.b64encode(raw).decode()


@pytest.mark.parametrize("fmt", _FORMATS)
def test_extract_document_surfaces_the_sentinel_for_every_format(
    client: TestClient, fmt: str
) -> None:
    """Each of the five formats decodes to plain text carrying the sentinel, with
    a char_count that equals the returned text length and is plainly non-trivial
    (the anthology is well over a thousand characters in every format)."""
    resp = client.post(
        "/extract-document",
        json={"content": _fixture_b64(fmt), "format": fmt},
        headers=_make_header(),
    )

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert _SENTINEL in data["text"], f"{fmt}: sentinel missing from extracted text"
    # char_count is len(text), the caller's cheap pre-write check — never a
    # fabricated or zero value on a document that clearly parsed.
    assert data["char_count"] == len(data["text"])
    assert data["char_count"] > 1000, f"{fmt}: implausibly short extraction"


def test_extract_document_without_token_returns_401_and_never_parses() -> None:
    """HMAC gates /extract-document exactly as it gates /analyze and /embed. The
    parser is an AssertionError here, so if auth ever let the request through the
    test fails on the 401 assertion rather than silently parsing."""
    with (
        patch(
            "app.main.extract_document",
            side_effect=AssertionError("auth must gate /extract-document before the parser"),
        ) as parser,
        TestClient(app) as unauthed,
    ):
        resp = unauthed.post(
            "/extract-document",
            json={"content": _fixture_b64("txt"), "format": "txt"},
        )

    assert resp.status_code == 401
    parser.assert_not_called()


def test_extract_document_with_unparseable_token_returns_401() -> None:
    with TestClient(app) as unauthed:
        resp = unauthed.post(
            "/extract-document",
            json={"content": _fixture_b64("txt"), "format": "txt"},
            headers={"X-Internal-Token": "not-a-valid-token"},
        )

    assert resp.status_code == 401


def test_extract_document_rejects_unknown_format_as_malformed(client: TestClient) -> None:
    """A format outside the supported set cannot be made valid by resending, so
    it is a deterministic MALFORMED_REQUEST — not a 200 and not a 500."""
    resp = client.post(
        "/extract-document",
        json={"content": _fixture_b64("txt"), "format": "rtf"},
        headers=_make_header(),
    )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VISION_ERROR_CODE_MALFORMED_REQUEST"


def test_extract_document_rejects_empty_content_as_malformed() -> None:
    """Empty content is rejected before the parser is ever woken — resending an
    empty document cannot make it valid."""
    with (
        patch(
            "app.main.extract_document",
            side_effect=AssertionError("must not parse empty content"),
        ) as parser,
        TestClient(app) as client,
    ):
        resp = client.post(
            "/extract-document",
            json={"content": "", "format": "txt"},
            headers=_make_header(),
        )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VISION_ERROR_CODE_MALFORMED_REQUEST"
    parser.assert_not_called()


def test_extract_document_rejects_undecodable_base64_as_malformed() -> None:
    """Content that is not valid base64 is a deterministic MALFORMED_REQUEST, and
    the parser is never reached with garbage bytes."""
    with (
        patch(
            "app.main.extract_document",
            side_effect=AssertionError("must not parse undecodable content"),
        ) as parser,
        TestClient(app) as client,
    ):
        resp = client.post(
            "/extract-document",
            json={"content": "not valid base64 !!!", "format": "txt"},
            headers=_make_header(),
        )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VISION_ERROR_CODE_MALFORMED_REQUEST"
    parser.assert_not_called()
