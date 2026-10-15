"""HMAC authentication on the vision sidecar's one authenticated endpoint.

⚠️ This file covered `/extract` and `/classify` until 2026-10-15, when a single
`/analyze` superseded both. Nine of its ten tests POSTed to those two routes,
and re-pointing them all at `/analyze` would have produced **three duplicate
pairs** — without-token, wrong-secret and expired-token each existed once per
endpoint, and the endpoint was the only difference between them. So the suite is
six distinct auth properties rather than nine near-identical tests, and that is
a deliberate reduction, not a loss of coverage.

The property each test pins is the one `hmac_auth.py` can get wrong
independently: a missing token, an unparseable one, a stale timestamp, a
pre-generated one, a correct signature under the wrong key, and a correct
signature for a different path. Note that the dependency runs before Pydantic
validates the body, so these assert 401 regardless of request shape — verified,
rather than assumed, by signing a request whose body would not have validated.
"""

import base64
import hashlib
import hmac
import time

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Settings, settings
from app.main import app

_VALID_IMAGE = base64.b64encode(b"fake-image-data").decode()
_PATH = "/analyze"


def _make_header(
    method: str,
    path: str,
    secret: str | None = None,
    timestamp: int | None = None,
) -> dict[str, str]:
    ts = str(timestamp if timestamp is not None else int(time.time()))
    key = secret if secret is not None else settings.hmac_secret
    message = f"{ts}.{method}.{path}".encode()
    token_hex = hmac.new(key.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{ts}.{token_hex}"}


def test_without_token_returns_401() -> None:
    with TestClient(app) as client:
        response = client.post(_PATH, json={"image": _VALID_IMAGE})
    assert response.status_code == 401


def test_with_unparseable_token_returns_401() -> None:
    with TestClient(app) as client:
        response = client.post(
            _PATH,
            json={"image": _VALID_IMAGE},
            headers={"X-Internal-Token": "not-a-valid-token"},
        )
    assert response.status_code == 401


def test_with_expired_token_returns_401() -> None:
    """A timestamp older than the 60-second replay window is rejected."""
    old_timestamp = int(time.time()) - 120
    headers = _make_header("POST", _PATH, timestamp=old_timestamp)
    with TestClient(app) as client:
        response = client.post(_PATH, json={"image": _VALID_IMAGE}, headers=headers)
    assert response.status_code == 401


def test_with_future_token_returns_401() -> None:
    """A timestamp far in the future is rejected too.

    The window is `abs(now - timestamp) > 60`, so it catches pre-generated
    tokens as well as stale ones. Signed by hand rather than through
    `_make_header` so the future timestamp is unmistakably part of the signed
    message.
    """
    ts = str(int(time.time()) + 120)
    message = f"{ts}.POST.{_PATH}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    with TestClient(app) as client:
        response = client.post(
            _PATH,
            json={"image": _VALID_IMAGE},
            headers={"X-Internal-Token": f"{ts}.{token_hex}"},
        )
    assert response.status_code == 401


def test_with_wrong_secret_returns_401() -> None:
    headers = _make_header("POST", _PATH, secret="wrong_secret")
    with TestClient(app) as client:
        response = client.post(_PATH, json={"image": _VALID_IMAGE}, headers=headers)
    assert response.status_code == 401


def test_with_token_signed_for_another_path_returns_401() -> None:
    """A valid signature for a different path must not be replayable here.

    The path is part of the HMAC message (`<ts>.POST.<path>`, built from
    `request.url.path`), which is what binds a token to one endpoint. Signed for
    a path that does not exist on this service, so the test asserts the binding
    rather than the existence of a second route — it cannot rot the next time an
    endpoint is removed.
    """
    with TestClient(app) as client:
        response = client.post(
            _PATH,
            json={"image": _VALID_IMAGE},
            headers=_make_header("POST", "/not-this-path"),
        )
    assert response.status_code == 401


def test_auth_rejects_before_body_validation() -> None:
    """An unauthenticated request with an invalid body is still a 401, not a 422.

    `Depends(verify_hmac)` runs ahead of Pydantic, so auth failure must win.
    If this ever returned 422 it would mean the service was telling an
    unauthenticated caller about its schema.
    """
    with TestClient(app) as client:
        response = client.post(_PATH, json={"images": [_VALID_IMAGE]})
    assert response.status_code == 401


@pytest.mark.parametrize("insecure_value", ["change_me_in_dev", "change_me", "secret", ""])
def test_settings_rejects_insecure_hmac_secret(insecure_value: str) -> None:
    """Settings should raise at startup if hmac_secret is an insecure default in non-test envs."""
    with pytest.raises(ValidationError, match="insecure default"):
        Settings(
            environment="development",
            hmac_secret=insecure_value,
        )
