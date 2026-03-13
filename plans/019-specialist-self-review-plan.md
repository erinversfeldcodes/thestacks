# Plan: Specialist Self-Review Before Handoff
**Issue**: #019
**Created**: 2026-03-13
**Status**: Approved

## Context
Mechanical review failures (missing typespecs, unformatted code, missing event emissions) currently survive to the reviewer, causing avoidable revision cycles. This issue adds a self-review step where specialists check mechanical axes before submitting their completion report, freeing reviewers to focus on judgment calls (alternative approaches, security threat model, forward compatibility, architectural fit).

## Research Summary
All 7 reviewers have 9 axes (0–8). Axes fall into two categories: mechanical (verifiable by running commands or checking patterns) and judgment (requiring domain expertise or subjective assessment). The split is consistent across reviewers: Axes 0, 2, 3, 5, 7 are primarily mechanical; Axes 1, 6, 8 are judgment; Axes 4 is mixed. Specialist completion reports currently have 5–6 items depending on the agent.

## Approach Options
- **Option A (chosen):** Self-Review subsection in specialists + mechanical/judgment tagging in reviewers — matches the issue spec, no content duplication. Recommended.
- **Option B:** Embed reviewer checklists directly in specialist docs — duplicates content, maintenance burden. Not recommended.
- **Option C:** Separate pre-review agent — over-engineered for a checklist step. Not recommended.

## Phases

### Phase 1: Specialist Agent Updates
**Objective**: Add Self-Review subsection and update completion report format for all 10 specialist agents
**Agent(s)**: platform-agent
**Steps**:
1. For each specialist, add a "Self-Review" subsection in Orchestrator Integration, after Test-First Protocol and before Completion Report Format
2. Content instructs: load your stack's reviewer doc, run through mechanical axes, fix failures, include Self-Review table in completion report
3. List the specific mechanical axes per stack (e.g., elixir: mix format, credo, sobelow, typespecs, event emission)
4. Update completion report format to add a Self-Review section as the final numbered item
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] All specialist agent docs updated with Self-Review subsection
- [ ] All specialist completion report formats updated with Self-Review section

### Phase 2: Reviewer Updates
**Objective**: Tag axes as mechanical/judgment and add spot-check guidance for self-reviewed axes
**Agent(s)**: platform-agent
**Steps**:
1. For each reviewer, add a tag after each axis heading: `(mechanical — specialist self-checks)` or `(judgment — reviewer only)` or `(mixed — specialist checks mechanical items, reviewer assesses judgment items)`
2. Add a note in the Review Process section: axes marked PASS in the specialist's self-review may be spot-checked rather than re-run in full
3. Add: a missing or empty Self-Review section in the completion report is a blocker (NEEDS_REVISION)
**Test Command**: N/A (documentation only)
**DoD Items**:
- [ ] All reviewer docs updated noting that self-reviewed axes can be spot-checked
- [ ] Mechanical vs judgment axis distinction documented per reviewer

## Open Questions
None.

## Integration Handoffs
All phases use platform-agent. No cross-agent coordination needed.
