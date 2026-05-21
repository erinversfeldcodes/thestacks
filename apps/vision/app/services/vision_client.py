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

    async def analyze(self, image: str) -> dict[str, object]:
        """Single-pass classify + extract via one Modal inference.

        Returns the combined payload shape documented on `_ANALYZE_PROMPT`
        in modal_app.py: `classification`, `confidence`, `reasoning`, `books`.
        The caller is responsible for normalising/validating the payload.
        """
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.analyze.remote.aio(image),
                timeout=float(settings.request_timeout_seconds),
            )
        except TimeoutError as exc:
            raise HTTPException(status_code=504, detail="Vision model request timed out") from exc
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Vision model request failed: {exc}"
            ) from exc
        if not isinstance(result, dict):
            return {"classification": "ambiguous", "confidence": 0.0, "books": []}
        return result

    async def verify(self, uploaded_b64: str, candidate_b64: str) -> dict[str, object]:
        """Two-image same-book comparison via Modal `VisionModel.verify`.

        Both inputs are base64-encoded PNG/JPEG bytes. Returns the parsed
        payload shape documented on `_VERIFY_PROMPT` in modal_app.py:
        `is_same_book`, `confidence`, `reasoning`.

        The candidate ISBN passed by the caller of /verify is logging-only —
        it never reaches this method or the VLM.
        """
        try:
            model = self._modal_cls()
            result = await asyncio.wait_for(
                model.verify.remote.aio(uploaded_b64, candidate_b64),
                timeout=float(settings.request_timeout_seconds),
            )
        except TimeoutError as exc:
            raise HTTPException(status_code=504, detail="Vision model request timed out") from exc
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Vision model request failed: {exc}"
            ) from exc
        if not isinstance(result, dict):
            return {"is_same_book": False, "confidence": 0.0, "reasoning": ""}
        return result

    async def close(self) -> None:
        pass  # Modal client manages its own connection lifecycle
