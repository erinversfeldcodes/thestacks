# Issue #168: Programmatic orientation correction in the vision sidecar

## Summary
The vision pipeline can't reliably read mirrored or rotated book covers
even with explicit prompt guidance. Qwen2.5-VL-72B's vision encoder isn't
trained on mirrored text and treats horizontally-flipped covers as
unrecognisable. Failures observed: `screenshot_image_reversed.jpg`,
`screenshot_image_reversed_and_cut_off.jpg`. Prompt tightening alone
plateaued — we need preprocessing.

This issue adds programmatic orientation detection (rotation + mirror)
in the sidecar BEFORE the VLM call, so the model always sees an upright,
non-mirrored image.

## User Stories
N/A (platform / vision reliability).

## Goal
- Rotated covers (90 / 180 / 270 degrees) are auto-corrected before VLM.
- Horizontally mirrored covers are auto-corrected before VLM.
- Pipeline overhead capped at <150 ms CPU per image; zero extra GPU cost.
- Upright, non-mirrored images pass through unchanged.

## Scope Check
- New module: `apps/vision/app/services/orientation.py`.
- One integration point: `/analyze` endpoint in `apps/vision/app/main.py`,
  immediately before the local OCR pre-pass.
- Zero core changes, zero proto changes, zero Elm changes.
- Adds `tesseract-ocr` apt package to the Modal FastAPI image.
- ~200 LOC production + ~150 LOC test fixtures.

## Wiring
- [x] Implementation only. No router or UI changes.

## Technical Requirements

### Detection strategy

**Rotation** (0/90/180/270): use Tesseract OSD (orientation + script
detection). Returns `(angle, confidence)`. Apply the inverse rotation
when `confidence >= 2.0` (Tesseract OSD's documented "trustable"
threshold). Below threshold, leave the image alone.

**Mirror**: Tesseract doesn't detect mirroring directly. Strategy:
1. Run Tesseract `image_to_data` on the upright candidate.
2. Run again on a horizontally-flipped variant.
3. Compare aggregated word-detection confidence. If the flipped variant
   scores ≥2× higher, treat the original as mirrored.

Total cost: 2-3 Tesseract calls, ~50-150 ms CPU on a modern x86 runner.

### Integration

In `apps/vision/app/main.py`'s `/analyze` handler, after loading the
image bytes but BEFORE the local OCR pre-pass:

```python
oriented_bytes = orientation.correct(image_bytes)
# … local OCR + VLM both run on oriented_bytes from here on
```

`correct/1` returns the (possibly-modified) bytes. Includes a structured
log line so we can observe how often correction fires in prod.

### Telemetry

Two new events to the existing sidecar `structlog` output:
- `orientation.rotated` with `angle`, `confidence`
- `orientation.mirrored` with `confidence_ratio`

We'll dashboard correction frequency to know whether the heuristic is
firing on real uploads.

## Reviewer Context
- `tesseract-ocr` apt-package needs to be in the `_fastapi_image` only —
  the orientation module runs in the FastAPI container, NOT the GPU
  VisionModel container. Don't bloat the GPU container.
- Mirror detection is the wobbly half of this. If it misfires on
  borderline cases (e.g. a screenshot with mostly numeric text), we
  should leave the image alone — `flipped_confidence >= 2× original`
  is a conservative threshold for exactly this reason.
- The 30-day image retention policy still applies — corrected images
  are not stored separately; they're a transient transform inside
  `/analyze`.
- Tesseract OSD requires the `osd` traineddata file (`tesseract-ocr-osd`
  apt package on Debian). Check that Modal's debian_slim base ships it
  or install it explicitly.

## Definition of Done

- [ ] `apps/vision/app/services/orientation.py` exists with `correct/1` and
      unit tests for: upright (no change), 90°, 180°, 270°, mirrored, mirrored
      + rotated, and below-confidence cases.
- [ ] `/analyze` calls `orientation.correct/1` before local OCR + VLM dispatch.
- [ ] `tesseract-ocr` (and `tesseract-ocr-osd` if not bundled) added to
      `_fastapi_image` apt_install in `modal_app.py`.
- [ ] Two telemetry events emitted; visible in sidecar structured logs.
- [ ] E2E tests: `Flyboys` and `Crystal City` upload tests pass on the
      preview deploy after this change (assuming the 72B + new prompt remain
      in place).
- [ ] No regression on the upright-cover E2E tests (`Born Again Bodies`,
      `The Name of the Rose` via barcode).
- [ ] Tests written and passing.
- [ ] Standards compliance verified.

## Dependencies
None. Independent of #169.

## Agent Assignment
python-agent (primary) + platform-agent (Modal image dep addition).

## Progress Notes
None yet.
