import os
import sys

os.environ.setdefault("VISION_ENVIRONMENT", "test")

# pyzbar needs the zbar shared library. On macOS with Homebrew, it lives under
# /opt/homebrew/lib and is not on the default search path. Set DYLD_LIBRARY_PATH
# so ctypes.util.find_library can locate it.
if sys.platform == "darwin":
    _brew_lib = "/opt/homebrew/lib"
    _current = os.environ.get("DYLD_LIBRARY_PATH", "")
    if _brew_lib not in _current:
        os.environ["DYLD_LIBRARY_PATH"] = f"{_brew_lib}:{_current}" if _current else _brew_lib

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture
def client() -> Generator[TestClient, None, None]:
    with TestClient(app) as c:
        yield c
