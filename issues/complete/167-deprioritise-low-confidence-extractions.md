# Issue #167: Deprioritise low-confidence vision extractions before enrichment

## Summary
The vision model now returns a per-book `confidence` score (0.0–1.0) on every
`ExtractedBook`. `EnrichBookJob` currently treats every extracted candidate as
equally trustworthy and hits Google Books / Open Library for each one. Low-
confidence guesses inflate external API call volume, increase the chance of
hitting 503 rate limits, and waste retry budget on candidates the model itself
flagged as weak.

This issue makes enrichment confidence-aware: candidates with
`confidence < 0.5` are deprioritised (or skipped) before external lookups.

## User Stories
N/A (platform / reliability).

## Goal
- Enrichment ordering reflects model confidence: high-confidence candidates
  consume external API budget first.
- Candidates with `confidence < 0.5` are either skipped entirely or attempted
  only after all higher-confidence candidates resolve (decision to be made
  during implementation — measure first).
- Observable: a `[:stacks, :enrichment, :candidate, :skipped]` (or similar)
  telemetry event records skipped/deferred candidates with their confidence.
- No regression on candidates without a `confidence` value — treat missing as
  the historical "process normally" behaviour, but flag for follow-up if the
  prompt ever stops emitting it.

## Scope Check
- One context function change: `EnrichBookJob` candidate selection logic.
- Zero new endpoints, zero DB migrations, zero Elm changes.
- Likely <100 LOC of production code + tests.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. No wiring needed.

## Technical Requirements
- Read `confidence` from `ExtractedBook` payload (already plumbed through the
  proto contract in `proto/stacks/internal/v1/vision.proto:77`).
- Threshold `0.5` is a starting point — confirm with one E2E run / canary
  measurement before locking in. A configurable threshold via app config is
  acceptable but not required.
- If skipping rather than deferring, ensure the audit log / event log still
  records that a candidate was observed (we may want it for later
  re-processing or training data).
- The vision prompt (`_ANALYZE_PROMPT` in `apps/vision/modal_app.py`) instructs
  the model to use 0.9+ only when title AND author are clearly legible, and
  to populate even on `ambiguous` classifications. Confidence ranges should
  be calibrated against real outputs before tuning the threshold.

## Reviewer Context
- `EnrichBookJob` retries up to 5 times on Oban; the cost of letting low-
  confidence candidates burn retries is amplified vs. a single-shot API call.
- Google Books returns 503 under load — observed during the E2E run on
  2026-05-14, where `EnrichBookJob` retries exhausted and a book was left
  with placeholder title `"ISBN XXXXXXXXXX"`.

## Definition of Done
- [ ] `EnrichBookJob` reads per-candidate `confidence` and applies threshold
      logic (skip OR defer).
- [ ] Telemetry event emitted for skipped/deferred candidates.
- [ ] Test covers: high-confidence processed first, low-confidence skipped or
      deferred, missing-confidence handled as historical behaviour.
- [ ] Threshold value confirmed by at least one calibration run against real
      vision output.
- [ ] Tests written and passing.
- [ ] Standards compliance verified (`just verify` passes).

## Dependencies
Depends on the new `_ANALYZE_PROMPT` (introduced 2026-05-15) which adds the
per-book `confidence` field. Without prompt v2 deployed, `confidence` is
absent from every payload and the skip path is dead code.

## Agent Assignment
elixir-agent (single context change in `Stacks.Books` / `EnrichBookJob`).

## Progress Notes
None yet.
