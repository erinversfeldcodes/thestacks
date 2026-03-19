"""Utility for downloading remote images with size and timeout constraints."""

import httpx
from fastapi import HTTPException

_DOWNLOAD_TIMEOUT_SECONDS = 10.0
_MAX_IMAGE_BYTES = 10_485_760  # 10 MB
_MAX_SIZE_MSG = f"Remote image exceeds maximum allowed size of {_MAX_IMAGE_BYTES} bytes"


async def download_image(url: str) -> bytes:
    """Download an image from *url*.

    Raises ``HTTPException`` (422) if the response body exceeds 10 MB.
    Raises ``HTTPException`` (504) if the request times out.
    Raises ``HTTPException`` (502) if the download fails for any other reason.
    """
    try:
        async with (
            httpx.AsyncClient(timeout=_DOWNLOAD_TIMEOUT_SECONDS) as client,
            client.stream("GET", url) as response,
        ):
            response.raise_for_status()
            chunks: list[bytes] = []
            total = 0
            async for chunk in response.aiter_bytes():
                total += len(chunk)
                if total > _MAX_IMAGE_BYTES:
                    raise HTTPException(status_code=422, detail=_MAX_SIZE_MSG)
                chunks.append(chunk)
            return b"".join(chunks)
    except HTTPException:
        raise
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=504, detail="Timed out downloading remote image") from exc
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Failed to download remote image: HTTP {exc.response.status_code}",
        ) from exc
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"Failed to download remote image: {exc}"
        ) from exc
