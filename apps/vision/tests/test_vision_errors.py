"""The sidecar's half of the vision error contract.

Core (`Stacks.AI.VisionError`) decides whether to retry an upload on a GPU by
branching on the ``code`` in the error body. That only works if the codes this
service actually puts on the wire are the ones core knows about, so these tests
check three separate things that can each break independently:

1. the constants in ``app.main`` are exactly the proto enum's non-zero values —
   a typo here is invisible to mypy and to every other test in this suite;
2. a deterministic failure really renders as a bare ``VisionError`` body, not as
   FastAPI's default ``{"detail": ...}``;
3. a failure that is *not* a determination about the image (auth, an unhandled
   crash) carries no code at all — because a code tells core to stop retrying,
   and telling it to stop retrying a transient fault is the more expensive
   mistake of the two.

The Elixir half is ``apps/core/test/stacks/ai/vision_error_test.exs``. Both read
the enum from the proto rather than from a literal list, so they cannot drift
apart without one of them failing.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.util
import time
from pathlib import Path
from typing import TYPE_CHECKING, Any
from unittest.mock import AsyncMock, patch

import pytest

from app import main as main_module
from app.config import settings

if TYPE_CHECKING:
    from fastapi.testclient import TestClient

REPO_ROOT = Path(__file__).resolve().parents[3]


def _proto_enum_values(enum_name: str) -> list[str]:
    """Read an enum's wire values straight from the proto descriptor.

    Uses the generator's own descriptor loading so this test cannot disagree
    with what codegen (and `scripts/check-enum-coverage.py`) sees.
    """
    spec = importlib.util.spec_from_file_location(
        "stacks_gen_proto", REPO_ROOT / "scripts" / "gen_python_proto.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    for entry in module._collect_all_enums(module.load_descriptor()):
        if entry["enum"]["name"] == enum_name:
            return [v["name"] for v in entry["enum"].get("value", [])]
    raise AssertionError(f"{enum_name} not found in the proto descriptor")


def _sidecar_error_constants() -> set[str]:
    return {
        value
        for name, value in vars(main_module).items()
        if name.startswith("_ERR_") and isinstance(value, str)
    }


def _make_header(path: str) -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _post(client: TestClient, path: str, body: dict[str, Any]) -> Any:
    return client.post(path, json=body, headers=_make_header(path))


# ---------------------------------------------------------------------------
# 1. The constants are the enum
# ---------------------------------------------------------------------------


def test_error_constants_are_exactly_the_proto_enums_non_zero_values() -> None:
    declared = _proto_enum_values("VisionErrorCode")
    zero_value = "VISION_ERROR_CODE_UNSPECIFIED"

    assert zero_value in declared, "proto3 requires a zero value"

    expected = set(declared) - {zero_value}
    actual = _sidecar_error_constants()

    assert actual == expected, (
        "The codes this service can send and the codes proto declares have "
        f"diverged.\n  only in app.main: {sorted(actual - expected)}\n"
        f"  only in proto:    {sorted(expected - actual)}\n"
        "Core branches on these strings; one it does not recognise is retried "
        "three times on a GPU before the upload fails."
    )


def test_the_unspecified_sentinel_is_never_a_constant() -> None:
    # Sending the zero value would mean "a determination was made, but not which
    # one" — core treats it as unrecognised, so emitting it deliberately would
    # be a way to look labelled while saying nothing.
    assert "VISION_ERROR_CODE_UNSPECIFIED" not in _sidecar_error_constants()


# ---------------------------------------------------------------------------
# 2. Deterministic failures render as a bare VisionError
# ---------------------------------------------------------------------------

_DETERMINISTIC_CASES = [
    pytest.param(
        "/extract",
        {"images": ["!!!not base64!!!"]},
        "VISION_ERROR_CODE_UNDECODABLE_IMAGE",
        id="undecodable-base64",
    ),
    pytest.param(
        "/extract",
        {"images": [base64.b64encode(b"x" * (settings.max_image_size_bytes + 1)).decode()]},
        "VISION_ERROR_CODE_IMAGE_TOO_LARGE",
        id="image-too-large",
    ),
    pytest.param(
        "/extract",
        {"images": []},
        "VISION_ERROR_CODE_NO_IMAGE_SUPPLIED",
        id="no-image-supplied",
    ),
    pytest.param(
        "/extract",
        {"images": [base64.b64encode(b"a").decode()], "image_url": "https://x.test/a.jpg"},
        "VISION_ERROR_CODE_MALFORMED_REQUEST",
        id="mutually-exclusive-inputs",
    ),
    pytest.param(
        "/extract",
        {"images": [base64.b64encode(b"a").decode()] * 4},
        "VISION_ERROR_CODE_MALFORMED_REQUEST",
        id="too-many-images",
    ),
]


@pytest.mark.parametrize(("path", "body", "expected_code"), _DETERMINISTIC_CASES)
def test_deterministic_failure_returns_a_bare_vision_error(
    client: TestClient, path: str, body: dict[str, Any], expected_code: str
) -> None:
    response = _post(client, path, body)

    assert response.status_code == 422
    payload = response.json()

    assert set(payload) == {"code", "message"}, (
        "The body must be the JSON encoding of the VisionError proto message, "
        f"not FastAPI's default envelope. Got: {payload}"
    )
    assert payload["code"] == expected_code
    assert payload["message"], "message is what the operator reads; it may not be empty"


@pytest.mark.parametrize(("path", "body", "expected_code"), _DETERMINISTIC_CASES)
def test_every_deterministic_code_is_one_core_recognises(
    client: TestClient, path: str, body: dict[str, Any], expected_code: str
) -> None:
    # Belt to test 1's braces: the constants could match the enum while a call
    # site sends a bare string that matches neither.
    response = _post(client, path, body)
    assert response.json()["code"] in _sidecar_error_constants()


def test_unreachable_image_url_is_labelled_unreachable(client: TestClient) -> None:
    with patch(
        "app.main._download_image",
        new_callable=AsyncMock,
        side_effect=main_module._vision_error(
            "VISION_ERROR_CODE_IMAGE_UNREACHABLE", "Failed to download image from URL: HTTP 404"
        ),
    ):
        response = _post(client, "/extract", {"image_url": "https://storage.test/gone.jpg"})

    assert response.status_code == 422
    assert response.json()["code"] == "VISION_ERROR_CODE_IMAGE_UNREACHABLE"


# ---------------------------------------------------------------------------
# 3. Non-determinations stay unlabelled, and therefore retryable
# ---------------------------------------------------------------------------


def test_auth_failure_carries_no_code(client: TestClient) -> None:
    # An auth failure is about us, not about the image. If it arrived labelled,
    # core would cancel the upload instead of retrying past a clock skew or a
    # secret rotation.
    response = client.post("/extract", json={"images": [base64.b64encode(b"a").decode()]})

    assert response.status_code in (401, 403)
    assert "code" not in response.json(), (
        f"an auth failure must not look like a determination about the image: {response.json()}"
    )
    assert "detail" in response.json()


def test_health_is_unaffected_by_the_error_handler(client: TestClient) -> None:
    # The exception handler is installed app-wide; this pins that it did not
    # change the shape of anything that was already working.
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
