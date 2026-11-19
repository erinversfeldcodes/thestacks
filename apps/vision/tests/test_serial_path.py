"""The serial-path contract of /analyze: the one base64 decode, CPU tiers off
the event loop, and the shadow cover read overlapping the GPU dispatch instead
of preceding it.

Each test here is an ordering/plumbing proof designed to RED under the serial
inline code it replaced — not a smoke test. The classify token cap's
behavioural safety (no score change) is owned by the slice gate, not this file;
here we prove only that the cap is actually plumbed to both classify call
sites and nowhere else.
"""

import asyncio
import base64
import hashlib
import hmac
import threading
import time
from collections.abc import Iterator
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.services.cover_text import CoverText

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()

_BOOK_ANALYZED: dict[str, Any] = {
    "classify": {"classification": "book", "confidence": 0.9},
    "extract": {"books": []},
}


def _make_header(path: str = "/analyze") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _cover(title: str | None) -> CoverText:
    return CoverText(
        title=title,
        author=None,
        raw_text=title or "",
        confidence=0.9 if title else 0.0,
        engine="test",
    )


@pytest.fixture(autouse=True)
def _shadow_mode() -> Iterator[None]:
    """Pin the mode these tests assume: cover text read in shadow (on, but not
    answering), so the GPU always answers and the overlap contract applies."""
    with (
        patch.object(settings, "cover_text_enabled", True),
        patch.object(settings, "ocr_short_circuit", False),
        patch.object(settings, "single_dispatch", True),
    ):
        yield


def test_shadow_cover_read_overlaps_the_gpu_dispatch() -> None:
    """The shadow read must run DURING the GPU call, not before it.

    The fake cover read blocks until the fake GPU dispatch has started. Under
    the old serial code (read first, dispatch after) that signal never comes:
    the wait times out and the read reports a miss. Only the concurrent
    ordering can produce a hit here — so a hit in `ocr_attempt` IS the
    ordering proof, and the timeout keeps the failure mode a red test, not a
    hang.
    """
    gpu_started = threading.Event()

    def blocking_cover_read(image_bytes: bytes) -> CoverText:
        released = gpu_started.wait(timeout=5.0)
        return _cover("Overlap" if released else None)

    async def fake_analyze(
        self: Any, image_b64: str, excluded_books: list[str] | None = None
    ) -> dict[str, Any]:
        gpu_started.set()
        return _BOOK_ANALYZED

    with (
        patch("app.main.local_isbn_scan", return_value=None),
        patch("app.main.read_cover_text", side_effect=blocking_cover_read),
        patch("app.services.vision_client.VisionClient.analyze", fake_analyze),
        TestClient(app) as client,
    ):
        data = client.post("/analyze", json={"image": _VALID_IMAGE}, headers=_make_header()).json()

    assert data["ocr_attempt"] is not None, "shadow read must still be reported"
    # ⬛ THE ORDERING PROOF: a title here is only reachable if the read saw the
    # dispatch start — i.e. it ran concurrently with the GPU call.
    assert data["ocr_attempt"]["title"] == "Overlap"
    assert data["ocr_attempt"]["answered"] is False
    # The read's own duration is reported, and the request still answered via
    # the VLM (shadow never answers).
    assert data["timings_ms"]["ocr"] is not None
    assert data["model_used"] != "test"


def test_cpu_tiers_run_off_the_event_loop() -> None:
    """Neither the barcode scan nor the cover read may execute on the event
    loop thread. Inside `asyncio.to_thread` there is no running loop, so
    `asyncio.get_running_loop()` raising is the discriminating observation —
    the old inline code ran both in the handler coroutine, where it succeeds.
    """
    ran_on_loop: dict[str, bool] = {}

    def recording(name: str, result: Any) -> Any:
        def fake(image_bytes: bytes) -> Any:
            try:
                asyncio.get_running_loop()
                ran_on_loop[name] = True
            except RuntimeError:
                ran_on_loop[name] = False
            return result

        return fake

    with (
        patch("app.main.local_isbn_scan", side_effect=recording("barcode", None)),
        patch("app.main.read_cover_text", side_effect=recording("ocr", _cover(None))),
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=_BOOK_ANALYZED,
        ),
        TestClient(app) as client,
    ):
        client.post("/analyze", json={"image": _VALID_IMAGE}, headers=_make_header())

    # ⬛ ANTI-VACUITY: both tiers must have RUN for their verdicts to mean
    # anything — a missing key is a cascade that skipped the tier, not a pass.
    assert ran_on_loop == {"barcode": False, "ocr": False}


def test_exactly_one_base64_decode_per_request() -> None:
    """`_load_image_b64` decodes once and every downstream tier takes the
    bytes. The old path decoded up to three times (validation, the handler's
    own decode, `_resize_for_vlm`) — counting the real decoder catches any of
    them coming back.
    """
    with (
        patch("app.main.local_isbn_scan", return_value=None),
        patch("app.main.read_cover_text", return_value=_cover(None)),
        patch(
            "app.services.vision_client.VisionClient.analyze",
            new_callable=AsyncMock,
            return_value=_BOOK_ANALYZED,
        ),
        TestClient(app) as client,
        patch("app.main.base64.b64decode", wraps=base64.b64decode) as decode,
    ):
        resp = client.post("/analyze", json={"image": _VALID_IMAGE}, headers=_make_header())

    assert resp.status_code == 200
    assert decode.call_count == 1


def test_classify_token_cap_is_plumbed_to_both_call_sites() -> None:
    """The cap must reach the `classify` method AND `analyze`'s classify leg,
    and must NOT reach extract (whose output is real content). Source-level on
    purpose: running `_infer` needs a GPU, and the cap's behavioural safety is
    the slice gate's job — this test only pins the plumbing so a refactor
    cannot silently drop the cap from one of the two sites.
    """
    import inspect

    import modal_app

    assert modal_app._CLASSIFY_MAX_TOKENS < 512
    source = inspect.getsource(modal_app)
    # Code-shaped pattern (`=` unspaced), so prose in comments cannot satisfy it.
    assert source.count("max_new_tokens=_CLASSIFY_MAX_TOKENS") == 2
    assert "max_new_tokens: int = 512" in source
