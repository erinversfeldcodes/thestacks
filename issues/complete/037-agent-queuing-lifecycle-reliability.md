# Issue #037: Agent Queuing & Lifecycle Reliability

## Summary
Agents don't process queued prompts after completing their initial task, and Agent Teams teammates resist shutdown. Both issues force manual re-launches and prevent clean team cleanup, degrading the orchestrator's ability to manage parallel work.

## User Stories
N/A — agent system infrastructure.

## Goal
The orchestrator can reliably queue sequential phases to a single agent (or separate agents), and teammates shut down cleanly when asked. No manual intervention required for agent lifecycle management.

## Technical Requirements

### Problem 1: Queued prompts dropped (#011)
When the orchestrator sends multiple prompts to a resumed agent via `resume`, the agent completes the first prompt and exits without processing subsequent queued prompts. This was observed in Issue #011 where Phases 3 and 4 were queued to the Phase 2 agent — the agent completed Phase 2 and stopped.

**Fix in orchestrator protocol:**
- Add explicit guidance: "Do not queue multiple prompts to a single agent via `resume`. Launch a separate agent for each independent phase."
- Update Phase 2 (Implementation Cycle) to document this constraint.

### Problem 2: Teammate shutdown resistance (#005)
In Issue #005, the platform-agent teammate didn't respond to multiple shutdown requests, preventing `TeamDelete` from succeeding. The teammate remained idle but alive, blocking team cleanup.

**Fix in orchestrator protocol:**
- Add shutdown instructions with timeout to teammate prompts: "When your task is complete, submit your completion report and stop. Do not wait for further instructions."
- Document the `TeamDelete` failure mode and workaround (manual agent termination).
- Add a timeout-based fallback: if a teammate doesn't respond to shutdown within 60 seconds, proceed with cleanup anyway.

### Problem 3: Orchestrator guidance gaps
The orchestrator protocol in `docs/agents/orchestrator-agent.md` lacks:
- Explicit constraint against prompt queuing
- Teammate shutdown instructions in the spawn template
- Fallback procedures when agents/teammates don't respond

## Definition of Done
- [ ] `docs/agents/orchestrator-agent.md` updated: "Do not queue multiple prompts to a single agent" guidance added to Phase 2
- [ ] Orchestrator agent spawn template includes shutdown instruction for teammates
- [ ] Timeout-based fallback documented for teammate cleanup
- [ ] Guidance tested: orchestrator launches separate agents for Phases 2, 3, 4 in a multi-phase issue without queuing

## Dependencies
None — documentation and protocol changes only.

## Agent Assignment
- **Orchestrator** (direct edit — no specialist needed)
- **Reviewer**: Manual review by human

## Progress Notes
<!-- Updated by agents during execution -->
