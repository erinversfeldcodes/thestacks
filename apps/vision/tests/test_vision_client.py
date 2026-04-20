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


def _make_modal_mock(return_value: dict[str, object]) -> MagicMock:
    """Build a mock modal.Cls handle whose method.remote.aio() returns return_value."""
    aio_mock = AsyncMock(return_value=return_value)
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.extract = method_mock
    instance_mock.classify = method_mock
    instance_mock.analyze = method_mock
    cls_mock = MagicMock(return_value=instance_mock)
    return cls_mock


async def test_extract_returns_dict(client: VisionClient) -> None:
    """Successful Modal call returns the result dict directly."""
    cls_mock = _make_modal_mock({"books": [{"title": "Test Book", "author": "Test Author"}]})
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.extract([_VALID_IMAGE])
    assert "books" in result
    books = result["books"]
    assert isinstance(books, list)
    assert books[0]["title"] == "Test Book"


async def test_classify_returns_dict(client: VisionClient) -> None:
    """Successful Modal call returns the result dict directly."""
    cls_mock = _make_modal_mock({"classification": "book", "confidence": 0.95})
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.classify(_VALID_IMAGE)
    assert result["classification"] == "book"
    assert result["confidence"] == 0.95


async def test_extract_timeout_returns_504(client: VisionClient) -> None:
    """Modal timeout surfaces as 504."""
    aio_mock = AsyncMock(side_effect=TimeoutError())
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
    aio_mock = AsyncMock(side_effect=TimeoutError())
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


async def test_analyze_returns_dict(client: VisionClient) -> None:
    """Successful Modal call returns the combined classify+extract payload."""
    cls_mock = _make_modal_mock(
        {
            "classification": "book",
            "confidence": 0.95,
            "books": [{"title": "Test", "potential_isbns": ["9780000000002"]}],
        }
    )
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.analyze(_VALID_IMAGE)
    assert result["classification"] == "book"
    books = result["books"]
    assert isinstance(books, list)
    assert books[0]["potential_isbns"] == ["9780000000002"]


async def test_analyze_timeout_returns_504(client: VisionClient) -> None:
    """Modal timeout on analyze surfaces as 504."""
    aio_mock = AsyncMock(side_effect=TimeoutError())
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.analyze = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.analyze(_VALID_IMAGE)
    assert exc_info.value.status_code == 504


async def test_analyze_remote_error_returns_502(client: VisionClient) -> None:
    """Modal remote execution failure on analyze surfaces as 502."""
    aio_mock = AsyncMock(side_effect=RuntimeError("container crashed"))
    method_mock = MagicMock()
    method_mock.remote.aio = aio_mock
    instance_mock = MagicMock()
    instance_mock.analyze = method_mock
    cls_mock = MagicMock(return_value=instance_mock)

    with (
        patch.object(client, "_modal_cls", cls_mock),
        pytest.raises(HTTPException) as exc_info,
    ):
        await client.analyze(_VALID_IMAGE)
    assert exc_info.value.status_code == 502


async def test_analyze_non_dict_returns_safe_default(client: VisionClient) -> None:
    """Defensive fallback: non-dict Modal result → ambiguous + empty books."""
    cls_mock = _make_modal_mock({})
    # Override so method.remote.aio returns a non-dict sentinel.
    cls_mock.return_value.analyze.remote.aio = AsyncMock(return_value="oops")
    with patch.object(client, "_modal_cls", cls_mock):
        result = await client.analyze(_VALID_IMAGE)
    assert result == {"classification": "ambiguous", "confidence": 0.0, "books": []}
