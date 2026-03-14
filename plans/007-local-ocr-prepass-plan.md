# Plan: Local OCR Pre-pass for ISBN Extraction
**Issue**: #007
**Created**: 2026-03-14
**Status**: Approved

## Context
The vision sidecar currently sends every uploaded image to the Together AI VLM (Qwen2.5-VL via Modal GPU) for book identification. When a book has a clean barcode, this is wasteful — a local barcode decode takes milliseconds and costs nothing. This phase adds a `pyzbar`-based pre-pass that short-circuits the VLM call when a clean ISBN barcode is found, reducing API cost and latency for the common case.

## Research Summary
- `/extract` endpoint receives base64 images, validates them, then calls `VisionClient.extract()` (Modal GPU)
- `ExtractedBook` model already has a `confidence` field (hardcoded `0.0`) with a comment referencing Phase 1D.2
- `ExtractionResponse` has a `model_used` field — perfect for distinguishing `"local_ocr"` from VLM results
- Only the first image is processed by the VLM (`images_b64[0]`) — pre-pass should match this
- `Dockerfile.vision` exists as a multi-stage build; needs `libzbar0` added to runtime stage
- No existing OCR/barcode code in the codebase

## Approach Options
- **Option A (chosen):** `pyzbar` only — pure barcode decoding from image bytes. Zero system deps beyond `libzbar0`. Covers EAN-13/ISBN-13 barcodes cleanly. Simple, fast, no ML overhead. Recommended.
- **Option B:** `pyzbar` + `pytesseract` fallback — adds OCR for spine text when no barcode found. Requires `tesseract-ocr` system package (~120MB in Docker). Not recommended — issue explicitly excludes Tesseract; spine OCR is a separate problem.
- **Option C:** `python-barcode` + `zxing-cpp` — alternative barcode libraries. Not recommended — `pyzbar` is the community standard, well-tested, and the issue names it specifically.

## Phases

### Phase 1: Local OCR Pre-pass
**Objective**: Add pyzbar-based barcode scan that short-circuits VLM when a clean ISBN barcode is found
**Agent(s)**: python-agent
**Steps**:
1. Create `apps/vision/app/services/local_ocr.py`:
   - `local_isbn_scan(image_bytes: bytes) -> str | None`
   - Decode image with Pillow, scan with pyzbar
   - Validate decoded data is a valid ISBN-10 or ISBN-13 (length + check digit)
   - Return ISBN string on success, `None` on any failure (never raise)
2. Add config fields to `apps/vision/app/config.py`:
   - `local_ocr_enabled: bool = True`
   - `local_ocr_confidence_threshold: float = 0.9`
3. Insert pre-pass in `apps/vision/app/main.py` `/extract` endpoint:
   - After base64 validation, before VisionClient.extract()
   - If `local_ocr_enabled` and `local_isbn_scan(decoded_bytes)` returns an ISBN:
     - Return `ExtractionResponse` immediately with `confidence=1.0`, `model_used="local_ocr"`, `potential_isbns=[isbn]`
   - Otherwise fall through to VLM path unchanged
4. Add `pyzbar` and `Pillow` to `apps/vision/requirements.txt`
5. Add `libzbar0` to `deploy/Dockerfile.vision` runtime stage
6. Create `apps/vision/tests/test_local_ocr.py`:
   - Clean ISBN-13 barcode → returns ISBN string
   - Clean ISBN-10 barcode → returns ISBN string
   - Non-ISBN barcode (e.g. UPC) → returns None
   - No barcode in image → returns None
   - Corrupt/invalid image bytes → returns None (no exception)
   - Invalid ISBN check digit → returns None
7. Add integration tests to `apps/vision/tests/test_extraction.py`:
   - Pre-pass hit: VLM skipped, `model_used="local_ocr"`, `confidence=1.0`
   - Pre-pass miss: falls through to VLM, `model_used=settings.model_name`
   - `local_ocr_enabled=False`: VLM always called regardless of barcode

**Test Command**: `cd apps/vision && .venv/bin/pytest tests/ -v`
**Lint Command**: `cd apps/vision && .venv/bin/ruff check . && .venv/bin/ruff format --check .`

**DoD Items**:
- [ ] `local_isbn_scan(image_bytes)` returns a valid ISBN string when a barcode is present, `None` otherwise
- [ ] `local_isbn_scan` returns `None` (not raises) on any error: corrupt image, no barcode, unrecognised format
- [ ] `/extract` short-circuits VLM call when `local_isbn_scan` returns a result
- [ ] `/extract` falls through to VLM unchanged when `local_isbn_scan` returns `None`
- [ ] `local_ocr_enabled = False` disables the pre-pass entirely
- [ ] `model_used` is `"local_ocr"` on pre-pass hits, `settings.model_name` on VLM path
- [ ] Tests cover: clean barcode → pre-pass hits, VLM skipped; no barcode → falls through; corrupt image → falls through; `local_ocr_enabled=False` → VLM always called
- [ ] `deploy/Dockerfile.vision` installs `libzbar0` system package
- [ ] `ruff check` and `ruff format --check` pass
- [ ] `mypy --strict` passes

## Open Questions
None — the issue is well-specified and the codebase is ready.

## Integration Handoffs
None — single-agent, single-phase issue. The upstream consumer (Elixir core's `IdentifyBookJob`) already handles `potential_isbns` in the extraction response and does not need changes.
