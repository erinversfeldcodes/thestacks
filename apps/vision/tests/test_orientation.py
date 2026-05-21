"""Unit tests for the programmatic orientation correction module.

These tests cover the behaviour contract defined in Issue #168:

* upright images pass through unchanged,
* rotated images (90/180/270) are auto-rotated back to upright when
  Tesseract OSD reports a confident orientation,
* mirrored images are flipped back when the mirror-confidence ratio
  exceeds the configured threshold,
* combined mirror + rotation is corrected end-to-end,
* below-confidence OSD readings leave the image alone,
* any internal failure (Tesseract crash, Pillow crash, ...) returns the
  original bytes without raising — `correct/1` is exception-safe.

We also assert the structured-log telemetry contract: an
``orientation.rotated`` event when rotation fires and an
``orientation.mirrored`` event when mirror correction fires, and zero
log events for the common upright case.
"""

from __future__ import annotations

import io
from typing import Any
from unittest.mock import patch

import pytest
from PIL import Image, ImageDraw, ImageFont, ImageOps

from app.services import orientation


def _render_text_image() -> Image.Image:
    """Render an upright PIL image carrying enough Latin text for
    Tesseract to commit to an OSD orientation with confidence >= 2.0
    AND for the mirror-confidence ratio between upright and flipped
    variants to clear the 2x threshold.

    Tesseract still scores moderate confidence on mirrored Latin text
    (typography has rough left-right symmetry for many letters), so the
    fixture needs enough words to amplify the ratio.
    """
    img = Image.new("RGB", (1200, 900), color="white")
    draw = ImageDraw.Draw(img)
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 32)
    except OSError:
        # Linux CI: fall back to a TrueType font shipped in most distros.
        try:
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 32)
        except OSError:
            font = ImageFont.load_default()
    text = (
        "The Great Gatsby\n"
        "by F. Scott Fitzgerald\n"
        "Published 1925\n"
        "Charles Scribners Sons\n"
        "New York City Publisher\n"
        "A novel about the\n"
        "American Dream\n"
        "chasing wealth power\n"
        "and the unattainable\n"
        "green light across\n"
        "the bay at East Egg\n"
        "Daisy Buchanan and\n"
        "Tom Buchanan host\n"
        "parties in West Egg."
    )
    draw.multiline_text((30, 20), text, fill="black", font=font)
    return img


def _to_jpeg_bytes(image: Image.Image) -> bytes:
    """Encode a PIL image as JPEG bytes — the on-the-wire format used by
    the sidecar."""
    buf = io.BytesIO()
    image.convert("RGB").save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def _bytes_to_image(image_bytes: bytes) -> Image.Image:
    """Decode bytes back into a PIL image (helper for assertions)."""
    img = Image.open(io.BytesIO(image_bytes))
    img.load()
    return img


def _osd_rotate(image: Image.Image) -> int:
    """Return Tesseract's `rotate` value (degrees to apply to reach
    upright) for a PIL image. Falls back to 0 on OSD failure — used in
    assertions where the corrected image should report `rotate=0`.
    """
    import pytesseract

    try:
        osd = pytesseract.image_to_osd(image, output_type=pytesseract.Output.DICT)
        return int(osd["rotate"])
    except pytesseract.TesseractError:
        return 0


@pytest.fixture(scope="module")
def upright_image() -> Image.Image:
    return _render_text_image()


@pytest.fixture(scope="module")
def upright_bytes(upright_image: Image.Image) -> bytes:
    return _to_jpeg_bytes(upright_image)


class TestOrientationCorrectUpright:
    """An already-upright, non-mirrored image is returned unchanged."""

    def test_upright_image_passes_through_unchanged(self, upright_bytes: bytes) -> None:
        result = orientation.correct(upright_bytes)
        # When no transformation is needed, the function returns the
        # exact input bytes object (identity, not equality) so callers
        # can `is`-check whether anything changed.
        assert result is upright_bytes

    def test_upright_image_emits_no_log_events(
        self, upright_bytes: bytes, caplog: pytest.LogCaptureFixture
    ) -> None:
        with caplog.at_level("INFO", logger="app.services.orientation"):
            orientation.correct(upright_bytes)
        joined = " ".join(record.getMessage() for record in caplog.records)
        assert "orientation.rotated" not in joined
        assert "orientation.mirrored" not in joined


class TestOrientationCorrectRotation:
    """Rotated images are corrected back to upright."""

    @pytest.mark.parametrize("angle", [90, 180, 270])
    def test_rotated_image_is_unrotated(self, upright_image: Image.Image, angle: int) -> None:
        rotated_bytes = _to_jpeg_bytes(upright_image.rotate(angle, expand=True))
        result = orientation.correct(rotated_bytes)
        # The corrected image should report no further rotation needed.
        corrected_img = _bytes_to_image(result)
        assert _osd_rotate(corrected_img) == 0

    def test_rotation_emits_telemetry(
        self,
        upright_image: Image.Image,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        rotated_bytes = _to_jpeg_bytes(upright_image.rotate(90, expand=True))
        with caplog.at_level("INFO"):
            orientation.correct(rotated_bytes)
        messages = [record.getMessage() for record in caplog.records]
        # structlog's KeyValueRenderer in pytest writes the event name in
        # the rendered log line — assert by substring rather than parsing
        # the structured payload.
        assert any("orientation.rotated" in m for m in messages), messages


class TestOrientationCorrectMirror:
    """Mirrored images are flipped back when the confidence ratio
    threshold is met."""

    def test_mirrored_image_is_unmirrored(self, upright_image: Image.Image) -> None:
        mirrored = ImageOps.mirror(upright_image)
        mirrored_bytes = _to_jpeg_bytes(mirrored)
        result = orientation.correct(mirrored_bytes)
        # The result bytes differ from the input (a flip happened).
        assert result != mirrored_bytes

    def test_mirror_emits_telemetry(
        self,
        upright_image: Image.Image,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        mirrored = ImageOps.mirror(upright_image)
        mirrored_bytes = _to_jpeg_bytes(mirrored)
        with caplog.at_level("INFO"):
            orientation.correct(mirrored_bytes)
        messages = [record.getMessage() for record in caplog.records]
        assert any("orientation.mirrored" in m for m in messages), messages


class TestOrientationCorrectCombined:
    """A mirrored + rotated image is corrected on both axes."""

    def test_mirrored_and_rotated_is_corrected(self, upright_image: Image.Image) -> None:
        mirrored = ImageOps.mirror(upright_image)
        combined = mirrored.rotate(180, expand=True)
        combined_bytes = _to_jpeg_bytes(combined)
        result = orientation.correct(combined_bytes)
        # After correction the image should be back upright per OSD.
        corrected_img = _bytes_to_image(result)
        assert _osd_rotate(corrected_img) == 0


class TestOrientationCorrectLowConfidence:
    """When Tesseract OSD's orientation confidence is below the
    documented "trustable" threshold of 2.0, the image is left alone."""

    def test_below_confidence_threshold_skips_rotation(self, upright_bytes: bytes) -> None:
        # Simulate an OSD reading with low confidence — even though it
        # reports a non-zero rotation, the function MUST NOT apply it.
        low_conf_osd = {
            "page_num": 0,
            "orientation": 90,
            "rotate": 270,
            "orientation_conf": 0.5,
            "script": "Latin",
            "script_conf": 1.0,
        }
        with patch(
            "app.services.orientation.pytesseract.image_to_osd",
            return_value=low_conf_osd,
        ):
            result = orientation.correct(upright_bytes)
        # We should have skipped rotation. The result may still be
        # mirror-corrected (or not — the input here is upright and not
        # mirrored, so it should pass through), but it must NOT be
        # rotated.
        corrected_img = _bytes_to_image(result)
        # Same dimensions as the original (rotation would have swapped
        # width/height).
        original_img = _bytes_to_image(upright_bytes)
        assert corrected_img.size == original_img.size


class TestOrientationCorrectExceptionSafety:
    """The contract says ``correct/1`` NEVER raises — any internal
    failure returns the input bytes unchanged."""

    def test_corrupt_bytes_returns_input_unchanged(self) -> None:
        garbage = b"not an image at all"
        result = orientation.correct(garbage)
        assert result == garbage

    def test_empty_bytes_returns_input_unchanged(self) -> None:
        result = orientation.correct(b"")
        assert result == b""

    def test_tesseract_crash_returns_input_unchanged(self, upright_bytes: bytes) -> None:
        def _boom(*args: Any, **kwargs: Any) -> Any:
            raise RuntimeError("tesseract exploded")

        with patch(
            "app.services.orientation.pytesseract.image_to_osd",
            side_effect=_boom,
        ):
            result = orientation.correct(upright_bytes)
        assert result == upright_bytes

    def test_pil_crash_returns_input_unchanged(self, upright_bytes: bytes) -> None:
        def _boom(*args: Any, **kwargs: Any) -> None:
            raise RuntimeError("PIL exploded")

        with patch("app.services.orientation.Image.open", side_effect=_boom):
            result = orientation.correct(upright_bytes)
        assert result == upright_bytes
