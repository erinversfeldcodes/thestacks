import asyncio
import base64
from typing import TypedDict, cast

import httpx
from fastapi import HTTPException

from app.config import settings

# Status codes that represent transient conditions worth retrying once.
_RETRYABLE_STATUS = {429, 500, 502, 503, 504}
_MAX_RETRIES = 2
_RETRY_BASE_DELAY = 1.0  # seconds; doubles each attempt (1 s, 2 s)


def _image_mime_type(b64_data: str) -> str:
    """Detect image MIME type from the first bytes of the base64-encoded data."""
    try:
        header = base64.b64decode(b64_data[:16], validate=False)
        if header[:8] == b"\x89PNG\r\n\x1a\n":
            return "image/png"
        if header[:3] == b"GIF":
            return "image/gif"
        if header[:4] == b"RIFF" and header[8:12] == b"WEBP":
            return "image/webp"
    except Exception:
        pass
    return "image/jpeg"


_TOGETHER_API_URL = "https://api.together.xyz/v1/chat/completions"


class _TogetherMessage(TypedDict):
    content: str


class _TogetherChoice(TypedDict):
    message: _TogetherMessage


class TogetherResponse(TypedDict):
    choices: list[_TogetherChoice]


_EXTRACT_SYSTEM_PROMPT = (
    "Extract all books visible or mentioned in this image. For each book, return its title, "
    "author name, and any ISBN numbers visible. If the image is a screenshot of text "
    "(social media post, article, reading list), extract all books mentioned in the text. "
    "Return JSON with field: books (array of objects, each with: title, author, "
    "potential_isbns (array of strings), raw_text). "
    'If no books can be identified, return {"books": []}.'
)

_CLASSIFY_SYSTEM_PROMPT = (
    "Does this image contain enough information to identify a book?\n\n"
    'Answer "book" if: the image shows a physical book (cover, spine, back, or barcode), '
    "OR the image is a screenshot or photo of text that mentions a specific book title or "
    "author.\n\n"
    'Answer "not_book" if: the image has no book-related content whatsoever (a pet, food, '
    "a landscape, a selfie with no book context).\n\n"
    'Answer "ambiguous" if: there is some possible book-related content but not enough '
    "to attempt identification.\n\n"
    'Return JSON: {"classification": "book" | "not_book" | "ambiguous", '
    '"confidence": 0.0-1.0}'
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
                "image_url": {"url": f"data:{_image_mime_type(img)};base64,{img}"},
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
                        "image_url": {"url": f"data:{_image_mime_type(image)};base64,{image}"},
                    }
                ],
            },
        ]
        return await self._call_api(messages)

    async def _call_api(self, messages: list[dict[str, object]]) -> TogetherResponse:
        """Send a request to Together AI chat completions endpoint.

        Retries up to _MAX_RETRIES times on transient errors (rate limits,
        upstream 5xx) with exponential backoff. Uses response_format=json_object
        to guarantee the model returns valid JSON rather than markdown-wrapped output.
        """
        payload: dict[str, object] = {
            "model": settings.model_name,
            "messages": messages,
            # Enforce JSON output — eliminates code-fence wrapping and parse failures.
            "response_format": {"type": "json_object"},
            # temperature=0 makes sampling deterministic, eliminating result variance
            # between retries and test runs. Either the model can identify the book or
            # it can't — we don't want random variation obscuring that signal.
            "temperature": 0,
        }
        headers = {
            "Authorization": f"Bearer {settings.together_api_key}",
            "Content-Type": "application/json",
        }

        last_exc: Exception | None = None
        for attempt in range(_MAX_RETRIES + 1):
            try:
                response = await self._client.post(_TOGETHER_API_URL, json=payload, headers=headers)
                if response.status_code in _RETRYABLE_STATUS and attempt < _MAX_RETRIES:
                    delay = _RETRY_BASE_DELAY * (2**attempt)
                    await asyncio.sleep(delay)
                    continue
                response.raise_for_status()
                return cast(TogetherResponse, response.json())
            except httpx.TimeoutException as exc:
                if attempt < _MAX_RETRIES:
                    await asyncio.sleep(_RETRY_BASE_DELAY * (2**attempt))
                    last_exc = exc
                    continue
                raise HTTPException(
                    status_code=504, detail="Vision model request timed out"
                ) from exc
            except httpx.HTTPStatusError as exc:
                body = exc.response.text[:500]
                raise HTTPException(
                    status_code=502,
                    detail=f"Vision model returned error: {exc.response.status_code} — {body}",
                ) from exc
            except httpx.HTTPError as exc:
                if attempt < _MAX_RETRIES:
                    await asyncio.sleep(_RETRY_BASE_DELAY * (2**attempt))
                    last_exc = exc
                    continue
                raise HTTPException(status_code=502, detail="Vision model request failed") from exc

        # Exhausted retries on a non-HTTPStatusError (timeout or network error).
        raise HTTPException(
            status_code=502, detail="Vision model request failed after retries"
        ) from last_exc

    async def close(self) -> None:
        await self._client.aclose()
