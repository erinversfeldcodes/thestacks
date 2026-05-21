"""Programmatic orientation correction for cover images.

Runs in the FastAPI container BEFORE the local OCR barcode pre-pass and
the VLM call in ``/analyze``. Qwen2.5-VL's vision encoder is not trained
on mirrored text and treats horizontally-flipped covers as
unrecognisable; rotated covers also degrade extraction quality. Fixing
orientation programmatically (≤150 ms CPU per image, zero GPU cost) is
materially cheaper than re-prompting the VLM and far more reliable than
asking the model to mentally re-orient.

Detection strategy
------------------

**Rotation** — Tesseract OSD (``pytesseract.image_to_osd``). OSD returns
the rotation angle needed to upright the page and a confidence value.
Tesseract's documented "trustable" threshold for orientation confidence
is ``>= 2.0`` — below that we leave the image alone rather than risk
mis-rotating a low-text or graphic-heavy cover.

**Mirror** — Tesseract cannot detect mirroring directly. We compare
``image_to_data`` word-confidence aggregates between the upright
candidate and its horizontal flip. If the flipped variant scores
``>= 2x`` higher, we treat the original as mirrored. The ``2x`` ratio
is deliberately conservative: a borderline cover (numeric-heavy
screenshot, ambiguous typography) should not be flipped on a coin-flip.

Safety contract
---------------

``correct`` NEVER raises. Any internal exception — Tesseract crash,
PIL decode failure, missing binary, corrupt bytes — is logged and
returns the input bytes unchanged. The orientation step is a perf /
quality optimisation; the upstream ``/analyze`` flow must continue
even when it can't run.
"""

from __future__ import annotations

import io
import logging

import pytesseract
import structlog
from PIL import Image, ImageOps

logger = structlog.get_logger(__name__)

# Stdlib logger used for fallback warnings (matches `local_ocr.py`).
# `_log_warning` writes here too so caplog-based tests can observe the
# exception-safety contract without depending on structlog routing.
_stdlib_logger = logging.getLogger(__name__)

# Tesseract OSD's documented "trustable" orientation-confidence
# threshold. Below this value the OSD reading is treated as noise.
_OSD_CONFIDENCE_THRESHOLD = 2.0

# Mirror is applied only when the flipped variant's aggregated word
# confidence is at least 2x the original's. Deliberately conservative —
# the failure mode (flipping a non-mirrored cover) is worse than the
# default (leaving a mirrored cover alone and letting the VLM degrade).
_MIRROR_CONFIDENCE_RATIO = 2.0


def correct(image_bytes: bytes) -> bytes:
    """Return possibly-corrected image bytes (rotation + mirror).

    Detects and reverses 90°/180°/270° rotation via Tesseract OSD,
    then detects and reverses horizontal mirroring via a word-confidence
    comparison between the upright candidate and its horizontal flip.

    Returns the input bytes object unchanged (identity, not equality)
    when neither correction fires — callers can ``is``-check the result
    to know whether the pipeline saw the original or a transform.

    Never raises. Any internal exception logs a structured warning and
    returns the input bytes unchanged.
    """
    try:
        image = _open_image(image_bytes)
    except Exception as exc:
        _log_warning("orientation.decode_failed", error=str(exc))
        return image_bytes

    try:
        rotated_image, rotation_applied = _maybe_rotate(image)
        oriented_image, mirror_applied = _maybe_mirror(rotated_image)
    except Exception as exc:
        _log_warning("orientation.detection_failed", error=str(exc))
        return image_bytes

    if not rotation_applied and not mirror_applied:
        return image_bytes

    try:
        return _encode(oriented_image, image.format)
    except Exception as exc:
        _log_warning("orientation.encode_failed", error=str(exc))
        return image_bytes


def _open_image(image_bytes: bytes) -> Image.Image:
    """Decode bytes into a fully-loaded PIL image. Raises on garbage."""
    image = Image.open(io.BytesIO(image_bytes))
    image.load()
    return image


def _maybe_rotate(image: Image.Image) -> tuple[Image.Image, bool]:
    """Apply OSD-recommended rotation when confidence clears the
    threshold. Returns the (possibly-rotated image, did_rotate) pair.

    Tesseract OSD's ``rotate`` field is the angle (in degrees) that
    must be applied to reach upright; the orientation convention there
    matches a clockwise rotation, which is ``image.rotate(-rotate)`` in
    PIL (whose ``rotate`` is counter-clockwise).
    """
    try:
        osd = pytesseract.image_to_osd(image, output_type=pytesseract.Output.DICT)
    except pytesseract.TesseractError:
        # OSD bails ("Too few characters") on graphic-heavy covers.
        # Treat as "no rotation applied" — silently fall through.
        return image, False

    confidence = float(osd.get("orientation_conf", 0.0))
    if confidence < _OSD_CONFIDENCE_THRESHOLD:
        return image, False

    angle = int(osd.get("rotate", 0))
    if angle == 0:
        return image, False

    rotated = image.rotate(-angle, expand=True)
    _log_event("orientation.rotated", angle=angle, confidence=confidence)
    return rotated, True


def _maybe_mirror(image: Image.Image) -> tuple[Image.Image, bool]:
    """Detect horizontal mirroring by comparing OCR word-confidence
    between the upright candidate and a flipped variant. If the
    flipped variant scores ``>= _MIRROR_CONFIDENCE_RATIO * original``,
    treat the original as mirrored and flip it.

    Returns (image, did_mirror).
    """
    original_score = _word_confidence_sum(image)
    flipped = ImageOps.mirror(image)
    flipped_score = _word_confidence_sum(flipped)

    # Guard against the divide-by-zero degenerate case. If the upright
    # candidate yielded zero confidence (no readable text) and the
    # flipped variant did too, there's nothing to compare. Leave alone.
    if flipped_score == 0:
        return image, False

    # When the original yields zero readable text but the flipped does,
    # we still want to flip — treat the ratio as effectively infinite.
    ratio = float("inf") if original_score == 0 else flipped_score / original_score

    if ratio < _MIRROR_CONFIDENCE_RATIO:
        return image, False

    _log_event("orientation.mirrored", confidence_ratio=ratio)
    return flipped, True


def _word_confidence_sum(image: Image.Image) -> int:
    """Sum of word-level confidences (positive values only) for a PIL
    image. Tesseract emits ``-1`` for non-word rows in the data table;
    we discard those. Higher = more legible text.
    """
    try:
        data = pytesseract.image_to_data(image, output_type=pytesseract.Output.DICT)
    except pytesseract.TesseractError:
        return 0

    total = 0
    for raw in data.get("conf", []):
        try:
            value = int(raw)
        except (TypeError, ValueError):
            continue
        if value > 0:
            total += value
    return total


def _encode(image: Image.Image, original_format: str | None) -> bytes:
    """Re-encode a PIL image back to bytes, preserving the original
    container format where possible. Falls back to JPEG when the source
    format is unknown or lossy-incompatible (most uploads are JPEG
    already, so this is the common path).
    """
    buf = io.BytesIO()
    fmt = (original_format or "JPEG").upper()
    # PIL refuses to save RGBA into JPEG; coerce to RGB on that path.
    save_image = image
    if fmt in ("JPEG", "JPG") and image.mode not in ("RGB", "L"):
        save_image = image.convert("RGB")
    save_kwargs: dict[str, object] = {}
    if fmt in ("JPEG", "JPG"):
        save_kwargs["quality"] = 90
    save_image.save(buf, format=fmt, **save_kwargs)
    return buf.getvalue()


def _log_event(event: str, **kwargs: object) -> None:
    """Emit a structured INFO event via both structlog (for prod's
    structured-log dashboarding) and stdlib logging (so test runners
    using ``caplog`` observe it).

    The dual emit costs nothing — structlog and stdlib are independent
    sinks. The stdlib record carries the event name as its message
    string so ``record.getMessage()`` matches by substring in tests.
    """
    logger.info(event, **kwargs)
    _stdlib_logger.info(event, extra=kwargs if kwargs else None)


def _log_warning(event: str, **kwargs: object) -> None:
    """Emit a structured WARNING via both structlog and stdlib logging,
    matching the dual-emit contract of :func:`_log_event`. Used by the
    exception-safety paths in :func:`correct`.
    """
    logger.warning(event, **kwargs)
    _stdlib_logger.warning(event, extra=kwargs if kwargs else None)
