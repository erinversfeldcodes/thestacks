# Issue #169: Selective vision verification pass for low-confidence extractions

## Summary
The vision pipeline can confidently misidentify books on ambiguous
inputs. Observed failure: `screenshot_image_reversed_and_cut_off.jpg`
(Train to Crystal City) — the 72B returned `"The Chinese Crystal Ball"`
by `"Dr. Pelham K. Mead III"` (an invented author name). The model
produced an answer-shaped output rather than admitting uncertainty.

This issue adds a **selective verification pass** that runs ONLY when
the first-pass extraction returns books with confidence below a
threshold. For uncertain candidates, the pipeline:

1. Title-searches to fetch candidate cover URLs from Open Library / Google Books.
2. Calls the VLM with `{uploaded_image, candidate_cover}` pairs and asks
   "are these the same book?".
3. Picks the highest-verified candidate above the verification threshold,
   or rejects as `:uncertain` if none verify.

High-confidence first-pass identifications skip verification entirely —
the common-case latency is unchanged.

## User Stories
N/A (platform / vision accuracy).

## Goal
- First-pass extractions with `confidence >= 0.7` flow through unchanged.
- Extractions with `confidence in [0.3, 0.7)` trigger one or more
  verification calls; the verified ISBN is used downstream.
- All-candidates-below-threshold uploads are rejected as `:uncertain`
  rather than silently committing to a wrong book.
- Verification latency budget: <8 s per upload in the uncertain branch
  (typical: 1 candidate × 2-4 s).

## Scope Check
- New sidecar endpoint: `POST /verify` accepting two image URLs (or one
  + reference URL) and returning a same-book confidence.
- Extends `Stacks.Moderation` flow with confidence-gated branch.
- One new proto message pair: `VerifyRequest`, `VerifyResponse` in
  `proto/stacks/internal/v1/vision.proto`.
- ~300 LOC production + tests across Python (sidecar) and Elixir (core).
- One concern: confidence-gated verification. No bundled scope.

## Wiring
- [x] Implementation only. No router or UI changes.

## Technical Requirements

### Vision sidecar — `POST /verify`

Request body (proto-validated `VerifyRequest`):
```
{
  "uploaded_image_url": "https://r2…/uploads/<id>",
  "candidate_cover_url": "https://covers.openlibrary.org/…",
  "candidate_isbn": "9781476732123"   // for logging/telemetry
}
```

Response body (proto-validated `VerifyResponse`):
```
{
  "is_same_book": true,
  "confidence": 0.92,
  "reasoning": "Cover artwork and partial visible title match…"
}
```

Internally: download both images, feed them to the VLM with a verify-
specific prompt ("STEP 1: orient both. STEP 2: compare illustration
style, title text, author text. STEP 3: are these the same book?
Reply with strict JSON `{is_same_book, confidence, reasoning}`").

HMAC-authenticated identically to `/analyze`. Same circuit breaker, same
budget controls.

### Core — confidence-gated branch in `Stacks.Moderation`

In `resolve_and_store/3` (or equivalent), after the analyze response:

1. Compute `max_confidence = candidates |> Enum.map(& &1["confidence"]) |> Enum.max(fn -> 0 end)`.
2. If `max_confidence >= verification_threshold_high` (default 0.7): proceed
   as today. No verification call.
3. If `max_confidence in [verification_threshold_low, verification_threshold_high)`
   (default `[0.3, 0.7)`): trigger verification.
4. If `max_confidence < verification_threshold_low`: reject as
   `:uncertain` immediately. Skip title-search. Skip verification.

Verification flow:
- For each candidate with confidence in the verification band:
  - Title-search to get candidate ISBN + cover URL (use existing
    `ISBNResolver.search_by_title/3`).
  - Call `VisionClient.verify(uploaded_image_url, cover_url, isbn)`.
- Pick the candidate with the highest `verify_response.confidence` if
  `is_same_book && confidence >= verification_threshold_match`.
- If no candidate clears the threshold: reject as `:uncertain`.

### Config

- `:core, :verification_threshold_high` (default 0.7)
- `:core, :verification_threshold_low` (default 0.3)
- `:core, :verification_threshold_match` (default 0.7) — the threshold
  the verify response itself must clear

All three are calibration knobs; threshold defaults are best guesses.
First production deploy informs tuning.

### Telemetry

- `[:stacks, :verification, :triggered]` — counter, metadata: `isbn`, `first_pass_confidence`
- `[:stacks, :verification, :match]` — counter, metadata: `isbn`, `verify_confidence`
- `[:stacks, :verification, :rejected]` — counter, metadata: `reason: :no_match | :uncertain`

## Reviewer Context
- The new `/verify` endpoint runs on the same Modal GPU as `/analyze`.
  It shares the H100 budget. Under burst load both endpoints contend
  for the same pool — `max_inputs=2` per container caps the contention.
- Don't try to merge `/verify` into `/analyze` as a "two-mode" endpoint.
  Different inputs (one image vs two), different output schemas, and
  different prompts. Keep them separate for clarity.
- The verification prompt is NEW — it lives next to `_ANALYZE_PROMPT`
  in `modal_app.py`. Same anti-confabulation language ("if you cannot
  tell, return `is_same_book: false`"); shorter than `_ANALYZE_PROMPT`
  since it only needs to do same-book comparison.
- The `:uncertain` rejection reason is new. Update the upload UI's
  error mapping to distinguish it from `:not_a_book` and
  `:isbn_not_found` — likely "We're not sure which book this is —
  try a clearer photo or enter the ISBN manually."

## Definition of Done

- [ ] `proto/stacks/internal/v1/vision.proto`: `VerifyRequest`, `VerifyResponse` added.
- [ ] Vision sidecar `POST /verify` endpoint exists, HMAC-gated, returns proto-validated response.
- [ ] New `_VERIFY_PROMPT` in `modal_app.py`; same JSON-strict pattern as `_ANALYZE_PROMPT`.
- [ ] `Stacks.Moderation` confidence-gated branch implemented with documented thresholds.
- [ ] Config keys (`:verification_threshold_*`) read from `:core` app config with defaults.
- [ ] Telemetry events emitted on triggered / match / rejected paths.
- [ ] `:uncertain` rejection reason plumbed through to the upload UI's error mapping.
- [ ] Tests:
  - High-confidence path: no `/verify` call (assert via telemetry handler).
  - Low-confidence + verify match: correct ISBN selected.
  - Low-confidence + no verify match: `:uncertain` rejection.
  - Below `verification_threshold_low`: immediate `:uncertain` rejection (no `/verify` call).
- [ ] E2E: `Crystal City` test passes on preview deploy (verification correctly picks the right candidate from the title-search list).
- [ ] No regression on high-confidence E2E (`Born Again Bodies`, barcode tests).
- [ ] Standards compliance verified.

## Dependencies
- Depends on #167 (low-confidence extractions deprioritised) — same
  confidence signal feeds both this issue's gate AND #167's skip.
  Already merged.
- Independent of #168 (orientation correction).

## Agent Assignment
python-agent (sidecar `/verify` endpoint + prompt) +
elixir-agent (core branching + config + telemetry) +
protobuf-agent (proto message additions).

## Progress Notes
None yet.
