import asyncio
import os

import modal
from fastapi import HTTPException

from app.config import settings

_DEFAULT_APP_NAME = "thestacks-vision"


class VisionClient:
    """Calls the Modal-hosted Qwen2.5-VL model for book classification and extraction.

    Credentials are read from MODAL_TOKEN_ID / MODAL_TOKEN_SECRET env vars (set as
    Fly secrets on the core app, or from ~/.modal.toml in local dev).

    The target Modal app name is read from MODAL_APP_NAME (injected by modal_app.py
    as a Secret.from_dict at deploy time). This allows ephemeral preview deployments
    to call their own GPU class rather than the production one.
    """

    def __init__(self) -> None:
        app_name = os.environ.get("MODAL_APP_NAME", _DEFAULT_APP_NAME)
        self._modal_cls = modal.Cls.from_name(app_name, "VisionModel")

    async def extract(self, images: list[str]) -> dict[str, object]:
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.extract.remote.aio(images),
                timeout=float(settings.request_timeout_seconds),
            )
        except TimeoutError as exc:
            raise HTTPException(status_code=504, detail="Vision model request timed out") from exc
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Vision model request failed: {exc}"
            ) from exc
        return result if isinstance(result, dict) else {"books": []}

    async def classify(self, image: str) -> dict[str, object]:
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.classify.remote.aio(image),
                timeout=float(settings.request_timeout_seconds),
            )
        except TimeoutError as exc:
            raise HTTPException(status_code=504, detail="Vision model request timed out") from exc
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
