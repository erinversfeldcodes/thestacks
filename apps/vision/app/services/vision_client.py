from typing import TypedDict, cast

import httpx
from fastapi import HTTPException

from app.config import settings

_TOGETHER_API_URL = "https://api.together.xyz/v1/chat/completions"


class _TogetherMessage(TypedDict):
    content: str


class _TogetherChoice(TypedDict):
    message: _TogetherMessage


class TogetherResponse(TypedDict):
    choices: list[_TogetherChoice]


_EXTRACT_SYSTEM_PROMPT = (
    "Extract the book title, author name, and any ISBN numbers visible in this image. "
    "Return JSON with fields: title, author, potential_isbns (array), raw_text."
)

_CLASSIFY_SYSTEM_PROMPT = (
    "Classify this image. Is it a book? "
    "Return JSON with fields: classification (one of: book, not_book, ambiguous), "
    "confidence (0.0-1.0)."
)


class VisionClient:
    """HTTP client for Together AI vision model.

    Security note: the Authorization header constructed in _call_api contains
    the together_api_key. Never pass the headers dict to any logger — log only
    the request method, path, and status code if needed.
    """

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(
            timeout=settings.request_timeout_seconds,
            # Single outbound host (Together AI). Pool sized for low-concurrency sidecar use.
            limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
        )

    async def extract(self, images: list[str]) -> TogetherResponse:
        """Call Together AI to extract text from images. Returns raw model output."""
        image_content: list[dict[str, object]] = [
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{img}"},
            }
            for img in images
        ]
        messages: list[dict[str, object]] = [
            {"role": "system", "content": _EXTRACT_SYSTEM_PROMPT},
            {"role": "user", "content": image_content},
        ]
        return await self._call_api(messages)

    async def classify(self, image: str) -> TogetherResponse:
        """Call Together AI to classify if image is a book."""
        messages: list[dict[str, object]] = [
            {"role": "system", "content": _CLASSIFY_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                    }
                ],
            },
        ]
        return await self._call_api(messages)

    async def _call_api(self, messages: list[dict[str, object]]) -> TogetherResponse:
        """Send a request to Together AI chat completions endpoint."""
        payload = {
            "model": settings.model_name,
            "messages": messages,
        }
        headers = {
            "Authorization": f"Bearer {settings.together_api_key}",
            "Content-Type": "application/json",
        }
        try:
            response = await self._client.post(_TOGETHER_API_URL, json=payload, headers=headers)
            response.raise_for_status()
            return cast(TogetherResponse, response.json())
        except httpx.TimeoutException as exc:
            raise HTTPException(status_code=504, detail="Vision model request timed out") from exc
        except httpx.HTTPStatusError as exc:
            raise HTTPException(
                status_code=502,
                detail=f"Vision model returned error: {exc.response.status_code}",
            ) from exc
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail="Vision model request failed") from exc

    async def close(self) -> None:
        await self._client.aclose()
