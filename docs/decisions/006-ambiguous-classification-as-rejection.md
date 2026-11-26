# Decision 006: Ambiguous Classification Treated as Permanent Rejection

**Status:** Superseded by Decision 015 (2026-10-15) — the mechanism this decision governed no longer exists
**Date:** 2026-03-26
**Context:** Issue #133

---

> ⚠️ **Superseded, and kept as history rather than deleted.**
>
> This decision governed the cover-**association** flow: an asynchronous job that
> classified a cover image and reported `ASSOCIATION_STATUS_REJECTED` with
> `reason = "ambiguous_classification"` back to the core via a callback. On
> 2026-10-15 that whole loop was deleted, because nothing ever started such a
> job — the endpoint that would have created one had no caller in any revision,
> so no callback could ever arrive and no ambiguous classification was ever
> acted on by this rule.
>
> **What survives is the reasoning, and it is worth keeping.** The argument below
> — that an ambiguous answer from the model is a determination rather than a
> transient fault, and so must not be retried — still applies to the surviving
> `/analyze` path, which returns `CLASSIFICATION_RESULT_AMBIGUOUS` from the same
> enum. Whoever rebuilds cover verification should read this before deciding how
> to treat that value, and should not re-derive the retry question from scratch.
>
> What is NO LONGER TRUE below: the `ASSOCIATION_STATUS_REJECTED` callback, the
> `reason` string reaching the core, and anything describing a background job.
> The association wire contract itself is deliberately retained in
> `proto/stacks/internal/v1/vision.proto` for the vision redesign.

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
