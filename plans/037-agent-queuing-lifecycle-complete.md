# Completion: Agent Queuing & Lifecycle Reliability
**Issue**: #037
**Completed**: 2026-03-14
**Agent(s)**: orchestrator (direct edit)

## Summary
Updated orchestrator protocol with three additions to prevent agent queuing failures and teammate shutdown issues.

## Changes to `docs/agents/orchestrator-agent.md`
1. **Agent Queuing Constraint** — new subsection under Context Conservation Strategy documenting that multiple prompts must not be queued to a single agent
2. **Teammate shutdown instruction** — added to teammate spawn template requiring explicit "stop immediately" instruction
3. **Teammate Cleanup Fallback** — new subsection documenting 60-second timeout for unresponsive teammates
