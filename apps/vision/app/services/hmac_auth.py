import hashlib
import hmac
import time

from fastapi import HTTPException, Request

from app.config import settings

_TOKEN_HEADER = "X-Internal-Token"
_MAX_AGE_SECONDS = 60


async def verify_hmac(request: Request) -> None:
    """Verify X-Internal-Token header. Raises 401 if missing or invalid."""
    token = request.headers.get(_TOKEN_HEADER)
    if not token:
        raise HTTPException(status_code=401, detail="Unauthorized")

    parts = token.split(".", 1)
    if len(parts) != 2:
        raise HTTPException(status_code=401, detail="Unauthorized")

    timestamp_str, provided_hex = parts

    try:
        timestamp = int(timestamp_str)
    except ValueError as err:
        raise HTTPException(status_code=401, detail="Unauthorized") from err

    now = int(time.time())
    if abs(now - timestamp) > _MAX_AGE_SECONDS:
        raise HTTPException(status_code=401, detail="Unauthorized")

    message = f"{timestamp_str}.{request.method}.{request.url.path}".encode()
    expected_hex = hmac.new(settings.hmac_secret.encode(), message, hashlib.sha256).hexdigest()

    if not hmac.compare_digest(expected_hex, provided_hex):
        raise HTTPException(status_code=401, detail="Unauthorized")
