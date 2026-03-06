import hashlib
import hmac
import time

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


@pytest.fixture
def valid_hmac_header() -> dict[str, str]:
    """Generate a valid HMAC token for testing."""
    timestamp = str(int(time.time()))
    method = "POST"
    path = "/extract"
    message = f"{timestamp}.{method}.{path}".encode()
    token_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{timestamp}.{token_hex}"}


def make_hmac_header(method: str, path: str, secret: str | None = None) -> dict[str, str]:
    """Helper to generate a valid HMAC header for any method+path."""
    timestamp = str(int(time.time()))
    key = secret if secret is not None else settings.hmac_secret
    message = f"{timestamp}.{method}.{path}".encode()
    token_hex = hmac.new(key.encode(), message, hashlib.sha256).hexdigest()
    return {"X-Internal-Token": f"{timestamp}.{token_hex}"}
