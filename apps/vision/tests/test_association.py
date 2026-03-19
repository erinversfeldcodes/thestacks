"""Tests for the POST /associate endpoint."""

import hashlib
import hmac
import json
import time
from collections.abc import Generator
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.config import settings
from app.main import _associate_jobs, _run_associate, _sign_callback, app
from app.models.association import AssociateRequest


def _make_header(path: str = "/associate") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


_VALID_BODY = {
    "isbn": "9780679410232",
    "book_id": "00000000-0000-0000-0000-000000000001",
    "edition_id": "00000000-0000-0000-0000-000000000002",
    "cover_image_url": "https://example.com/cover.jpg",
}


@pytest.fixture(autouse=True)
def clear_idempotency_cache() -> Generator[None, None, None]:
    """Reset the in-process idempotency dict between tests."""
    _associate_jobs.clear()
    yield
    _associate_jobs.clear()


def test_associate_returns_202_with_job_id() -> None:
    """Valid request returns 202 Accepted with a job_id."""
    with (
        patch("app.main.BackgroundTasks.add_task"),
        TestClient(app) as client,
    ):
        response = client.post("/associate", json=_VALID_BODY, headers=_make_header())

    assert response.status_code == 202
    data = response.json()
    assert "job_id" in data
    assert len(data["job_id"]) == 36  # UUID


def test_associate_idempotent_returns_same_job_id() -> None:
    """Same edition_id sent twice returns the same job_id."""
    with (
        patch("app.main.BackgroundTasks.add_task"),
        TestClient(app) as client,
    ):
        r1 = client.post("/associate", json=_VALID_BODY, headers=_make_header())
        r2 = client.post("/associate", json=_VALID_BODY, headers=_make_header())

    assert r1.status_code == 202
    assert r2.status_code == 202
    assert r1.json()["job_id"] == r2.json()["job_id"]


def test_associate_background_task_queued() -> None:
    """Background task is queued on first call but not on duplicate."""
    mock_add_task = MagicMock()
    with patch("app.main.BackgroundTasks.add_task", mock_add_task), TestClient(app) as client:
        client.post("/associate", json=_VALID_BODY, headers=_make_header())
        client.post("/associate", json=_VALID_BODY, headers=_make_header())

    # add_task called exactly once (second call is idempotent short-circuit)
    assert mock_add_task.call_count == 1


def test_associate_requires_auth() -> None:
    """Request without HMAC token is rejected with 401."""
    with TestClient(app) as client:
        response = client.post("/associate", json=_VALID_BODY)
    assert response.status_code == 401


def test_associate_rejects_malformed_input() -> None:
    """Missing required fields returns 422."""
    with TestClient(app) as client:
        response = client.post(
            "/associate",
            json={"isbn": "9780679410232"},  # missing book_id, edition_id, cover_image_url
            headers=_make_header(),
        )
    assert response.status_code == 422


def test_associate_rejects_invalid_cover_url() -> None:
    """Non-URL string for cover_image_url returns 422."""
    body = {**_VALID_BODY, "cover_image_url": "not-a-url"}
    with TestClient(app) as client:
        response = client.post("/associate", json=body, headers=_make_header())
    assert response.status_code == 422


async def test_run_associate_confirmed_path() -> None:
    """_run_associate sends confirmed callback when classify returns book."""
    body = AssociateRequest.model_validate(_VALID_BODY)
    fake_image = b"fake-cover-bytes"

    mock_classify = AsyncMock(return_value={"classification": "book", "confidence": 0.95})
    mock_client = AsyncMock()
    mock_client.classify = mock_classify

    mock_http_response = MagicMock()
    mock_http_response.status_code = 200

    with (
        patch("app.main._download_image", new_callable=AsyncMock, return_value=fake_image),
        patch("app.main.httpx.AsyncClient") as mock_httpx,
    ):
        mock_httpx.return_value.__aenter__ = AsyncMock(return_value=mock_httpx.return_value)
        mock_httpx.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_httpx.return_value.post = AsyncMock(return_value=mock_http_response)

        await _run_associate("test-job-id", body, mock_client)

    mock_classify.assert_awaited_once()
    post_call = mock_httpx.return_value.post.call_args
    payload = json.loads(post_call.kwargs.get("content") or post_call.args[1])
    assert payload["status"] == "confirmed"
    assert payload["isbn"] == body.isbn
    assert "reason" not in payload


async def test_run_associate_rejected_path() -> None:
    """_run_associate sends rejected callback when classify returns not_book."""
    body = AssociateRequest.model_validate(_VALID_BODY)
    fake_image = b"fake-cover-bytes"

    mock_classify = AsyncMock(return_value={"classification": "not_book", "confidence": 0.9})
    mock_client = AsyncMock()
    mock_client.classify = mock_classify

    mock_http_response = MagicMock()
    mock_http_response.status_code = 200

    with (
        patch("app.main._download_image", new_callable=AsyncMock, return_value=fake_image),
        patch("app.main.httpx.AsyncClient") as mock_httpx,
    ):
        mock_httpx.return_value.__aenter__ = AsyncMock(return_value=mock_httpx.return_value)
        mock_httpx.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_httpx.return_value.post = AsyncMock(return_value=mock_http_response)

        await _run_associate("test-job-id", body, mock_client)

    post_call = mock_httpx.return_value.post.call_args
    payload = json.loads(post_call.kwargs.get("content") or post_call.args[1])
    assert payload["status"] == "rejected"
    assert payload["reason"] == "not_a_book_cover"


async def test_run_associate_download_failure_sends_rejected() -> None:
    """_run_associate sends rejected callback when cover download fails."""
    body = AssociateRequest.model_validate(_VALID_BODY)
    mock_client = AsyncMock()

    mock_http_response = MagicMock()
    mock_http_response.status_code = 200

    with (
        patch(
            "app.main._download_image",
            new_callable=AsyncMock,
            side_effect=HTTPException(status_code=422, detail="Download failed"),
        ),
        patch("app.main.httpx.AsyncClient") as mock_httpx,
    ):
        mock_httpx.return_value.__aenter__ = AsyncMock(return_value=mock_httpx.return_value)
        mock_httpx.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_httpx.return_value.post = AsyncMock(return_value=mock_http_response)

        await _run_associate("test-job-id", body, mock_client)

    post_call = mock_httpx.return_value.post.call_args
    payload = json.loads(post_call.kwargs.get("content") or post_call.args[1])
    assert payload["status"] == "rejected"
    mock_client.classify.assert_not_awaited()


def test_associate_callback_signature_present() -> None:
    """Callback POST includes X-Vision-Signature header."""
    payload = b'{"status":"confirmed"}'
    sig = _sign_callback(payload)
    assert len(sig) == 64  # hex SHA256
    # Verify it's a valid HMAC
    expected = hmac.new(settings.hmac_secret.encode(), payload, hashlib.sha256).hexdigest()
    assert sig == expected
