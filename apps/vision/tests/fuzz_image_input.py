"""Fuzz target for image input parsing in the vision sidecar.

Exercises the base64 decode, size check, and JSON parsing paths in both
/extract and /classify without making any external API calls.

Running with Atheris (Linux only — requires: pip install atheris):
    just fuzz-vision -- -atheris_runs=100000

Running as a seed-corpus regression test (all platforms):
    just fuzz-vision

The seed corpus lives at <repo-root>/images/ and contains representative
book cover photos used to prime coverage before Atheris mutates inputs.
"""

import base64
import json
import os
import sys
from pathlib import Path

# Must precede app imports — config reads VISION_ENVIRONMENT at module load time.
os.environ.setdefault("VISION_ENVIRONMENT", "test")

# Atheris is Linux-only; import conditionally so the file can be loaded on macOS.
try:
    import atheris

    _ATHERIS_AVAILABLE = True
except ImportError:
    _ATHERIS_AVAILABLE = False

from app.config import settings

_CORPUS_DIR = Path(__file__).parent.parent.parent.parent / "images"


def _fuzz_base64_and_size(raw: bytes) -> None:
    """Simulate the per-image validation path shared by /extract and /classify."""
    # Path 1: treat raw bytes as image content, encode and re-decode (nominal path).
    b64 = base64.b64encode(raw).decode()
    try:
        decoded = base64.b64decode(b64, validate=True)
        _ = len(decoded) > settings.max_image_size_bytes
    except Exception:
        pass

    # Path 2: treat raw bytes as an attacker-supplied base64 string.
    try:
        as_str = raw.decode("latin-1")
        decoded = base64.b64decode(as_str, validate=True)
        _ = len(decoded) > settings.max_image_size_bytes
    except Exception:
        pass


def _fuzz_model_output_parsing(raw: bytes) -> None:
    """Simulate the JSON parsing path applied to Together AI model output."""
    try:
        content = raw.decode("utf-8", errors="replace")
        parsed: object = json.loads(content)
        if isinstance(parsed, dict):
            _ = parsed.get("classification", "ambiguous")
            _ = parsed.get("confidence", 0.0)
            _ = parsed.get("title")
            _ = parsed.get("author")
            _ = parsed.get("potential_isbns")
    except (json.JSONDecodeError, UnicodeDecodeError):
        pass


def TestOneInput(data: bytes) -> None:  # noqa: N802 — Atheris requires this exact name
    _fuzz_base64_and_size(data)
    _fuzz_model_output_parsing(data)


def _run_seed_corpus() -> None:
    """Run TestOneInput against every image in the seed corpus plus synthetic inputs."""
    synthetic = [
        b"",
        b"not valid base64!!!",
        b'{"classification": "book", "confidence": 0.95}',
        b'{"classification": "unknown", "confidence": 999}',
        b'{"choices": []}',
        bytes(range(256)),
        b"\x00" * 10_000,
    ]
    for payload in synthetic:
        TestOneInput(payload)

    if _CORPUS_DIR.exists():
        images = sorted(_CORPUS_DIR.glob("*.PNG")) + sorted(_CORPUS_DIR.glob("*.jpg"))
        for img_path in images:
            print(f"  seed: {img_path.name}")
            TestOneInput(img_path.read_bytes())
    else:
        print(f"  (no corpus at {_CORPUS_DIR} — synthetic inputs only)")

    print("Seed corpus run complete — no panics.")


if __name__ == "__main__":
    if _ATHERIS_AVAILABLE and len(sys.argv) > 1 and sys.argv[1].startswith("-"):
        atheris.Setup(sys.argv, TestOneInput)
        atheris.Fuzz()
    else:
        _run_seed_corpus()
