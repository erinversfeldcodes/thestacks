# Complete: Structured Feedback Loop from Reviews to Agent Prompts
**Issue**: #021
**Completed**: 2026-03-13

## Summary
Created a persistent feedback loop from reviewer findings to specialist agent prompts. Feedback log files in `docs/agents/feedback/` capture structured entries when reviewers return NEEDS_REVISION. The `get_feedback_summary` MCP tool reads open entries so the orchestrator can brief specialists on known gaps before invocation.

## Files Created/Modified (13)
- `docs/agents/feedback/` — 10 template files (one per specialist)
- `docs/agents/orchestrator-agent.md` — Phase 2D feedback logging + invocation known-gaps section
- `scripts/mcp/project_tools.py` — `get_feedback_summary` tool + `_parse_feedback_file` helper
- `scripts/mcp/test_project_tools.py` — 4 new tests (20 total)

## DoD Items
- [x] `docs/agents/feedback/` directory created with template file for each specialist
- [x] Feedback entry format documented in each file's header
- [x] Orchestrator Phase 2D updated to append feedback entries on NEEDS_REVISION
- [x] `get_feedback_summary` MCP tool implemented
- [x] Orchestrator invocation template updated to include known-gaps section when feedback exists
- [ ] At least one feedback entry written and used to improve a specialist prompt (deferred — requires real NEEDS_REVISION cycle)
