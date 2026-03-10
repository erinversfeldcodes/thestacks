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


def test_extract_without_token_returns_401() -> None:
    with TestClient(app) as client:
        response = client.post("/extract", json={"images": [_VALID_IMAGE]})
    assert response.status_code == 401


def test_extract_with_invalid_token_returns_401() -> None:
    with TestClient(app) as client:
        response = client.post(
            "/extract",
            json={"images": [_VALID_IMAGE]},
            headers={"X-Internal-Token": "not-a-valid-token"},
        )
    assert response.status_code == 401


def test_extract_with_expired_token_returns_401() -> None:
    """Timestamp older than 60 seconds should be rejected."""
    old_timestamp = int(time.time()) - 120
    headers = _make_header("POST", "/extract", timestamp=old_timestamp)
    with TestClient(app) as client:
        response = client.post("/extract", json={"images": [_VALID_IMAGE]}, headers=headers)
    assert response.status_code == 401


def test_classify_without_token_returns_401() -> None:
    with TestClient(app) as client:
        response = client.post("/classify", json={"image": _VALID_IMAGE})
    assert response.status_code == 401


def test_extract_with_wrong_secret_returns_401() -> None:
    headers = _make_header("POST", "/extract", secret="wrong_secret")
    with TestClient(app) as client:
        response = client.post("/extract", json={"images": [_VALID_IMAGE]}, headers=headers)
    assert response.status_code == 401


def test_classify_with_wrong_secret_returns_401() -> None:
    headers = _make_header("POST", "/classify", secret="wrong_secret")
    with TestClient(app) as client:
        response = client.post("/classify", json={"image": _VALID_IMAGE}, headers=headers)
    assert response.status_code == 401


def test_classify_with_expired_token_returns_401() -> None:
    """Timestamp older than 60 seconds should be rejected on /classify."""
    old_timestamp = int(time.time()) - 120
    headers = _make_header("POST", "/classify", timestamp=old_timestamp)
    with TestClient(app) as client:
        response = client.post("/classify", json={"image": _VALID_IMAGE}, headers=headers)
    assert response.status_code == 401


@pytest.mark.parametrize("insecure_value", ["change_me_in_dev", "change_me", "secret", ""])
def test_settings_rejects_insecure_hmac_secret(insecure_value: str) -> None:
    """Settings should raise at startup if hmac_secret is an insecure default in non-test envs."""
    with pytest.raises(ValidationError, match="insecure default"):
        Settings(
            environment="development",
            hmac_secret=insecure_value,
            together_api_key="any-key",
        )


def test_settings_rejects_empty_together_api_key() -> None:
    """Settings should raise at startup if together_api_key is empty in non-test environments."""
    with pytest.raises(ValidationError, match="VISION_TOGETHER_API_KEY"):
        Settings(
            environment="development",
            hmac_secret="a-strong-secret-value",
            together_api_key="",
        )
