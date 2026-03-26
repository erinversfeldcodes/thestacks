# Issue #133: Ambiguous Classification Product Decision — Document and Surface to Core

## Priority: P2 Medium

## Problem

`CLASSIFICATION_RESULT_AMBIGUOUS` is now a first-class proto enum value, but the Python vision service collapses it to `ASSOCIATION_STATUS_REJECTED` with `reason = "not_a_book_cover"` — the same value used for a definitive `CLASSIFICATION_RESULT_NOT_BOOK`. Core (`internal_controller.ex`) has no way to distinguish an ambiguous classification (model was unsure) from a definitive rejection (model was confident it is not a book).

The comment in `main.py:143` acknowledges this and suggests a future `"ambiguous_classification"` reason string, but:
1. The product decision has not been made or documented.
2. Core currently ignores the `reason` field for rejected associations entirely (the `dispatch_association/2` REJECTED clause only logs a warning — it does not branch on `reason`).
3. The test `test_run_associate_ambiguous_path` asserts `reason == "not_a_book_cover"`, cementing the ambiguous-equals-rejected behaviour as a tested invariant — changing this later will require coordination.

## Impact

If a book cover image is ambiguous (e.g., blurry spine photo), it is silently treated as a non-book and the association is dropped. There is no mechanism for operators or the system to retry ambiguous cases, flag them for human review, or provide user feedback ("we couldn't read this image clearly, please try again").

## Evidence

- `apps/vision/app/main.py:141–144` — ambiguous maps to `_STATUS_REJECTED` with `reason = "not_a_book_cover"`.
- `apps/core/lib/stacks_web/controllers/internal_controller.ex:115–127` — REJECTED handler ignores `reason` field entirely.
- `apps/vision/tests/test_association.py:204–229` — `test_run_associate_ambiguous_path` cements this behaviour.
- `proto/stacks/internal/v1/vision.proto:16` — `CLASSIFICATION_RESULT_AMBIGUOUS` exists as a first-class enum value but is never surfaced to core.

## Suggested Fix

1. Make a product decision: should ambiguous classifications be retried, queued for human review, or treated as permanent rejections?
2. If retrying is the answer: change `reason` for ambiguous to `"ambiguous_classification"` and add an Oban retry job in core when it receives this reason.
3. If human review is the answer: emit an event when `reason == "ambiguous_classification"` is received.
4. If permanent rejection: document this explicitly in the proto comment on `CLASSIFICATION_RESULT_AMBIGUOUS` and close the issue.
5. Update `test_run_associate_ambiguous_path` to assert the correct `reason` string once the decision is made.

## Agent Assignment

orchestrator (product decision first), then elixir-agent + python-agent

## Definition of Done

- [ ] Product decision documented in `docs/decisions/` or `docs/technical-architecture.md`
- [ ] `reason` field for ambiguous classification is distinct from definitive rejection
- [ ] Core handles ambiguous reason appropriately (retry, queue, or documented no-op)
- [ ] Tests updated to reflect the decision
