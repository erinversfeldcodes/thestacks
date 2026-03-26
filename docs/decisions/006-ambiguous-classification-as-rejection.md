# Decision 006: Ambiguous Classification Treated as Permanent Rejection

**Status:** Accepted
**Date:** 2026-03-26
**Context:** Issue #133

---

## Decision

When the vision model returns `CLASSIFICATION_RESULT_AMBIGUOUS` for a cover image, the
association is rejected with `reason = "ambiguous_classification"`. No automatic retry
is scheduled. The user may re-upload a clearer image.

## Context

`CLASSIFICATION_RESULT_AMBIGUOUS` is a first-class enum value in `vision.proto`. It means
the model was uncertain (e.g., blurry photo, partial spine). Previously it was collapsed
into `reason = "not_a_book_cover"`, indistinguishable from a definitive non-book.

## Rationale

- Re-upload is a natural recovery path for blurry photos — no infrastructure needed.
- Automatic retry loops risk hammering the vision service on consistently ambiguous images.
- Human review queues add operational overhead not justified at current scale.
- The distinct `reason` string means we can always change this behaviour later without a
  wire format change.

## Consequences

- Core receives `ASSOCIATION_STATUS_REJECTED` with `reason = "ambiguous_classification"`.
- The rejected handler logs the reason — operators can monitor log volume for this reason.
- Future work: if ambiguous rates are high, emit a telemetry event on this reason to make
  retry or review decisions data-driven.
- `reason = "not_a_book_cover"` now exclusively means the model was confident it is not
  a book cover.
