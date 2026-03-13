# Issue #007: Local OCR Pre-pass for ISBN Extraction

## Summary
Add an in-process barcode/OCR scan to the vision sidecar before calling the Together AI VLM. When a barcode is cleanly readable locally, skip the VLM entirely — reducing API cost and latency for the common case. This is Phase 1D.2 of the consolidated roadmap.

## User Stories
- US-1.1.1 — Photo upload triggers book identification pipeline

## Goal
Implement a fast, cheap local barcode decode step that short-circuits the VLM call when a clean ISBN barcode is present. The VLM remains the fallback for all other cases — spine text, cover art, oblique shots, worn barcodes. The pre-pass is additive and model-agnostic: if it finds nothing, the sidecar behaves identically to today.

## Technical Requirements

See roadmap: `plans/consolidated-roadmap.md` § Phase 1D.2.

**Implementation** (in-process, no new service):

Add `pyzbar` (pure-Python barcode decoder, no system dependency for basic use) and `Pillow` to `requirements.txt`. `pyzbar` decodes ISBN barcodes directly from image bytes without Tesseract. Add `pytesseract` as a secondary fallback only if pyzbar returns nothing — but consider whether the added system dependency (`tesseract-ocr` apt package) is worth the marginal gain before including it.

**New function** `local_isbn_scan(image_bytes: bytes) -> str | None` in `app/services/local_ocr.py`:
- Decode image bytes with Pillow
- Attempt barcode decode with pyzbar
- If a barcode is found and its data is a valid ISBN-10 or ISBN-13, return the ISBN string
- Otherwise return `None`
- All failures are silent — never raise; always return `None` on any exception

**Modified endpoint** `POST /extract` in `app/main.py`:
- If `local_ocr_enabled` is True, call `local_isbn_scan(decoded_image_bytes)` on the first image
- If a result is returned, construct and return an `ExtractionResponse` immediately without calling Together AI (`potential_isbns=[isbn]`, `title=None`, `author=None`, `raw_text=None`, `model_used="local_ocr"`, `confidence=1.0`)
- If `None` is returned, fall through to the existing VLM path unchanged

**New config fields** in `app/config.py`:
- `local_ocr_enabled: bool = True` — escape hatch to disable without redeploying
- `local_ocr_confidence_threshold: float = 0.9` — reserved for future use if a scored decoder is added

**Files:**
- `apps/vision/app/services/local_ocr.py` — barcode scan function
- `apps/vision/app/config.py` — two new settings fields
- `apps/vision/app/main.py` — pre-pass logic in `/extract`
- `apps/vision/tests/test_local_ocr.py` — unit tests for `local_isbn_scan`
- `apps/vision/requirements.txt` — add `pyzbar`, `Pillow`
- `deploy/Dockerfile.vision` — add `libzbar0` apt package (pyzbar runtime dependency)

**Constraints:**
- Local OCR failure must never surface as an error — silent fallback only
- `local_ocr_enabled = False` must completely bypass the pre-pass with no side effects
- `model_used` field in the response should be `"local_ocr"` when the pre-pass succeeds, so callers can distinguish VLM results from local results
- Do not add Tesseract as a dependency in this issue — pyzbar covers the barcode case cleanly; text OCR (for spine-only images) is a separate, larger problem

## Definition of Done
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

## Dependencies
- Issue #003 merged (vision sidecar implemented)

## Feeds back into
- Issue #005 (vision model evaluation framework) — once implemented, run a benchmark experiment comparing pre-pass+VLM pipeline against VLM-only. This is a new experiment config TOML, not a code change.

## Agent Assignment
- **python-agent** (`docs/agents/python-agent.md`)
- **Reviewer**: python-reviewer (`docs/agents/reviewers/python-reviewer.md`)
- **Model**: Sonnet 4.6

## Progress Notes
<!-- Updated by agents during execution -->
