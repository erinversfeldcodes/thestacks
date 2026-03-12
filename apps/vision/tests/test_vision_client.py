import asyncio
from collections.abc import AsyncGenerator
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from app.services.vision_client import VisionClient

_VALID_IMAGE = "dGVzdA=="  # base64("test")


@pytest.fixture
async def client() -> AsyncGenerator[VisionClient, None]:
    c = VisionClient()
    yield c
    await c.close()


def _make_modal_mock(return_value: dict) -> MagicMock:
    """Build a mock modal.Cls handle whose method.remote.aio() returns return_value."""
    aio_mock = AsyncMock(return_value=return_value)
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.extract = method_mock
    instance_mock.classify = method_mock
    cls_mock = MagicMock(return_value=instance_mock)
    return cls_mock


async def test_extract_returns_wrapped_response(client: VisionClient) -> None:
    """Successful Modal call is wrapped in the TogetherResponse envelope."""
    cls_mock = _make_modal_mock({"books": [{"title": "Test Book", "author": "Test Author"}]})
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.extract([_VALID_IMAGE])
    assert "choices" in result
    assert result["choices"][0]["message"]["content"]


async def test_classify_returns_wrapped_response(client: VisionClient) -> None:
    """Successful Modal call is wrapped in the TogetherResponse envelope."""
    cls_mock = _make_modal_mock({"classification": "book", "confidence": 0.95})
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.classify(_VALID_IMAGE)
    assert "choices" in result


async def test_extract_timeout_returns_504(client: VisionClient) -> None:
    """Modal timeout surfaces as 504."""
    aio_mock = AsyncMock(side_effect=asyncio.TimeoutError())
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.extract = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.extract([_VALID_IMAGE])
    assert exc_info.value.status_code == 504


async def test_classify_timeout_returns_504(client: VisionClient) -> None:
    """Modal timeout on classify surfaces as 504."""
    aio_mock = AsyncMock(side_effect=asyncio.TimeoutError())
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.classify = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.classify(_VALID_IMAGE)
    assert exc_info.value.status_code == 504


async def test_extract_remote_error_returns_502(client: VisionClient) -> None:
    """Modal remote execution failure surfaces as 502."""
    aio_mock = AsyncMock(side_effect=RuntimeError("container crashed"))
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.extract = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.extract([_VALID_IMAGE])
    assert exc_info.value.status_code == 502


async def test_classify_remote_error_returns_502(client: VisionClient) -> None:
    """Modal remote execution failure on classify surfaces as 502."""
    aio_mock = AsyncMock(side_effect=RuntimeError("container crashed"))
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.classify = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.classify(_VALID_IMAGE)
    assert exc_info.value.status_code == 502
