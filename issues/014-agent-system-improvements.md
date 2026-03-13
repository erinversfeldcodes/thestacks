# Issue #014: Agent System Improvements — Explore Phase, Challenge-the-Brief, Self-Verification, Retrospective

## Summary
Four structural gaps in the agent workflow were identified by comparing the system against common principles: the Explore phase skips alternative exploration before planning; specialist agents are executors rather than thinking partners; implementation agents don't self-verify before handoff; and there is no retrospective mechanism to make the system self-improving.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
A workflow where (1) fundamental approach questions are raised before implementation begins, not after; (2) specialist agents flag risks and underspecified requirements at the start of their work; (3) implementation agents verify their own output with real data before submitting a completion report; and (4) the orchestrator runs a structured retrospective after each completed phase so the agent system improves over time.

## Technical Requirements

### 14.1 — Pre-planning Alternative Exploration

Currently the orchestrator moves from research → plan with no explicit step to question the approach. Reviewer Axis 6 (Alternative Approaches) catches this too late — after implementation is complete.

**Change to `docs/agents/orchestrator-agent.md`:**

Add a mandatory **Approach Exploration** step between Phase 1 (research) and Phase 2 (planning):

> Before drafting the implementation plan, consider whether the plan as written represents the best approach to the problem. Specifically:
> - Are there fundamentally different architectural approaches to this problem? What are the tradeoffs?
> - Does the roadmap phase assume a specific technology or pattern that may have better alternatives?
> - Are there known footguns, deprecation warnings, or community debates about the chosen approach?
>
> Produce a short (3–5 bullet) **Approach Options** section in the plan that the human can review before implementation begins. For each option: what it is, the tradeoff against the chosen approach, and a recommendation. The human may override the recommendation before the plan is executed.

This does not block planning — the orchestrator still produces a plan. It adds a section the human can act on before issuing the implementation prompt.

---

### 14.2 — Challenge-the-Brief Step for Specialist Agents

Specialist agents (elixir-agent, elm-agent, etc.) receive a plan and implement it. There is no explicit step to question whether the plan is right before execution begins. Issues that would have been caught early — underspecified requirements, risky assumptions, approach mismatches — surface only at review time.

**Change to each specialist agent file (`docs/agents/*.md`):**

Add a **Challenge the Brief** step at the start of the agent's process, before any implementation:

> Before writing any code, read the phase plan carefully and identify anything that seems:
> - **Underspecified**: requirements or interfaces that are ambiguous or missing detail
> - **Risky**: assumptions that are likely to be wrong, or that will be hard to undo
> - **Suboptimal**: a better library, pattern, or approach exists for this specific problem
> - **Inconsistent**: the plan conflicts with existing code, architecture docs, or standards
>
> Raise each finding explicitly in your completion report under "Pre-implementation Flags". If no flags, state "None". Do not block on flags — implement as planned, but flag first.

Agents that are already good executors remain so. This step adds a lightweight thinking-partner moment without requiring human intervention at the start of every task.

**Files to update:**
- `docs/agents/elixir-agent.md`
- `docs/agents/elm-agent.md`
- `docs/agents/python-agent.md`
- `docs/agents/rust-agent.md`
- `docs/agents/database-agent.md`
- `docs/agents/protobuf-agent.md`
- `docs/agents/platform-agent.md`

---

### 14.3 — Self-Verification Before Completion Report

Currently, implementation agents submit a completion report and hand off to the reviewer. The reviewer runs `mix test` etc. after the fact. Issues that would have been obvious with a real test run are caught only in the review cycle, requiring a revision round.

**Change to each specialist agent file and to the orchestrator's completion report instructions:**

Add a mandatory **Self-Verification** step before the agent submits its completion report:

> Before submitting your completion report:
> 1. Run the test suite for the language/component you changed and confirm it passes. Record the exact output (pass count, any skips).
> 2. If the feature has a realistic "happy path" (an HTTP endpoint, a rendered view, a processed image), exercise it with real input — not just tests — and confirm the output looks correct.
> 3. If any test fails or the feature does not behave as expected, fix it before submitting.
> 4. Include the test run output summary in your completion report under "Test Results".
>
> Do not submit a completion report with failing tests or an untested feature.

---

### 14.4 — Structured Retrospective After Phase Completion

There is no mechanism for the agent system to learn from experience. After a multi-phase implementation, the orchestrator writes a completion file, but it is a summary, not a reflection. Patterns that cause revision cycles, human overrides, or agent confusion are never captured and never feed back into the agent prompts.

**Change to `docs/agents/orchestrator-agent.md` Phase 3 (post-implementation):**

Add a **Retrospective** step after all phases complete and the human has reviewed/committed:

> After the human has accepted the implementation (committed or merged), run a structured retrospective by answering the following three questions — drawing on the full session: the completion reports, the reviewer findings, the human's override decisions, and any revision cycles.
>
> **What worked well?** Phases that completed without revision, reviewer findings that were spot-on, plan decisions that paid off.
>
> **What caused friction?** Revision cycles and their root causes. Human overrides and why the agent got it wrong. Reviewer findings that required implementation rework. Plan assumptions that turned out to be false.
>
> **What should change in the agent system?** Specific, actionable changes to agent prompts, standards files, or the orchestrator protocol that would prevent the friction points from recurring. Each suggestion should name the file to change and describe the change.
>
> Write the retrospective to `plans/{NNN}-{slug}-retro.md`. The human decides which suggestions to act on — they become candidates for the next agent system improvement issue (like this one).

---

## Definition of Done

- [ ] `docs/agents/orchestrator-agent.md` updated with Approach Exploration step (§14.1) and Retrospective step (§14.4)
- [ ] All 7 specialist agent files updated with Challenge the Brief step (§14.2)
- [ ] All 7 specialist agent files and orchestrator updated with Self-Verification step (§14.3)
- [ ] Completion report format updated in each agent to include "Pre-implementation Flags" and "Test Results" sections
- [ ] Retrospective template created at `plans/retro-template.md`

## Dependencies
None — self-contained documentation change. No code changes required.

## Agent Assignment
Orchestrator session (no specialist agent required — all changes are to agent prompt files).

## Progress Notes
- 2026-03-13: All 9 files implemented (orchestrator, 7 specialists, retro template). Reviewer returned APPROVED in one cycle. All DoD items satisfied.
