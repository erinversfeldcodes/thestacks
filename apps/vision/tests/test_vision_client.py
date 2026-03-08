import os

os.environ.setdefault("VISION_ENVIRONMENT", "test")

from unittest.mock import MagicMock, patch

import httpx
import pytest
from fastapi import HTTPException

from app.services.vision_client import VisionClient

_VALID_IMAGE = "dGVzdA=="  # base64("test")


@pytest.fixture
async def client() -> VisionClient:
    c = VisionClient()
    yield c
    await c.close()


async def test_extract_timeout_returns_504(client: VisionClient) -> None:
    """Together AI timeout should surface as 504."""
    with (
        patch.object(client._client, "post", side_effect=httpx.TimeoutException("timed out")),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.extract([_VALID_IMAGE])
    assert exc_info.value.status_code == 504


async def test_extract_upstream_5xx_returns_502(client: VisionClient) -> None:
    """Together AI 5xx should surface as 502."""
    mock_response = MagicMock()
    mock_response.status_code = 503
    error = httpx.HTTPStatusError("upstream error", request=MagicMock(), response=mock_response)
    with (
        patch.object(client._client, "post", side_effect=error),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.extract([_VALID_IMAGE])
    assert exc_info.value.status_code == 502
    assert "503" in exc_info.value.detail


async def test_extract_network_error_returns_502(client: VisionClient) -> None:
    """Generic network error should surface as 502."""
    with (
        patch.object(client._client, "post", side_effect=httpx.HTTPError("connection failed")),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.extract([_VALID_IMAGE])
    assert exc_info.value.status_code == 502


async def test_classify_timeout_returns_504(client: VisionClient) -> None:
    """Together AI timeout on classify should surface as 504."""
    with (
        patch.object(client._client, "post", side_effect=httpx.TimeoutException("timed out")),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.classify(_VALID_IMAGE)
    assert exc_info.value.status_code == 504


async def test_classify_upstream_5xx_returns_502(client: VisionClient) -> None:
    """Together AI 5xx on classify should surface as 502."""
    mock_response = MagicMock()
    mock_response.status_code = 500
    error = httpx.HTTPStatusError("upstream error", request=MagicMock(), response=mock_response)
    with (
        patch.object(client._client, "post", side_effect=error),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.classify(_VALID_IMAGE)
    assert exc_info.value.status_code == 502
    assert "500" in exc_info.value.detail


async def test_classify_network_error_returns_502(client: VisionClient) -> None:
    """Generic network error on classify should surface as 502."""
    with (
        patch.object(client._client, "post", side_effect=httpx.HTTPError("connection failed")),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.classify(_VALID_IMAGE)
    assert exc_info.value.status_code == 502
