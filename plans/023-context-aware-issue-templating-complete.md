# Complete: Context-Aware Issue Templating
**Issue**: #023
**Completed**: 2026-03-13

## Summary
Added a `draft_issue` MCP tool that pre-populates issue drafts with domain-specific DoD items, agent assignments, dependency suggestions, and standards references. The orchestrator's Phase 0 now calls `draft_issue` before `create_issue`, reducing manual cross-referencing at the mandatory stop.

## Files Created/Modified (4)
- `scripts/mcp/dod_templates.py` — DoD templates for 6 domains + agent mappings for 9 domains (created)
- `scripts/mcp/project_tools.py` — `draft_issue` tool with dependency detection
- `scripts/mcp/test_project_tools.py` — 13 new tests (39 total)
- `docs/agents/orchestrator-agent.md` — Phase 0 step 3 updated to use `draft_issue` before `create_issue`

## DoD Items
- [x] `draft_issue` MCP tool implemented
- [x] `scripts/mcp/dod_templates.py` with domain DoD templates for elixir, elm, rust, python, platform, database
- [x] Dependency detection logic implemented and tested against existing issue set
- [x] Orchestrator Phase 0 step 3 updated to use `draft_issue` before `create_issue`
- [x] Tool tested: draft for an elixir domain issue includes correct DoD items and surfaces relevant open issues
