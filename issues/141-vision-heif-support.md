# Issue #141: Vision service — accept HEIF/HEIC uploads

## Summary
`Core.AI.Client` forwards user-uploaded images to the Modal vision service, which opens them with PIL/Pillow. PIL doesn't read HEIF/HEIC (the default photo format on iOS 11+) without the `pillow-heif` plugin, so every iPhone photo that lands in the upload pipeline hits a 502:

```
%{status: 502,
  body: "{\"detail\":\"Vision model request failed: cannot identify image file <_io.BytesIO object at 0x...>\"}"}
```

Result: an entire class of real-user uploads fails silently from the operator's perspective (job retries, eventually times out, user sees "upload timed out" with no reason).

## User Stories
US-11.1 (upload a cover photo) — broken for ~60% of potential users (iOS market share).

## Goal
A user who uploads a photo straight from their iPhone camera roll gets the same terminal outcome (`resolved` | `rejected`) as they would from a JPG/PNG. No surprise 502 or "cannot identify image file".

## Scope Check
- One controller touched (none; change is in `apps/vision/`) ✓
- No new endpoints ✓
- ~50 LOC plus a test fixture ✓

## Wiring
- [ ] Implementation only. The calling paths in core (`Stacks.AI.Client`,
  `Stacks.Workers.IdentifyBookJob`) already forward whatever bytes the
  user uploads; no core-side change needed.

## Technical Requirements

1. **Add `pillow-heif` to `apps/vision/pyproject.toml`** (or the
   equivalent dependency manifest the service uses). Pinned to a
   known-stable version.

2. **Register the HEIF opener at service startup**, e.g. in the FastAPI
   lifespan hook:

   ```python
   from pillow_heif import register_heif_opener
   register_heif_opener()
   ```

   After this, `PIL.Image.open(BytesIO(heif_bytes))` transparently
   works for HEIC/HEIF inputs — no change to downstream classification
   or ISBN-extraction code.

3. **Add a HEIF fixture** to the vision service's test suite (a small
   book-cover HEIC file is ideal). Assert the `/classify` and
   `/extract` endpoints process it without 502.

4. **Bonus**: surface the input format in the response JSON so future
   debugging doesn't require sniffing the upload bytes again. Cheap at
   this layer.

## Reviewer Context
- Modal builds the vision service image from `apps/vision/` on each
  deploy; adding `pillow-heif` to the dependency manifest is all the
  operator action required. No Fly / core change.
- `pillow-heif` pulls in `libheif` at install time — verify the Modal
  builder still produces a working image. If `libheif` isn't available
  in Modal's base image, switch to a Debian/Ubuntu base that includes
  it (or install via apt in the build step).
- Discovered 2026-04-19 during SLO gate work: the dual-canary upload
  probe added `images/photo.PNG` as its "real book" canary, which
  turned out to be HEIF-with-a-misleading-extension. The vision
  service rejected every upload → 86% `oban_failure_rate_vision`
  breach on the gate. Short-term fix (2026-04-19): probe was switched
  to `images/barcode_isbn_clean.jpg` so the gate can pass while this
  issue is outstanding.

## Definition of Done
- [ ] `pillow-heif` in the vision service's dependency manifest
- [ ] HEIF opener registered at startup
- [ ] HEIF test fixture asserts `/classify` returns a terminal outcome
- [ ] HEIF test fixture asserts `/extract` returns a terminal outcome
- [ ] Manual verification: re-add `images/photo.PNG` to the SLO gate
  probe (or a fresh HEIF canary) and confirm the gate stays green

## Dependencies
- None. Issues #136, #139, #140 (SLO gate honesty) already surface
  this class of failure loudly — #141 closes the input-format gap.

## Agent Assignment
python-agent (vision service) for implementation; platform-agent for
the canary re-swap + gate verification.

## Progress Notes
2026-04-19: Filed after SLO gate investigation showed vision 502-ing
on HEIF uploads. Short-term mitigation (gate canary → JPG) landed in
the same session; this issue is the structural fix.
