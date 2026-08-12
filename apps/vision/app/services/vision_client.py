import asyncio
import os

import modal
from fastapi import HTTPException

from app.config import settings

_DEFAULT_APP_NAME = "thestacks-vision"


class VisionClient:
    """Calls the Modal-hosted Qwen2.5-VL model for classification and
    extraction. Credentials: MODAL_TOKEN_ID/SECRET env vars. The target app
    name comes from MODAL_APP_NAME (injected at deploy), so preview
    deployments call their own GPU class, not production's. One method per
    Modal-side VisionModel method (``classify``, ``extract``); the
    ``/analyze`` endpoint orchestrates the two-call flow.
    """

    def __init__(self) -> None:
        app_name = os.environ.get("MODAL_APP_NAME", _DEFAULT_APP_NAME)
        self._modal_cls = modal.Cls.from_name(app_name, "VisionModel")

    async def extract(
        self,
        images: list[str],
        excluded_books: list[str] | None = None,
    ) -> dict[str, object]:
        """Run the extract Modal method.

        ``excluded_books`` forwards the rejection-retry list ("Title by Author"
        strings the user has already rejected on a prior identification of
        this image) through to ``VisionModel.extract``, which appends a
        constraint clause to the extract prompt. ``None`` or an empty list
        leaves the baseline prompt unchanged.
        """
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.extract.remote.aio(images, excluded_books or []),
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
