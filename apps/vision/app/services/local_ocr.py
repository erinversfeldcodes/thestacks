"""Local barcode-based ISBN scanner.

Uses pyzbar to decode barcodes from images and validates extracted data
as ISBN-10 or ISBN-13. This provides a fast, cheap pre-pass that can
short-circuit the VLM call when a clean barcode is present.

Safety contract: ``local_isbn_scan`` NEVER raises. It returns ``None``
on any error (corrupt image, no barcode, unrecognised format, etc.).
"""

from __future__ import annotations

import io
import logging

logger = logging.getLogger(__name__)


def _is_valid_isbn13(digits: str) -> bool:
    """Check whether *digits* is a valid ISBN-13 (EAN-13 with 978/979 prefix)."""
    if len(digits) != 13 or not digits.isdigit():
        return False
    if not digits.startswith(("978", "979")):
        return False
    total = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(digits))
    return total % 10 == 0


def _is_valid_isbn10(text: str) -> bool:
    """Check whether *text* is a valid ISBN-10."""
    if len(text) != 10:
        return False
    # First 9 characters must be digits; last may be digit or 'X'.
    if not text[:9].isdigit():
        return False
    last = text[9]
    if last not in "0123456789Xx":
        return False
    total = sum(int(d) * (10 - i) for i, d in enumerate(text[:9]))
    total += 10 if last in "Xx" else int(last)
    return total % 11 == 0


def _extract_isbn(data: str) -> str | None:
    """Return *data* if it is a valid ISBN-10 or ISBN-13, else ``None``."""
    cleaned = data.strip()
    if _is_valid_isbn13(cleaned):
        return cleaned
    if _is_valid_isbn10(cleaned):
        return cleaned
    return None


def local_isbn_scan(image_bytes: bytes) -> str | None:
    """Attempt to decode an ISBN barcode from raw image bytes.

    Returns the ISBN string on success, ``None`` otherwise. Never raises.
    """
    try:
        from PIL import Image
        from pyzbar.pyzbar import decode  # type: ignore[import-untyped]

        image = Image.open(io.BytesIO(image_bytes))
        barcodes = decode(image)
        for barcode in barcodes:
            data = barcode.data.decode("utf-8", errors="replace")
            isbn = _extract_isbn(data)
            if isbn is not None:
                return isbn
    except Exception:
        # Silent failure: corrupt image, missing lib, anything — return None.
        logger.debug("local_isbn_scan failed silently", exc_info=True)
    return None
