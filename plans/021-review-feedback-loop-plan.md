# Plan: Structured Feedback Loop from Reviews to Agent Prompts
**Issue**: #021
**Created**: 2026-03-13
**Status**: Approved

## Context
Reviewer NEEDS_REVISION findings are valuable signal about specialist prompt gaps. A persistent feedback log captures each finding, enabling systematic prompt improvements. The orchestrator appends entries on NEEDS_REVISION and briefs specialists on known gaps before invocation.

## Research Summary
The orchestrator's Phase 2D (Act on Review Result) handles NEEDS_REVISION by presenting the review to the human, incrementing revision cycles, and returning to 2A. The invocation template is in the Subagent Invocation Protocol section. The MCP server (`project_tools.py`) follows a sync `@mcp.tool()` pattern.

## Approach Options
- **Option A (chosen):** Feedback directory + MCP tool + orchestrator protocol updates. Recommended.
- **Option B:** Database-backed feedback — over-engineered. Not recommended.
- **Option C:** Claude Code auto-memory — wrong scope. Not recommended.

## Phases

### Phase 1: Feedback Directory + Orchestrator Protocol
**Objective**: Create feedback directory with templates, update orchestrator Phase 2D and invocation template
**Agent(s)**: platform-agent
**Steps**:
1. Create `docs/agents/feedback/` directory
2. Create template feedback log files for all 10 specialists (elixir-agent.md through testing-coordinator-agent.md)
3. Update orchestrator Phase 2D to append feedback entries on NEEDS_REVISION
4. Update orchestrator Subagent Invocation Protocol to include known-gaps briefing when feedback exists
**Test Command**: N/A (documentation/scaffolding only)
**DoD Items**:
- [ ] `docs/agents/feedback/` directory created with template file for each specialist
- [ ] Feedback entry format documented in each file's header
- [ ] Orchestrator Phase 2D updated to append feedback entries on NEEDS_REVISION
- [ ] Orchestrator invocation template updated to include known-gaps section when feedback exists

### Phase 2: MCP Tool
**Objective**: Implement `get_feedback_summary` in `scripts/mcp/project_tools.py`
**Agent(s)**: python-agent
**Steps**:
1. Add `get_feedback_summary(agent_name: str | None = None) -> list[dict]` tool
2. Parse markdown feedback files for structured entries
3. Filter to open entries only (status: open)
4. Return list of entry dicts with date, issue, axis, finding, root_cause, prompt_change_needed, status
5. Write tests for parsing and filtering
**Test Command**: `cd scripts/mcp && .venv/bin/python -m unittest test_project_tools.py`
**DoD Items**:
- [ ] `get_feedback_summary` MCP tool implemented
- [ ] Tool tested with sample feedback entries

## Open Questions
None.

## Integration Handoffs
Phase 1 creates the feedback directory and file format. Phase 2 parses those files. Phase 2 depends on Phase 1 establishing the format.
