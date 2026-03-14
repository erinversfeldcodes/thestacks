# Issue #019: Specialist Self-Review Before Handoff

## Summary
Before submitting a completion report, each specialist loads its stack-specific reviewer's `.md` file and runs a structured self-assessment against the mechanical review axes — format, typespecs, event emission, security basics. The reviewer then skips axes the specialist already verified and focuses on judgment calls.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Mechanical review failures (missing typespecs, unformatted code, missing event emissions) never survive to the reviewer. Revision cycles caused by routine checklist items are eliminated. Reviewer capacity is freed for architectural, security, and forward-compatibility concerns.

## Technical Requirements

### 19.1 — Self-Review Step in Specialist Agents

All specialist agent docs gain a **Self-Review** subsection in Orchestrator Integration, after Self-Verification and before Completion Report:

> Before submitting your completion report:
> 1. Load `docs/agents/reviewers/<stack>-reviewer.md`
> 2. Run through each review axis that is mechanical and checkable without deep domain judgment
> 3. Fix any failures you find
> 4. Include a **Self-Review** section in your completion report listing which axes you checked and their result

The self-review is not a substitute for the reviewer — it is a pre-flight that filters out failures the specialist can catch themselves.

### 19.2 — Mechanical vs Judgment Axes

Specialists self-check **mechanical axes** only:
- Formatting (mix format, elm-format, cargo fmt, ruff)
- Typespecs / type annotations on public functions
- Test coverage (tests written and passing)
- Required conventions (event emission for state changes, ISBN gate, etc.)

Specialists do **not** self-assess judgment axes:
- Alternative approaches
- Security threat model
- Forward compatibility / breaking changes
- Architectural fit

### 19.3 — Completion Report Update

The completion report format for all specialists gains a required **Self-Review** section:

```
7. Self-Review
   | Axis | Result | Notes |
   |------|--------|-------|
   | mix format | PASS | — |
   | typespecs on public functions | PASS | — |
   | events emitted for state changes | PASS | BookPlaced emitted |
   | tests passing | PASS | 42 passed |
```

A missing or empty self-review section is a reviewer blocker.

### 19.4 — Reviewer Acknowledgement

Reviewer docs gain a note: axes marked PASS in the specialist's self-review may be spot-checked rather than re-run in full, allowing the reviewer to focus context on judgment axes.

## Definition of Done

- [ ] All specialist agent docs updated with Self-Review subsection
- [ ] All specialist completion report formats updated with Self-Review section
- [ ] All reviewer docs updated noting that self-reviewed axes can be spot-checked
- [ ] Mechanical vs judgment axis distinction documented per reviewer

## Dependencies
- Issue #014 (agent system improvements)
- Issue #018 (test-first workflow) — the two reinforce each other; both reduce reviewer burden

## Agent Assignment
- Changes are to agent docs only — platform-agent or direct edit

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
