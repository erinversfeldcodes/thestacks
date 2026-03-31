# Retrospective: Complete Implementation Gaps
**Issue**: #138–#152 (14 sub-issues)
**Date**: 2026-03-31
**Phases completed**: 14
**Agents involved**: orchestrator, elixir-agent, elm-agent

---

## What Worked Well

- **Sequencing held.** 14 phases, zero blocking dependency surprises. The ordering — standalone features first, dependency chains (groups, partner), structural risk (physical shelf migration), then cross-cutting (notifications) — never needed resequencing.
- **Gate checkpoints.** `just verify` caught format/lint issues before they accumulated. No accumulated debt at the end: 1598 tests, 0 failures, 13/13 E2E tests passing against the deployed PR stack.
- **Mid-plan scope adjustment.** Collapsing #143/#144 into a single Elm-only phase (contact-info listing, no offer threads) when the marketplace backend was confirmed complete was the right call and was captured with a scope note. No friction downstream.
- **Cross-cutting concerns section.** The explicit per-phase reminders about proto sync, migration safety, and dbt staging models meant nothing was accidentally skipped across 14 phases.
- **Fly logs as a debugger.** Once consulted, Fly logs resolved the non-book rejection investigation in one line (`IdentifyBookJob: rejected image ... (not_a_book)`). The backend was never the problem.

---

## What Caused Friction

- **The non-book rejection E2E test required three red-herring investigations before finding the root cause.** The test expected "Doesn't Look Like a Book" but received "Could Not Identify Book". We investigated in order: (1) stale Modal GPU containers with old prompts, (2) whether R2 presigned URL path vs direct base64 differed in what the model received, (3) whether the test image was ambiguous. All were red herrings. The actual bug was three lines in `Upload.elm`: the `Rejected` poll handler ignored `rejectionReason` and always set `IdentificationFailed` regardless of whether the reason was `not_a_book`. Fly logs would have confirmed backend correctness in the first five minutes.

- **Phase 14 DoD review was not thorough on first pass.** The orchestrator initially declared Phase 14 complete. A user challenge prompted a proper DoD review, which found that the implementation used `notify_marketplace` where the DoD specified `notify_offers`. The broader name was the better design (covers both `new_offer` and `marketplace_sale` templates), but the deviation was undocumented. It should have been flagged at implementation time, not at plan close.

- **The state file was never maintained.** `plans/chore-complete-implementations-state.json` existed with all phases showing "pending" from start to finish. It provided no value.

- **Issue files were moved in batches, not per-phase.** Most files were still in `issues/` at the end of the plan rather than being moved to `issues/complete/` as each phase closed.

---

## What Should Change in the Agent System

| File | Change | Addresses |
|------|--------|-----------|
| `docs/agents/orchestrator-agent.md` | When an E2E test fails against a deployed stack, make "check server logs first" the explicit first step — not a fallback after other investigations. Log inspection (Fly logs, application error logs) can immediately confirm whether the server layer is working, preventing multi-step client-side investigation when the bug is in the client. | Non-book rejection red herring chain |
| `docs/agents/orchestrator-agent.md` | Phase close DoD review must be a line-by-line checklist, not a summary judgement. For each DoD bullet: (1) name the test or behaviour that demonstrates it, (2) note any deviation from the specified naming or behaviour. Deviations must be confirmed intentional before the phase closes. | Phase 14 `notify_marketplace` vs `notify_offers` |
| `docs/agents/orchestrator-agent.md` | Move the corresponding issue file to `issues/complete/` as part of the phase close step, not deferred to end-of-plan cleanup. | Issue files batched at end |
| `plans/retro-template.md` | Add a note: if the plan specifies a state file, it must be updated at the end of every phase. If that discipline won't hold in practice, omit the state file entirely. A stale state file is worse than no state file. | State file abandoned |
| `docs/agents/elm-agent.md` | When implementing a poll response handler that branches on a status enum, assert in the test that each distinct status value produces the correct model state. A single "Rejected sets result to X" test is insufficient if the handler has sub-branches (e.g. `rejectionReason`). | `Rejected` handler ignored `rejectionReason` |

---

## Suggested Issues

- [ ] Elm poll handler sub-branch test coverage — add DoD requirement to elm-agent standards: any update branch that pattern-matches on a nested value must have a test for each branch, not just the outer constructor
- [ ] Audit existing E2E tests for cases where server-side logic is the implementation and the test was written assuming a particular client-visible symptom — similar gaps to the `not_a_book` case may exist in other specs
