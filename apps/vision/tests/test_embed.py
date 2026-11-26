"""The route contract of POST /embed — the text-embedding backend for the
writing-assistant corpus, on the CPU front door with NO GPU dispatch.

Every test MOCKS the embedder: bge-m3 is ~2.3GB and never loads in CI. What they
pin is the contract a caller may rely on — the response shape (one vector per
text, in request order, at the model's full width), that the response's `model`
is the SIDECAR's stamp (the model that ran) and never the echoed request value,
the HMAC gate, and the deterministic rejection of an empty batch.
"""

import hashlib
import hmac
import time
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

# The stamp the mocked embedder reports. Deliberately DIFFERENT from any model a
# request asks for below, so "the response carries this" proves the handler
# returns the model that RAN, not the one the caller requested.
_SERVED_STAMP = "bge-m3-served"
_DIM = 1024


def _make_header(path: str = "/embed") -> dict[str, str]:
    ts = str(int(time.time()))
    message = f"{ts}.POST.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def _fake_embed(texts: list[str]) -> tuple[list[list[float]], str, int]:
    """Deterministic stand-in for bge-m3: a distinct full-width vector per text,
    its first component the text's index so request order is checkable, the rest
    zero. Returns the same `(vectors, model_stamp, dim)` triple the real
    `embed_texts` does."""
    vectors = [[float(i), *([0.0] * (_DIM - 1))] for i in range(len(texts))]
    return vectors, _SERVED_STAMP, _DIM


def test_embed_returns_one_stamped_vector_per_text_in_order() -> None:
    texts = ["shelf intent one", "a blog post", "imported writing"]
    with (
        patch("app.main.embed_texts", side_effect=_fake_embed) as embedder,
        TestClient(app) as client,
    ):
        resp = client.post(
            "/embed",
            json={"texts": texts, "model": "bge-m3"},
            headers=_make_header(),
        )

    assert resp.status_code == 200
    data = resp.json()
    # One vector per input text, each at the full bge-m3 width.
    assert len(data["vectors"]) == len(texts)
    assert all(len(v["values"]) == _DIM for v in data["vectors"])
    # In request order — the index rode in as each vector's first component.
    assert [v["values"][0] for v in data["vectors"]] == [0.0, 1.0, 2.0]
    # The reported dim is the embedder's width, and `model` is the stamp.
    assert data["dim"] == _DIM
    assert data["model"] == _SERVED_STAMP
    # The texts reached the embedder in order and nothing else was invented.
    embedder.assert_called_once_with(texts)


def test_embed_response_model_is_the_stamp_not_the_requested_value() -> None:
    """The caller persists the model that RAN. A request asking for one name
    must come back stamped with what the sidecar actually served — echoing
    `body.model` would record a model the row was never embedded with."""
    with (
        patch("app.main.embed_texts", side_effect=_fake_embed),
        TestClient(app) as client,
    ):
        data = client.post(
            "/embed",
            json={"texts": ["x"], "model": "a-model-the-caller-asked-for"},
            headers=_make_header(),
        ).json()

    assert data["model"] == _SERVED_STAMP
    assert data["model"] != "a-model-the-caller-asked-for"


def test_embed_without_token_returns_401_and_never_embeds() -> None:
    """HMAC gates /embed exactly as it gates /analyze. The embedder is an
    AssertionError here, so if auth ever let the request through the test would
    fail on the 401 assertion rather than silently embedding."""
    with (
        patch(
            "app.main.embed_texts",
            side_effect=AssertionError("auth must gate /embed before the embedder"),
        ) as embedder,
        TestClient(app) as client,
    ):
        resp = client.post("/embed", json={"texts": ["x"], "model": "bge-m3"})

    assert resp.status_code == 401
    embedder.assert_not_called()


def test_embed_with_unparseable_token_returns_401() -> None:
    with (
        patch("app.main.embed_texts", side_effect=_fake_embed),
        TestClient(app) as client,
    ):
        resp = client.post(
            "/embed",
            json={"texts": ["x"], "model": "bge-m3"},
            headers={"X-Internal-Token": "not-a-valid-token"},
        )

    assert resp.status_code == 401


def test_embed_rejects_empty_texts_as_malformed() -> None:
    """An empty batch cannot be made valid by being resent, so it is a
    deterministic MALFORMED_REQUEST and the embedder is never woken."""
    with (
        patch(
            "app.main.embed_texts",
            side_effect=AssertionError("must not embed an empty batch"),
        ) as embedder,
        TestClient(app) as client,
    ):
        resp = client.post(
            "/embed",
            json={"texts": [], "model": "bge-m3"},
            headers=_make_header(),
        )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VISION_ERROR_CODE_MALFORMED_REQUEST"
    embedder.assert_not_called()


def test_embed_rejects_absent_texts_as_malformed() -> None:
    """An omitted `texts` defaults to [] at the schema layer and takes the same
    rejection path — not a 200 with an empty vector list."""
    with (
        patch(
            "app.main.embed_texts",
            side_effect=AssertionError("must not embed"),
        ) as embedder,
        TestClient(app) as client,
    ):
        resp = client.post(
            "/embed",
            json={"model": "bge-m3"},
            headers=_make_header(),
        )

    assert resp.status_code == 422
    assert resp.json()["code"] == "VISION_ERROR_CODE_MALFORMED_REQUEST"
    embedder.assert_not_called()
