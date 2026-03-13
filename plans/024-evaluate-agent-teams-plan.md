# Plan: Evaluate Claude Code Agent Teams
**Issue**: #024
**Created**: 2026-03-13
**Status**: Approved

## Context
Claude Code now has native Agent Teams for multi-agent orchestration. The Stacks orchestrator does this manually through prompt engineering. This issue evaluates whether migrating to Agent Teams would meaningfully simplify the orchestrator.

## Research Summary
Agent Teams are experimental (disabled by default). They offer peer-to-peer messaging, shared task lists, and distributed context windows. However, they lack native worktree isolation (teammates share one directory), cannot enforce mandatory stops across the whole team, have no session resumption for teammates, and warn about file conflict overwrites. The existing orchestrator already handles all of these concerns via prompt engineering + MCP tools + worktrees.

## Approach Options
Not applicable — this is a research/evaluation issue, not an implementation choice.

## Phases

### Phase 1: Research + Decision Document
**Objective**: Produce decision matrix and recommendation
**Agent(s)**: Orchestrator (direct — no specialist delegation)
**Steps**:
1. Research Agent Teams documentation (done)
2. Build decision matrix from research findings
3. Assess prototype feasibility given experimental status
4. Write recommendation to `docs/agents/decisions/agent-teams-evaluation.md`
**Test Command**: N/A (research only)
**DoD Items**:
- [ ] Agent Teams documentation read and summarised
- [ ] Decision matrix completed with evidence
- [ ] Recommendation documented

## Open Questions
None.
