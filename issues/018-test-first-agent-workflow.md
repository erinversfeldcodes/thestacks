# Issue #018: Test-First Agent Workflow

## Summary
The current flow is plan → implement → review. Flipping it to plan → write failing tests → implement → verify tests pass → review eliminates an entire class of revision cycles by making tests the executable spec before any production code exists.

## User Stories
Not directly tied to a user story — internal tooling for the agent-driven development workflow.

## Goal
Reviewers stop catching "tests don't cover the requirements" failures. Every specialist phase begins with tests that fail (because there's nothing to pass them yet), and the reviewer's job shifts from "does this work?" to "are the tests meaningful and is the code clean?" Revision cycles caused by insufficient test coverage are eliminated.

## Technical Requirements

### 18.1 — Orchestrator Phase Protocol Change

The orchestrator's subagent invocation prompt gains a mandatory test-first gate:

1. **Delegate test writing**: Specialist writes tests that specify the behaviour described in the phase DoD. Tests must fail (no implementation yet). Specialist returns the failing test output as evidence.
2. **Orchestrator verifies**: Confirms the specialist returned failing tests before proceeding. If no failing tests returned, send back.
3. **Delegate implementation**: Specialist implements against the failing tests. Must return passing test output.
4. **Proceed to review**: Reviewer sees both the tests and the implementation.

This replaces the current single delegation step with two — test-write then implement — with an automated failing-test check between them.

### 18.2 — Specialist Agent Updates

All specialist agents gain a **Test-First Protocol** subsection in their Orchestrator Integration section:

> When starting a phase, write the tests first. Tests must:
> - Cover every DoD item for this phase
> - Fail before implementation (return failing test output as evidence)
> - Pass after implementation (return passing test output as evidence)
>
> Do not write any production code until tests are written and confirmed failing.

### 18.3 — Reviewer Checklist Update

The reviewer's `docs/agents/reviewers/` files gain a test-first check axis:

> **Axis 0: Test-First Compliance**
> - Were tests written before implementation? (Check completion report for failing test evidence)
> - Do the tests cover all DoD items?
> - Are the tests meaningful (not trivially passing)?

Axis 0 is a blocker — NEEDS_REVISION if failing test evidence is absent.

### 18.4 — Language-Specific Considerations

| Language | Test framework | Failing evidence format |
|----------|---------------|------------------------|
| Elixir | ExUnit | `mix test` output with failure count |
| Elm | elm-test | `elm-test` output with failure count |
| Rust | cargo test | `cargo test` output with failure count |
| Python | pytest | `pytest` output with failure count |

Failing tests must show at least one meaningful failure (not compile errors — actual assertion failures proving the feature doesn't exist yet).

## Definition of Done

- [ ] Orchestrator updated: two-step delegation (test-write then implement) with failing-test gate between
- [ ] All specialist agent docs updated with Test-First Protocol subsection
- [ ] All reviewer docs updated with Axis 0 (test-first compliance) as a blocker
- [ ] Orchestrator completion report template updated to include failing test evidence field
- [ ] At least one real phase run under the new protocol

## Dependencies
- Issue #014 (agent system improvements) — builds on existing specialist/reviewer structure

## Agent Assignment
- **platform-agent** for orchestrator-agent.md changes
- All specialist agents and reviewer docs are mechanical updates

## Progress Notes
<!-- Updated by agents during execution -->
- 2026-03-13: Issue created from agentic techniques feedback.
