"""Local barcode-based ISBN scanner (pyzbar): the fast, cheap pre-pass
that short-circuits the VLM when a clean barcode is present. If the
as-uploaded image fails to decode, a sweep of cheap transforms is tried
(mirror, rotations — pyzbar can't decode mirrored barcodes, which
screenshot-of-screenshot uploads produce); the happy path stays one
decode attempt. Safety contract: ``local_isbn_scan`` never raises —
any failure returns None and the VLM path proceeds.
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

    Tries the image as-is first, then a sweep of cheap orientation
    variants (mirror, rotations, mirror + 90) for photos that are
    flipped, rotated, or mirrored.

    Returns the ISBN string on success, ``None`` otherwise. Never raises.
    """
    try:
        from PIL import Image
        from pyzbar.pyzbar import decode

        def _scan(image: Image.Image) -> str | None:
            for barcode in decode(image):
                data = barcode.data.decode("utf-8", errors="replace")
                isbn = _extract_isbn(data)
                if isbn is not None:
                    return isbn
            return None

        original = Image.open(io.BytesIO(image_bytes))
        original.load()

        isbn = _scan(original)
        if isbn is not None:
            return isbn

        mirrored = original.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        variants: list[tuple[str, Image.Image]] = [
            ("mirror", mirrored),
            ("rotate_90", original.transpose(Image.Transpose.ROTATE_90)),
            ("rotate_180", original.transpose(Image.Transpose.ROTATE_180)),
            ("rotate_270", original.transpose(Image.Transpose.ROTATE_270)),
            ("mirror+rotate_90", mirrored.transpose(Image.Transpose.ROTATE_90)),
        ]
        for name, variant in variants:
            isbn = _scan(variant)
            if isbn is not None:
                logger.debug("local_isbn_scan succeeded on %s variant", name)
                return isbn
    except Exception:
        logger.debug("local_isbn_scan failed silently", exc_info=True)
    return None
