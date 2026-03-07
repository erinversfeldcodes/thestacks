import httpx
from fastapi import HTTPException

from app.config import settings

_TOGETHER_API_URL = "https://api.together.xyz/v1/chat/completions"

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
    """HTTP client for Together AI vision model."""

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=settings.request_timeout_seconds)

    async def extract(self, images: list[str]) -> dict:  # type: ignore[type-arg]
        """Call Together AI to extract text from images. Returns raw model output."""
        image_content = [
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{img}"},
            }
            for img in images
        ]
        messages = [
            {"role": "system", "content": _EXTRACT_SYSTEM_PROMPT},
            {"role": "user", "content": image_content},
        ]
        return await self._call_api(messages)

    async def classify(self, image: str) -> dict:  # type: ignore[type-arg]
        """Call Together AI to classify if image is a book."""
        messages = [
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

    async def _call_api(self, messages: list[dict]) -> dict:  # type: ignore[type-arg]
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
            return response.json()  # type: ignore[no-any-return]
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
