import asyncio

import modal
from fastapi import HTTPException

from app.config import settings


class VisionClient:
    """Calls the Modal-hosted Qwen2.5-VL model for book classification and extraction.

    Credentials are read from MODAL_TOKEN_ID / MODAL_TOKEN_SECRET env vars (set as
    Fly secrets on the core app, or from ~/.modal.toml in local dev).
    """

    def __init__(self) -> None:
        self._modal_cls = modal.Cls.from_name("thestacks-vision", "VisionModel")

    async def extract(self, images: list[str]) -> dict:
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.extract.remote.aio(images),
                timeout=float(settings.request_timeout_seconds),
            )
        except asyncio.TimeoutError as exc:
            raise HTTPException(
                status_code=504, detail="Vision model request timed out"
            ) from exc
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Vision model request failed: {exc}"
            ) from exc
        return result if isinstance(result, dict) else {"books": []}

    async def classify(self, image: str) -> dict:
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.classify.remote.aio(image),
                timeout=float(settings.request_timeout_seconds),
            )
        except asyncio.TimeoutError as exc:
            raise HTTPException(
                status_code=504, detail="Vision model request timed out"
            ) from exc
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Vision model request failed: {exc}"
            ) from exc
        return (
            result
            if isinstance(result, dict)
            else {"classification": "ambiguous", "confidence": 0.0}
        )

    async def close(self) -> None:
        pass  # Modal client manages its own connection lifecycle
